#!/usr/bin/env python3
"""Run app-server reasoning persistence parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers source-backed reasoning records
that original Codex persists and verifies that the `.chat` backend keeps the
same durable facts in journal source transport while mapping them into the
neutral timeline.
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


USER_TEXT = "Persist reasoning summary and raw reasoning for .chat validation."
ASSISTANT_TEXT = "Reasoning persistence final answer from mock model."
REASONING_SUMMARY_TEXTS = [
    "Reasoning summary alpha for persistence.",
    "Reasoning summary beta for persistence.",
]
REASONING_RAW_TEXTS = [
    "Raw reasoning detail one for persistence.",
    "Raw reasoning detail two for persistence.",
]
REASONING_ID = "rsn-msp-chat-validation"


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
                "input_tokens": 13,
                "input_tokens_details": {"cached_tokens": 3},
                "output_tokens": 21,
                "output_tokens_details": {"reasoning_tokens": 8},
                "total_tokens": 34,
            },
        },
    }


def reasoning_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "reasoning",
                    "id": REASONING_ID,
                    "summary": [
                        {"type": "summary_text", "text": text}
                        for text in REASONING_SUMMARY_TEXTS
                    ],
                    "content": [
                        {"type": "reasoning_text", "text": REASONING_RAW_TEXTS[0]},
                        {"type": "text", "text": REASONING_RAW_TEXTS[1]},
                    ],
                    "encrypted_content": "encrypted-reasoning-marker",
                },
            },
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-reasoning-smoke-final",
                    "content": [{"type": "output_text", "text": ASSISTANT_TEXT}],
                },
            },
            ev_completed(response_id),
        ]
    )


class ReasoningResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        return reasoning_sse_response(f"resp-reasoning-smoke-{counter}")

    def summary(self) -> dict[str, Any]:
        base = super().summary()
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        serialized = [json.dumps(request["json"], ensure_ascii=False) for request in response_requests]
        base.update(
            {
                "first_response_input_contains_user_text": any(
                    USER_TEXT in body for body in serialized[:1]
                ),
                "request_mentions_reasoning_summary_config": any(
                    "reasoning" in body and "summary" in body for body in serialized
                ),
            }
        )
        return base


def append_reasoning_config(codex_home: pathlib.Path) -> None:
    write_mock_config(codex_home, "http://127.0.0.1:1")
    # Caller rewrites the provider URL immediately after this helper in run_tree.


def write_reasoning_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write(
            "\nshow_raw_agent_reasoning = true\n"
            "hide_agent_reasoning = false\n"
            'model_reasoning_summary = "detailed"\n'
            'model_reasoning_effort = "high"\n'
        )


def normalize_thread_read_for_reasoning(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    item_types_by_turn = []
    item_count_by_turn = []
    serialized = json.dumps(turns, ensure_ascii=False)
    for turn in turns:
        items = turn.get("items") or []
        item_count_by_turn.append(len(items))
        item_types_by_turn.append([item.get("type") for item in items])
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": [
            (turn.get("status") or {}).get("type")
            if isinstance(turn.get("status"), dict)
            else turn.get("status")
            for turn in turns
        ],
        "item_count_by_turn": item_count_by_turn,
        "item_types_by_turn": item_types_by_turn,
        "contains_user_text": USER_TEXT in serialized,
        "contains_assistant_text": ASSISTANT_TEXT in serialized,
        "contains_reasoning_summary": all(
            text in serialized for text in REASONING_SUMMARY_TEXTS
        ),
        "contains_raw_reasoning": all(text in serialized for text in REASONING_RAW_TEXTS),
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_rollout_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    response_types: list[str] = []
    event_msg_types: list[str] = []
    reasoning_response_items: list[dict[str, Any]] = []
    agent_reasoning_texts: list[str] = []
    agent_reasoning_raw_texts: list[str] = []

    for item in items:
        top_type = item.get("type")
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        if top_type == "response_item":
            response_types.append(nested_type)
            if nested_type == "reasoning":
                reasoning_response_items.append(payload)
        elif top_type == "event_msg":
            event_msg_types.append(nested_type)
            if nested_type == "agent_reasoning":
                agent_reasoning_texts.append(payload.get("text"))
            elif nested_type == "agent_reasoning_raw_content":
                agent_reasoning_raw_texts.append(payload.get("text"))

    reasoning_summary_texts = []
    reasoning_raw_texts = []
    encrypted_content_values = []
    for item in reasoning_response_items:
        for summary in item.get("summary") or []:
            reasoning_summary_texts.append(summary.get("text"))
        for content in item.get("content") or []:
            reasoning_raw_texts.append(content.get("text"))
        encrypted_content_values.append(item.get("encrypted_content"))

    return {
        "line_count": len(items),
        "response_types": response_types,
        "event_msg_types": event_msg_types,
        "reasoning_response_item_count": len(reasoning_response_items),
        "reasoning_summary_texts": reasoning_summary_texts,
        "reasoning_raw_texts": reasoning_raw_texts,
        "encrypted_content_values": encrypted_content_values,
        "agent_reasoning_texts": agent_reasoning_texts,
        "agent_reasoning_raw_texts": agent_reasoning_raw_texts,
        "has_expected_reasoning_summary": all(
            text in reasoning_summary_texts for text in REASONING_SUMMARY_TEXTS
        ),
        "has_expected_reasoning_raw": all(
            text in reasoning_raw_texts for text in REASONING_RAW_TEXTS
        ),
        "has_expected_agent_reasoning_event": all(
            text in agent_reasoning_texts for text in REASONING_SUMMARY_TEXTS
        ),
        "has_expected_raw_reasoning_event": all(
            text in agent_reasoning_raw_texts for text in REASONING_RAW_TEXTS
        ),
    }


def summarize_original_reasoning_storage(codex_home: pathlib.Path) -> dict[str, Any]:
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
    summary = summarize_rollout_sources(all_items)
    summary.update(
        {
            "codex_home": str(codex_home),
            "rollouts": rollouts,
        }
    )
    return summary


def summarize_chat_reasoning_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_rollout_sources([]),
            "timeline": {},
        }
    package = packages[0]
    journal_lines = read_json_lines(package / "journal.ndjson")
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_lines = read_json_lines(package / "timeline.ndjson")
    timeline_source_response_types = [
        ((line.get("body") or {}).get("source_response_type")) for line in timeline_lines
    ]
    timeline_source_types = [
        ((line.get("body") or {}).get("source_type")) for line in timeline_lines
    ]
    timeline_summary = {
        "line_count": len(timeline_lines),
        "event_types": [line.get("type") for line in timeline_lines],
        "source_types": timeline_source_types,
        "source_response_types": timeline_source_response_types,
        "reasoning_response_event_count": sum(
            1 for value in timeline_source_response_types if value == "reasoning"
        ),
        "agent_reasoning_status_event_count": sum(
            1 for value in timeline_source_response_types if value == "agent_reasoning"
        ),
        "raw_reasoning_status_event_count": sum(
            1
            for value in timeline_source_response_types
            if value == "agent_reasoning_raw_content"
        ),
    }
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "package": str(package),
        "journal": summarize_rollout_sources(source_items),
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

    with ReasoningResponsesServer() as mock_server:
        write_reasoning_mock_config(codex_home, mock_server.url)
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
                "client-user-message-reasoning-smoke",
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
            "normalized_thread_read": normalize_thread_read_for_reasoning(
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
            result["chat_reasoning_storage"] = summarize_chat_reasoning_package(chat_root)
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
            result["original_reasoning_storage"] = summarize_original_reasoning_storage(
                codex_home
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-reasoning-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        config_overrides=["show_raw_agent_reasoning=true"],
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            "show_raw_agent_reasoning=true",
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_reasoning = original_result["original_reasoning_storage"]
    chat_reasoning = chat_result["chat_reasoning_storage"]
    chat_journal = chat_reasoning["journal"]
    chat_timeline = chat_reasoning["timeline"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-reasoning-smoke",
        "binary_checks": binary_checks,
        "original_turn_start_exit_ok": "result"
        in original_result["turn_start_result"]["response"],
        "chat_backend_turn_start_exit_ok": "result"
        in chat_result["turn_start_result"]["response"],
        "original_thread_read_exit_ok": "result" in original_result["thread_read_response"],
        "chat_backend_thread_read_exit_ok": "result" in chat_result["thread_read_response"],
        "normalized_thread_read_equal": original_read == chat_read,
        "normalized_thread_list_equal": original_list == chat_list,
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
        ),
        "original_has_reasoning_response_item": original_reasoning[
            "has_expected_reasoning_summary"
        ]
        and original_reasoning["has_expected_reasoning_raw"],
        "chat_journal_has_reasoning_response_item": chat_journal[
            "has_expected_reasoning_summary"
        ]
        and chat_journal["has_expected_reasoning_raw"],
        "original_has_reasoning_events": original_reasoning[
            "has_expected_agent_reasoning_event"
        ]
        and original_reasoning["has_expected_raw_reasoning_event"],
        "chat_journal_has_reasoning_events": chat_journal[
            "has_expected_agent_reasoning_event"
        ]
        and chat_journal["has_expected_raw_reasoning_event"],
        "reasoning_response_item_count_equal": original_reasoning[
            "reasoning_response_item_count"
        ]
        == chat_journal["reasoning_response_item_count"],
        "agent_reasoning_event_texts_equal": original_reasoning[
            "agent_reasoning_texts"
        ]
        == chat_journal["agent_reasoning_texts"],
        "agent_reasoning_raw_texts_equal": original_reasoning[
            "agent_reasoning_raw_texts"
        ]
        == chat_journal["agent_reasoning_raw_texts"],
        "line_counts_equal": original_reasoning["line_count"] == chat_journal["line_count"],
        "chat_timeline_has_reasoning_mapping": chat_timeline.get(
            "reasoning_response_event_count",
            0,
        )
        >= 1,
        "chat_timeline_has_reasoning_event_statuses": chat_timeline.get(
            "agent_reasoning_status_event_count",
            0,
        )
        >= len(REASONING_SUMMARY_TEXTS)
        and chat_timeline.get("raw_reasoning_status_event_count", 0)
        >= len(REASONING_RAW_TEXTS),
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_reasoning_storage": original_reasoning,
        "chat_reasoning_storage": chat_reasoning,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "review mode events",
            "subagent activity",
            "plan/sleep ItemCompleted parity",
            "goal/runtime status replay",
            "complete source transport inventory",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/reasoning-response.json", original_result)
    write_json(output_dir / "chat-backend/reasoning-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Reasoning Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that emits one `ResponseItem::Reasoning` with summary text, raw
reasoning content, encrypted content, and a final assistant message.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and persisted item inventory were read.

## Scope

This smoke covers a source-backed open gap from the persisted item inventory:
reasoning records, `AgentReasoning`, and `AgentReasoningRawContent`. It proves
that the original backend and `.chat` backend both persist the same reasoning
facts for this app-server path, and that `.chat` also exposes a neutral timeline
mapping linked to journal source transport.

It does not prove review mode, subagent activity, plan/sleep `ItemCompleted`,
goal/runtime status replay, full source-transport inventory, or final
user-indistinguishability.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- original `thread/read` response succeeded: `{summary['original_thread_read_exit_ok']}`
- `.chat` backend `thread/read` response succeeded: `{summary['chat_backend_thread_read_exit_ok']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- original rollout has expected reasoning response item: `{summary['original_has_reasoning_response_item']}`
- `.chat` journal has expected reasoning response item: `{summary['chat_journal_has_reasoning_response_item']}`
- original rollout has expected reasoning legacy events: `{summary['original_has_reasoning_events']}`
- `.chat` journal has expected reasoning legacy events: `{summary['chat_journal_has_reasoning_events']}`
- reasoning response item counts equal: `{summary['reasoning_response_item_count_equal']}`
- reasoning summary event texts equal: `{summary['agent_reasoning_event_texts_equal']}`
- raw reasoning event texts equal: `{summary['agent_reasoning_raw_texts_equal']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- `.chat` timeline has neutral reasoning response mapping: `{summary['chat_timeline_has_reasoning_mapping']}`
- `.chat` timeline has reasoning status mappings: `{summary['chat_timeline_has_reasoning_event_statuses']}`

## Normalized Thread Read

```json
{json.dumps({'original': original_read, 'chat-backend': chat_read}, indent=2, sort_keys=True)}
```

## Original Reasoning Storage

```json
{json.dumps(original_reasoning, indent=2, sort_keys=True)}
```

## `.chat` Reasoning Storage

```json
{json.dumps(chat_reasoning, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/reasoning-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/reasoning-response.json
```
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return (
        0
        if summary["original_turn_start_exit_ok"]
        and summary["chat_backend_turn_start_exit_ok"]
        and summary["original_thread_read_exit_ok"]
        and summary["chat_backend_thread_read_exit_ok"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["original_has_reasoning_response_item"]
        and summary["chat_journal_has_reasoning_response_item"]
        and summary["original_has_reasoning_events"]
        and summary["chat_journal_has_reasoning_events"]
        and summary["reasoning_response_item_count_equal"]
        and summary["agent_reasoning_event_texts_equal"]
        and summary["agent_reasoning_raw_texts_equal"]
        and summary["line_counts_equal"]
        and summary["chat_timeline_has_reasoning_mapping"]
        and summary["chat_timeline_has_reasoning_event_statuses"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
