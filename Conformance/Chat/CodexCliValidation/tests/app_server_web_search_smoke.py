#!/usr/bin/env python3
"""Run app-server web-search response-item persistence parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers source-backed persisted
`ResponseItem::WebSearchCall` and the related durable `EventMsg::WebSearchEnd`
path, proving that the original backend and the `.chat` backend keep the same
durable web-search facts while the `.chat` timeline exposes a neutral tool
event for lightweight readers.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import threading
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    normalize_thread_list_response,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_fork_smoke import (  # noqa: E402
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_start,
    send_turn_start,
)


USER_TEXT = "Search for the MSP .chat source transport notes."
ASSISTANT_TEXT = "Web search persistence final answer from mock model."
WEB_SEARCH_ID = "ws-chat-validation-smoke"
WEB_SEARCH_QUERY = ".chat file standard source transport"
WEB_SEARCH_QUERIES = [
    ".chat file standard source transport",
    "agent conversation file format",
]


def sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def ev_response_created(response_id: str) -> dict[str, Any]:
    return {"type": "response.created", "response": {"id": response_id}}


def ev_completed(response_id: str) -> dict[str, Any]:
    return {
        "type": "response.completed",
        "response": {
            "id": response_id,
            "usage": {
                "input_tokens": 27,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 31,
                "output_tokens_details": {"reasoning_tokens": 0},
                "total_tokens": 58,
            },
        },
    }


def ev_web_search_call() -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "id": WEB_SEARCH_ID,
            "type": "web_search_call",
            "status": "completed",
            "action": {
                "type": "search",
                "query": WEB_SEARCH_QUERY,
                "queries": WEB_SEARCH_QUERIES,
            },
        },
    }


def ev_final_message() -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "message",
            "role": "assistant",
            "id": "msg-web-search-smoke-final",
            "content": [{"type": "output_text", "text": ASSISTANT_TEXT}],
        },
    }


def web_search_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_web_search_call(),
            ev_final_message(),
            ev_completed(response_id),
        ]
    )


class WebSearchResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        return web_search_sse_response(f"resp-web-search-smoke-{counter}")

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        bodies = [request["json"] for request in response_requests]
        first_body = bodies[0] if bodies else {}
        serialized_first_body = json.dumps(first_body, ensure_ascii=False)
        first_tools = [
            item.get("name") or item.get("type")
            for item in first_body.get("tools", [])
            if isinstance(item, dict)
        ]
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "first_response_model": first_body.get("model"),
            "first_response_input_contains_user_text": USER_TEXT
            in json.dumps(first_body.get("input"), ensure_ascii=False),
            "first_response_tools": first_tools,
            "first_response_advertises_web_search": "web_search" in first_tools,
            "first_request_body_mentions_web_search": "web_search"
            in serialized_first_body,
        }


def normalize_thread_read_for_web_search(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": [
            (turn.get("status") or {}).get("type")
            if isinstance(turn.get("status"), dict)
            else turn.get("status")
            for turn in turns
        ],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in turn.get("items") or []] for turn in turns
        ],
        "contains_user_text": USER_TEXT in serialized,
        "contains_assistant_text": ASSISTANT_TEXT in serialized,
        "contains_web_search_id": WEB_SEARCH_ID in serialized,
        "contains_web_search_query": WEB_SEARCH_QUERY in serialized,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def normalized_action(action: Any) -> Any:
    if not isinstance(action, dict):
        return action
    return json.loads(json.dumps(action, sort_keys=True))


def summarize_web_search_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    response_types: list[str] = []
    event_msg_types: list[str] = []
    web_search_calls: list[dict[str, Any]] = []
    web_search_end_events: list[dict[str, Any]] = []

    for item in items:
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        if item.get("type") == "response_item":
            response_types.append(nested_type)
            if nested_type == "web_search_call":
                web_search_calls.append(
                    {
                        "id": payload.get("id"),
                        "status": payload.get("status"),
                        "action": normalized_action(payload.get("action")),
                    }
                )
        elif item.get("type") == "event_msg":
            event_msg_types.append(nested_type)
            if nested_type == "web_search_end":
                web_search_end_events.append(
                    {
                        "call_id": payload.get("call_id"),
                        "query": payload.get("query"),
                        "action": normalized_action(payload.get("action")),
                    }
                )

    expected_action = {
        "type": "search",
        "query": WEB_SEARCH_QUERY,
        "queries": WEB_SEARCH_QUERIES,
    }
    return {
        "line_count": len(items),
        "response_types": response_types,
        "event_msg_types": event_msg_types,
        "web_search_call_count": len(web_search_calls),
        "web_search_end_count": len(web_search_end_events),
        "web_search_calls": web_search_calls,
        "web_search_end_events": web_search_end_events,
        "web_search_call_ids": [item.get("id") for item in web_search_calls],
        "web_search_end_call_ids": [
            item.get("call_id") for item in web_search_end_events
        ],
        "web_search_statuses": [item.get("status") for item in web_search_calls],
        "has_expected_web_search_call": any(
            item.get("id") == WEB_SEARCH_ID
            and item.get("status") == "completed"
            and item.get("action") == expected_action
            for item in web_search_calls
        ),
        "has_expected_web_search_end": any(
            item.get("call_id") == WEB_SEARCH_ID
            and item.get("action") == expected_action
            for item in web_search_end_events
        ),
    }


def summarize_original_web_search_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    rollout_paths = sorted(codex_home.rglob("*.jsonl"))
    all_items: list[dict[str, Any]] = []
    rollouts = []
    for path in rollout_paths:
        lines = read_json_lines(path)
        all_items.extend(lines)
        rollouts.append(
            {
                "path": path.relative_to(codex_home).as_posix(),
                "line_count": len(lines),
            }
        )
    summary = summarize_web_search_sources(all_items)
    summary.update({"codex_home": str(codex_home), "rollouts": rollouts})
    return summary


def summarize_chat_web_search_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_web_search_sources([]),
            "timeline": {},
        }
    package = packages[0]
    journal_lines = read_json_lines(package / "journal.ndjson")
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_lines = read_json_lines(package / "timeline.ndjson")
    timeline_source_payload_types = [
        (line.get("body") or {}).get("source_response_type") for line in timeline_lines
    ]
    timeline_summary = {
        "line_count": len(timeline_lines),
        "event_types": [line.get("type") for line in timeline_lines],
        "source_payload_types": timeline_source_payload_types,
        "web_search_call_event_count": sum(
            1 for value in timeline_source_payload_types if value == "web_search_call"
        ),
        "web_search_end_event_count": sum(
            1 for value in timeline_source_payload_types if value == "web_search_end"
        ),
        "tool_call_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "tool_call"
        ),
        "status_changed_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "status_changed"
        ),
    }
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "package": str(package),
        "journal": summarize_web_search_sources(source_items),
        "timeline": timeline_summary,
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with WebSearchResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                client,
                2,
                workspace,
            )
            turn_start_result = send_turn_start(
                client,
                3,
                started_thread_id,
                "client-user-message-web-search-smoke",
                USER_TEXT,
            )
            thread_read_response = send_thread_read(client, 4, started_thread_id)
            thread_list_response = send_thread_list(client, 5)
        finally:
            stderr = client.close()

        result = {
            "tree": tree_name,
            "command": client.command,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "mock_server_summary": mock_server.summary(),
            "initialize_response": initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_result": turn_start_result,
            "thread_read_response": thread_read_response,
            "thread_list_response": thread_list_response,
            "normalized_thread_read": normalize_thread_read_for_web_search(
                thread_read_response
            ),
            "normalized_thread_list": normalize_thread_list_response(
                thread_list_response,
                started_thread_id,
            ),
            "jsonrpc_sent": client.sent,
            "jsonrpc_received": client.received,
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }
        if tree_name == "chat-backend":
            result["chat_package_summary"] = summarize_chat_packages(chat_root)
            result["chat_web_search_storage"] = summarize_chat_web_search_package(
                chat_root
            )
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
            result["original_web_search_storage"] = summarize_original_web_search_storage(
                codex_home
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-web-search-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

    run_root = output_dir / "run"
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_storage = original_result["original_web_search_storage"]
    chat_storage = chat_result["chat_web_search_storage"]
    chat_journal = chat_storage["journal"]
    chat_timeline = chat_storage["timeline"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-web-search-smoke",
        "binary_checks": binary_checks,
        "original_turn_start_exit_ok": "result"
        in original_result["turn_start_result"]["response"],
        "chat_backend_turn_start_exit_ok": "result"
        in chat_result["turn_start_result"]["response"],
        "normalized_thread_read_equal": original_read == chat_read,
        "normalized_thread_list_equal": original_list == chat_list,
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
        ),
        "mock_response_request_count_is_one": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
            == 1
        ),
        "mock_first_request_contains_user_text": (
            original_result["mock_server_summary"][
                "first_response_input_contains_user_text"
            ]
            and chat_result["mock_server_summary"][
                "first_response_input_contains_user_text"
            ]
        ),
        "mock_first_request_advertises_web_search": (
            original_result["mock_server_summary"][
                "first_response_advertises_web_search"
            ]
            and chat_result["mock_server_summary"][
                "first_response_advertises_web_search"
            ]
        ),
        "original_has_web_search_call": original_storage[
            "has_expected_web_search_call"
        ],
        "chat_journal_has_web_search_call": chat_journal[
            "has_expected_web_search_call"
        ],
        "original_has_web_search_end": original_storage["has_expected_web_search_end"],
        "chat_journal_has_web_search_end": chat_journal["has_expected_web_search_end"],
        "web_search_call_counts_equal": original_storage["web_search_call_count"]
        == chat_journal["web_search_call_count"],
        "web_search_end_counts_equal": original_storage["web_search_end_count"]
        == chat_journal["web_search_end_count"],
        "web_search_call_ids_equal": original_storage["web_search_call_ids"]
        == chat_journal["web_search_call_ids"],
        "web_search_end_call_ids_equal": original_storage["web_search_end_call_ids"]
        == chat_journal["web_search_end_call_ids"],
        "web_search_calls_equal": original_storage["web_search_calls"]
        == chat_journal["web_search_calls"],
        "web_search_end_events_equal": original_storage["web_search_end_events"]
        == chat_journal["web_search_end_events"],
        "line_counts_equal": original_storage["line_count"] == chat_journal["line_count"],
        "chat_timeline_has_web_search_call_mapping": chat_timeline.get(
            "web_search_call_event_count",
            0,
        )
        >= 1
        and chat_timeline.get("tool_call_event_count", 0) >= 1,
        "chat_timeline_has_web_search_end_mapping": chat_timeline.get(
            "web_search_end_event_count",
            0,
        )
        >= 1
        and chat_timeline.get("status_changed_event_count", 0) >= 1,
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_web_search_storage": original_storage,
        "chat_web_search_storage": chat_storage,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "standalone web-search extension execution",
            "live external network search behavior",
            "open_page and find_in_page web-search actions",
            "subagent activity",
            "inter-agent communication",
            "detached/interrupted review-mode variants",
            "broader MCP/app-search/dynamic tool variants",
            "performance and final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/web-search-response.json", original_result)
    write_json(output_dir / "chat-backend/web-search-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Web Search Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that emits one `web_search_call` plus a final assistant message.

## Gate

Before this work, the public `.chat` goal attachment, spec files,
vendor manifest, baseline checks, parity matrix, current data-fidelity report,
persisted item inventory, original Codex persistence policy, original web-search
response-item model, and adapted `.chat` mapper were read.

## Scope

This smoke covers a source-backed open gap from the persisted item inventory:
`ResponseItem::WebSearchCall` and the persisted `EventMsg::WebSearchEnd`
derived from that turn item. It proves that the original backend and `.chat`
backend both persist the same web-search facts for this app-server path, and
that `.chat` also exposes a neutral `tool_call` timeline mapping linked to
journal source transport.

It does not prove standalone web-search extension execution, live external
network search behavior, `open_page` / `find_in_page` action variants,
performance, or final user-indistinguishability.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- both runs made exactly one Responses request: `{summary['mock_response_request_count_is_one']}`
- first request contained user text: `{summary['mock_first_request_contains_user_text']}`
- first request advertised `web_search`: `{summary['mock_first_request_advertises_web_search']}` (observed only; this smoke validates persisted provider output)
- original rollout has expected `web_search_call`: `{summary['original_has_web_search_call']}`
- `.chat` journal has expected `web_search_call`: `{summary['chat_journal_has_web_search_call']}`
- original rollout has expected `web_search_end`: `{summary['original_has_web_search_end']}`
- `.chat` journal has expected `web_search_end`: `{summary['chat_journal_has_web_search_end']}`
- `web_search_call` counts equal: `{summary['web_search_call_counts_equal']}`
- `web_search_end` counts equal: `{summary['web_search_end_counts_equal']}`
- `web_search_call` ids equal: `{summary['web_search_call_ids_equal']}`
- `web_search_end` call ids equal: `{summary['web_search_end_call_ids_equal']}`
- `web_search_call` payloads equal: `{summary['web_search_calls_equal']}`
- `web_search_end` payloads equal: `{summary['web_search_end_events_equal']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- `.chat` timeline has neutral web-search call mapping: `{summary['chat_timeline_has_web_search_call_mapping']}`
- `.chat` timeline has web-search end status mapping: `{summary['chat_timeline_has_web_search_end_mapping']}`

## Normalized Thread Read

```json
{json.dumps({'original': original_read, 'chat-backend': chat_read}, indent=2, sort_keys=True)}
```

## Original Web Search Storage

```json
{json.dumps(original_storage, indent=2, sort_keys=True)}
```

## `.chat` Web Search Storage

```json
{json.dumps(chat_storage, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/web-search-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/web-search-response.json
```
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return (
        0
        if summary["original_turn_start_exit_ok"]
        and summary["chat_backend_turn_start_exit_ok"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["mock_response_request_count_is_one"]
        and summary["mock_first_request_contains_user_text"]
        and summary["original_has_web_search_call"]
        and summary["chat_journal_has_web_search_call"]
        and summary["original_has_web_search_end"]
        and summary["chat_journal_has_web_search_end"]
        and summary["web_search_call_counts_equal"]
        and summary["web_search_end_counts_equal"]
        and summary["web_search_call_ids_equal"]
        and summary["web_search_end_call_ids_equal"]
        and summary["web_search_calls_equal"]
        and summary["web_search_end_events_equal"]
        and summary["line_counts_equal"]
        and summary["chat_timeline_has_web_search_call_mapping"]
        and summary["chat_timeline_has_web_search_end_mapping"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
