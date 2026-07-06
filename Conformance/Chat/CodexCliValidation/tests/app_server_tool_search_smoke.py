#!/usr/bin/env python3
"""Run app-server tool-search persistence parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers source-backed persisted
`ResponseItem::ToolSearchCall` and `ResponseItem::ToolSearchOutput`, proving
that the original backend and the `.chat` backend keep the same durable
tool-search facts while the `.chat` timeline exposes neutral tool events.
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
    send_turn_start,
)


USER_TEXT = "Find the deferred .chat validation tool."
ASSISTANT_TEXT = "Tool search persistence final answer from mock model."
TOOL_SEARCH_CALL_ID = "call-tool-search-smoke"
TOOL_NAMESPACE = "validation_tools"
TOOL_NAME = "validate_chat_package"
TOOL_QUERY = ".chat validation package reader"


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
                "input_tokens": 19,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 23,
                "output_tokens_details": {"reasoning_tokens": 0},
                "total_tokens": 42,
            },
        },
    }


def ev_tool_search_call() -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "tool_search_call",
            "call_id": TOOL_SEARCH_CALL_ID,
            "execution": "client",
            "arguments": {
                "query": TOOL_QUERY,
                "limit": 2,
            },
        },
    }


def tool_search_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_tool_search_call(),
            ev_completed(response_id),
        ]
    )


def final_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-tool-search-smoke-final",
                    "content": [{"type": "output_text", "text": ASSISTANT_TEXT}],
                },
            },
            ev_completed(response_id),
        ]
    )


class ToolSearchResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter == 1:
            return tool_search_sse_response("resp-tool-search-smoke-1")
        return final_sse_response(f"resp-tool-search-smoke-{counter}")

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        bodies = [request["json"] for request in response_requests]
        serialized = [json.dumps(body, ensure_ascii=False) for body in bodies]
        first_body = bodies[0] if bodies else {}
        second_body = bodies[1] if len(bodies) > 1 else {}
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
            "first_response_input_contains_user_text": any(
                USER_TEXT in body for body in serialized[:1]
            ),
            "first_response_tools": first_tools,
            "first_response_advertises_tool_search": "tool_search" in first_tools,
            "first_response_hides_deferred_tool": TOOL_NAME not in first_tools,
            "second_response_input_contains_tool_search_output": "tool_search_output"
            in json.dumps(second_body.get("input"), ensure_ascii=False),
            "second_response_input_contains_tool_name": TOOL_NAME
            in json.dumps(second_body.get("input"), ensure_ascii=False),
            "second_response_input_contains_namespace": TOOL_NAMESPACE
            in json.dumps(second_body.get("input"), ensure_ascii=False),
        }


def dynamic_tools() -> list[dict[str, Any]]:
    return [
        {
            "type": "namespace",
            "name": TOOL_NAMESPACE,
            "description": "Tools used by the .chat validation harness.",
            "tools": [
                {
                    "type": "function",
                    "name": TOOL_NAME,
                    "description": "Validate and inspect an MSP .chat package.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string"},
                        },
                        "required": ["path"],
                        "additionalProperties": False,
                    },
                    "deferLoading": True,
                }
            ],
        }
    ]


def send_thread_start_with_dynamic_tools(
    client: JsonRpcClient,
    request_id: int,
    workspace: pathlib.Path,
) -> tuple[str | None, dict[str, Any]]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/start",
            "params": {
                "cwd": str(workspace),
                "ephemeral": False,
                "historyMode": "legacy",
                "model": "mock-model",
                "dynamicTools": dynamic_tools(),
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    thread_id = ((response.get("result") or {}).get("thread") or {}).get("id")
    return thread_id, response


def normalize_thread_read_for_tool_search(response: dict[str, Any]) -> dict[str, Any]:
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
        "contains_tool_search_call_id": TOOL_SEARCH_CALL_ID in serialized,
        "contains_tool_search_tool_name": TOOL_NAME in serialized,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_tool_search_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    response_types: list[str] = []
    tool_search_calls: list[dict[str, Any]] = []
    tool_search_outputs: list[dict[str, Any]] = []
    for item in items:
        if item.get("type") != "response_item":
            continue
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        response_types.append(nested_type)
        if nested_type == "tool_search_call":
            tool_search_calls.append(payload)
        elif nested_type == "tool_search_output":
            tool_search_outputs.append(payload)

    output_tools = []
    for output in tool_search_outputs:
        output_tools.extend(output.get("tools") or [])

    serialized_outputs = json.dumps(tool_search_outputs, ensure_ascii=False)
    return {
        "line_count": len(items),
        "response_types": response_types,
        "tool_search_call_count": len(tool_search_calls),
        "tool_search_output_count": len(tool_search_outputs),
        "tool_search_call_ids": [
            item.get("call_id") for item in tool_search_calls
        ],
        "tool_search_output_call_ids": [
            item.get("call_id") for item in tool_search_outputs
        ],
        "tool_search_queries": [
            (item.get("arguments") or {}).get("query") for item in tool_search_calls
        ],
        "tool_search_executions": [
            item.get("execution") for item in tool_search_calls + tool_search_outputs
        ],
        "tool_search_output_statuses": [
            item.get("status") for item in tool_search_outputs
        ],
        "tool_search_output_tool_count": len(output_tools),
        "tool_search_output_contains_namespace": TOOL_NAMESPACE in serialized_outputs,
        "tool_search_output_contains_tool_name": TOOL_NAME in serialized_outputs,
        "has_expected_tool_search_call": any(
            item.get("call_id") == TOOL_SEARCH_CALL_ID
            and (item.get("arguments") or {}).get("query") == TOOL_QUERY
            for item in tool_search_calls
        ),
        "has_expected_tool_search_output": any(
            item.get("call_id") == TOOL_SEARCH_CALL_ID
            and item.get("status") == "completed"
            and item.get("execution") == "client"
            for item in tool_search_outputs
        ),
    }


def summarize_original_tool_search_storage(codex_home: pathlib.Path) -> dict[str, Any]:
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
    summary = summarize_tool_search_sources(all_items)
    summary.update({"codex_home": str(codex_home), "rollouts": rollouts})
    return summary


def summarize_chat_tool_search_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_tool_search_sources([]),
            "timeline": {},
        }
    package = packages[0]
    journal_lines = read_json_lines(package / "journal.ndjson")
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_lines = read_json_lines(package / "timeline.ndjson")
    timeline_source_response_types = [
        (line.get("body") or {}).get("source_response_type") for line in timeline_lines
    ]
    timeline_summary = {
        "line_count": len(timeline_lines),
        "event_types": [line.get("type") for line in timeline_lines],
        "source_response_types": timeline_source_response_types,
        "tool_search_call_event_count": sum(
            1 for value in timeline_source_response_types if value == "tool_search_call"
        ),
        "tool_search_output_event_count": sum(
            1 for value in timeline_source_response_types if value == "tool_search_output"
        ),
        "tool_call_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "tool_call"
        ),
        "tool_output_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "tool_output"
        ),
    }
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "package": str(package),
        "journal": summarize_tool_search_sources(source_items),
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

    with ToolSearchResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start_with_dynamic_tools(
                client,
                2,
                workspace,
            )
            turn_start_result = send_turn_start(
                client,
                3,
                started_thread_id,
                "client-user-message-tool-search-smoke",
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
            "normalized_thread_read": normalize_thread_read_for_tool_search(
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
            result["chat_tool_search_storage"] = summarize_chat_tool_search_package(
                chat_root
            )
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
            result["original_tool_search_storage"] = (
                summarize_original_tool_search_storage(codex_home)
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-tool-search-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_storage = original_result["original_tool_search_storage"]
    chat_storage = chat_result["chat_tool_search_storage"]
    chat_journal = chat_storage["journal"]
    chat_timeline = chat_storage["timeline"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-tool-search-smoke",
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
        "mock_response_request_count_is_two": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
            == 2
        ),
        "mock_tool_search_visible_in_first_request": (
            original_result["mock_server_summary"][
                "first_response_advertises_tool_search"
            ]
            and chat_result["mock_server_summary"][
                "first_response_advertises_tool_search"
            ]
        ),
        "mock_deferred_tool_hidden_before_search": (
            original_result["mock_server_summary"]["first_response_hides_deferred_tool"]
            and chat_result["mock_server_summary"]["first_response_hides_deferred_tool"]
        ),
        "mock_tool_search_output_reaches_second_request": (
            original_result["mock_server_summary"][
                "second_response_input_contains_tool_search_output"
            ]
            and chat_result["mock_server_summary"][
                "second_response_input_contains_tool_search_output"
            ]
        ),
        "mock_tool_search_output_contains_tool_name": (
            original_result["mock_server_summary"][
                "second_response_input_contains_tool_name"
            ]
            and chat_result["mock_server_summary"][
                "second_response_input_contains_tool_name"
            ]
        ),
        "original_has_tool_search_call": original_storage[
            "has_expected_tool_search_call"
        ],
        "original_has_tool_search_output": original_storage[
            "has_expected_tool_search_output"
        ],
        "chat_journal_has_tool_search_call": chat_journal[
            "has_expected_tool_search_call"
        ],
        "chat_journal_has_tool_search_output": chat_journal[
            "has_expected_tool_search_output"
        ],
        "tool_search_call_counts_equal": original_storage["tool_search_call_count"]
        == chat_journal["tool_search_call_count"],
        "tool_search_output_counts_equal": original_storage["tool_search_output_count"]
        == chat_journal["tool_search_output_count"],
        "tool_search_call_ids_equal": original_storage["tool_search_call_ids"]
        == chat_journal["tool_search_call_ids"],
        "tool_search_output_call_ids_equal": original_storage[
            "tool_search_output_call_ids"
        ]
        == chat_journal["tool_search_output_call_ids"],
        "tool_search_queries_equal": original_storage["tool_search_queries"]
        == chat_journal["tool_search_queries"],
        "line_counts_equal": original_storage["line_count"] == chat_journal["line_count"],
        "chat_timeline_has_tool_search_call_mapping": chat_timeline.get(
            "tool_search_call_event_count",
            0,
        )
        >= 1
        and chat_timeline.get("tool_call_event_count", 0) >= 1,
        "chat_timeline_has_tool_search_output_mapping": chat_timeline.get(
            "tool_search_output_event_count",
            0,
        )
        >= 1
        and chat_timeline.get("tool_output_event_count", 0) >= 1,
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_tool_search_storage": original_storage,
        "chat_tool_search_storage": chat_storage,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "subagent activity",
            "inter-agent communication",
            "detached/interrupted review-mode variants",
            "broader web-search parity",
            "tool_search advertisement and non-empty discovery result parity",
            "broader dynamic tool variants beyond empty tool_search output",
            "performance and final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/tool-search-response.json", original_result)
    write_json(output_dir / "chat-backend/tool-search-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Tool Search Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that emits one `tool_search_call`, lets Codex produce the paired
`tool_search_output`, and then returns a final assistant message.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and persisted item inventory were read.

## Scope

This smoke covers a source-backed open gap from the persisted item inventory:
`ResponseItem::ToolSearchCall` and `ResponseItem::ToolSearchOutput`. It proves
that the original backend and `.chat` backend both persist the same tool-search
facts for this app-server path, and that `.chat` also exposes neutral
`tool_call` / `tool_output` timeline mappings linked to journal source
transport.

It does not prove subagent activity, inter-agent communication,
detached/interrupted review-mode variants, broader web-search parity, broader
dynamic tool variants, performance, or final user-indistinguishability. This
fixture treats dynamic discovery contents as out of scope: the persisted
`tool_search_output` may contain an empty `tools` array. Non-empty discovery
and `tool_search` advertisement are tracked as separate open coverage.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- both runs made exactly two Responses requests: `{summary['mock_response_request_count_is_two']}`
- first request advertised `tool_search`: `{summary['mock_tool_search_visible_in_first_request']}` (observed only; not required by this smoke)
- deferred dynamic tool was hidden before search: `{summary['mock_deferred_tool_hidden_before_search']}` (observed only; not required by this smoke)
- second request carried `tool_search_output`: `{summary['mock_tool_search_output_reaches_second_request']}`
- second request carried discovered tool name: `{summary['mock_tool_search_output_contains_tool_name']}` (observed only; non-empty discovery is out of scope)
- original rollout has expected `tool_search_call`: `{summary['original_has_tool_search_call']}`
- original rollout has expected `tool_search_output`: `{summary['original_has_tool_search_output']}`
- `.chat` journal has expected `tool_search_call`: `{summary['chat_journal_has_tool_search_call']}`
- `.chat` journal has expected `tool_search_output`: `{summary['chat_journal_has_tool_search_output']}`
- call counts equal: `{summary['tool_search_call_counts_equal']}`
- output counts equal: `{summary['tool_search_output_counts_equal']}`
- call ids equal: `{summary['tool_search_call_ids_equal']}`
- output call ids equal: `{summary['tool_search_output_call_ids_equal']}`
- search queries equal: `{summary['tool_search_queries_equal']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- `.chat` timeline has neutral tool-search call mapping: `{summary['chat_timeline_has_tool_search_call_mapping']}`
- `.chat` timeline has neutral tool-search output mapping: `{summary['chat_timeline_has_tool_search_output_mapping']}`

## Normalized Thread Read

```json
{json.dumps({'original': original_read, 'chat-backend': chat_read}, indent=2, sort_keys=True)}
```

## Original Tool Search Storage

```json
{json.dumps(original_storage, indent=2, sort_keys=True)}
```

## `.chat` Tool Search Storage

```json
{json.dumps(chat_storage, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/tool-search-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/tool-search-response.json
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
        and summary["mock_response_request_count_is_two"]
        and summary["mock_tool_search_output_reaches_second_request"]
        and summary["original_has_tool_search_call"]
        and summary["original_has_tool_search_output"]
        and summary["chat_journal_has_tool_search_call"]
        and summary["chat_journal_has_tool_search_output"]
        and summary["tool_search_call_counts_equal"]
        and summary["tool_search_output_counts_equal"]
        and summary["tool_search_call_ids_equal"]
        and summary["tool_search_output_call_ids_equal"]
        and summary["tool_search_queries_equal"]
        and summary["line_counts_equal"]
        and summary["chat_timeline_has_tool_search_call_mapping"]
        and summary["chat_timeline_has_tool_search_output_mapping"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
