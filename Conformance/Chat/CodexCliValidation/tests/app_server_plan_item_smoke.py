#!/usr/bin/env python3
"""Run app-server plan ItemCompleted parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers the persisted
`EventMsg::ItemCompleted` path for `TurnItem::Plan`, proving that the original
backend and `.chat` backend keep the same durable plan completion fact.
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
)


USER_TEXT = "Plan this .chat validation task."
PLAN_TEXT = "# Final plan\n- first\n- second\n"
FULL_MESSAGE = f"Preface\n<proposed_plan>\n{PLAN_TEXT}</proposed_plan>\nPostscript"


def sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def ev_response_created(response_id: str) -> dict[str, Any]:
    return {"type": "response.created", "response": {"id": response_id}}


def ev_message_item_added(message_id: str, text: str) -> dict[str, Any]:
    return {
        "type": "response.output_item.added",
        "item": {
            "type": "message",
            "role": "assistant",
            "id": message_id,
            "content": [{"type": "output_text", "text": text}],
        },
    }


def ev_output_text_delta(delta: str) -> dict[str, Any]:
    return {"type": "response.output_text.delta", "delta": delta}


def ev_assistant_message(message_id: str, text: str) -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "message",
            "role": "assistant",
            "id": message_id,
            "content": [{"type": "output_text", "text": text}],
        },
    }


def ev_completed(response_id: str) -> dict[str, Any]:
    return {
        "type": "response.completed",
        "response": {
            "id": response_id,
            "usage": {
                "input_tokens": 11,
                "input_tokens_details": None,
                "output_tokens": 17,
                "output_tokens_details": None,
                "total_tokens": 28,
            },
        },
    }


def plan_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_message_item_added("msg-plan-smoke", ""),
            ev_output_text_delta(FULL_MESSAGE),
            ev_assistant_message("msg-plan-smoke", FULL_MESSAGE),
            ev_completed(response_id),
        ]
    )


class PlanResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FULL_MESSAGE)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        return plan_sse_response(f"resp-plan-smoke-{counter}")

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
                "request_mentions_plan_mode": any("proposed_plan" in body for body in serialized),
            }
        )
        return base


def write_plan_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write("\n[features]\ncollaboration_modes = true\n")


def send_plan_turn_start(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    start_index = len(client.received)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": "client-user-message-plan-item-smoke",
                "input": [
                    {
                        "type": "text",
                        "text": USER_TEXT,
                        "textElements": [],
                    }
                ],
                "collaborationMode": {
                    "mode": "plan",
                    "settings": {
                        "model": "mock-model",
                        "reasoning_effort": None,
                        "developer_instructions": None,
                    },
                },
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications = [
        message for message in client.received[start_index:] if message.get("method")
    ]
    notification_errors: list[str] = []
    if "error" not in response and not any(
        message.get("method") == "turn/completed" for message in notifications
    ):
        while True:
            try:
                message = client.receive_until(
                    lambda payload: payload.get("method") is not None,
                    60,
                    "turn notification",
                )
            except TimeoutError as exc:
                notification_errors.append(str(exc))
                break
            notifications.append(message)
            if message.get("method") == "turn/completed":
                break
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def normalize_plan_notifications(turn_start_result: dict[str, Any]) -> dict[str, Any]:
    notifications = turn_start_result.get("notifications") or []
    completed_items = []
    plan_delta_texts = []
    turn_status = None
    for message in notifications:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/completed":
            completed_items.append(params.get("item") or {})
        elif method == "item/plan/delta":
            plan_delta_texts.append(params.get("delta"))
        elif method == "turn/completed":
            status = (params.get("turn") or {}).get("status")
            turn_status = status.get("type") if isinstance(status, dict) else status

    plan_items = [item for item in completed_items if item.get("type") == "plan"]
    agent_items = [item for item in completed_items if item.get("type") == "agentMessage"]
    return {
        "has_error": "error" in turn_start_result.get("response", {}),
        "notification_methods": [message.get("method") for message in notifications],
        "completed_item_types": [item.get("type") for item in completed_items],
        "plan_item_count": len(plan_items),
        "agent_message_item_count": len(agent_items),
        "plan_texts": [item.get("text") for item in plan_items],
        "plan_delta_joined": "".join(text or "" for text in plan_delta_texts),
        "turn_status": turn_status,
    }


def normalize_thread_read_for_plan(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    item_types_by_turn = []
    item_count_by_turn = []
    plan_texts = []
    agent_message_texts = []
    user_message_texts = []
    for turn in turns:
        items = turn.get("items") or []
        item_count_by_turn.append(len(items))
        item_types_by_turn.append([item.get("type") for item in items])
        for item in items:
            item_type = item.get("type")
            if item_type == "plan":
                plan_texts.append(item.get("text"))
            elif item_type == "agentMessage":
                agent_message_texts.append(item.get("text"))
            elif item_type == "userMessage":
                for content in item.get("content") or []:
                    if content.get("type") == "text":
                        user_message_texts.append(content.get("text"))
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
        "contains_user_text": USER_TEXT in user_message_texts,
        "contains_plan_text": PLAN_TEXT in plan_texts,
        "agent_message_texts": agent_message_texts,
        "plan_texts": plan_texts,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_rollout_plan_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    event_msg_types: list[str] = []
    response_types: list[str] = []
    plan_completed_texts: list[str] = []
    agent_message_texts: list[str] = []
    item_completed_types: list[str] = []

    for item in items:
        top_type = item.get("type")
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        if top_type == "response_item":
            response_types.append(nested_type)
            if nested_type in {"message", "agent_message"}:
                for content in payload.get("content") or []:
                    text = content.get("text")
                    if text is not None:
                        agent_message_texts.append(text)
        elif top_type == "event_msg":
            event_msg_types.append(nested_type)
            if nested_type == "item_completed":
                completed_item = payload.get("item") or {}
                item_completed_types.append(completed_item.get("type"))
                if completed_item.get("type") in {"Plan", "plan"}:
                    plan_completed_texts.append(completed_item.get("text"))

    return {
        "line_count": len(items),
        "response_types": response_types,
        "event_msg_types": event_msg_types,
        "item_completed_types": item_completed_types,
        "plan_item_completed_count": len(plan_completed_texts),
        "plan_completed_texts": plan_completed_texts,
        "contains_plan_item_completed": PLAN_TEXT in plan_completed_texts,
        "contains_full_message_response": FULL_MESSAGE in agent_message_texts,
    }


def summarize_original_plan_storage(codex_home: pathlib.Path) -> dict[str, Any]:
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
    summary = summarize_rollout_plan_sources(all_items)
    summary.update(
        {
            "codex_home": str(codex_home),
            "rollouts": rollouts,
        }
    )
    return summary


def summarize_chat_plan_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_rollout_plan_sources([]),
            "timeline": {},
        }
    package = packages[0]
    journal_lines = read_json_lines(package / "journal.ndjson")
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_lines = read_json_lines(package / "timeline.ndjson")
    timeline_source_response_types = [
        ((line.get("body") or {}).get("source_response_type")) for line in timeline_lines
    ]
    timeline_summary = {
        "line_count": len(timeline_lines),
        "event_types": [line.get("type") for line in timeline_lines],
        "source_response_types": timeline_source_response_types,
        "item_completed_status_event_count": sum(
            1 for value in timeline_source_response_types if value == "item_completed"
        ),
    }
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "package": str(package),
        "journal": summarize_rollout_plan_sources(source_items),
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

    with PlanResponsesServer() as mock_server:
        write_plan_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                client,
                2,
                workspace,
            )
            turn_start_result = send_plan_turn_start(client, 3, started_thread_id)
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
            "normalized_plan_notifications": normalize_plan_notifications(
                turn_start_result
            ),
            "normalized_thread_read": normalize_thread_read_for_plan(
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
            result["chat_plan_storage"] = summarize_chat_plan_package(chat_root)
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
            result["original_plan_storage"] = summarize_original_plan_storage(
                codex_home
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-plan-item-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_plan = original_result["original_plan_storage"]
    chat_plan = chat_result["chat_plan_storage"]
    chat_journal = chat_plan["journal"]
    chat_timeline = chat_plan["timeline"]
    original_notifications = original_result["normalized_plan_notifications"]
    chat_notifications = chat_result["normalized_plan_notifications"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-plan-item-smoke",
        "binary_checks": binary_checks,
        "original_turn_start_exit_ok": "result"
        in original_result["turn_start_result"]["response"],
        "chat_backend_turn_start_exit_ok": "result"
        in chat_result["turn_start_result"]["response"],
        "original_thread_read_exit_ok": "result" in original_result["thread_read_response"],
        "chat_backend_thread_read_exit_ok": "result" in chat_result["thread_read_response"],
        "normalized_plan_notifications_equal": original_notifications == chat_notifications,
        "normalized_thread_read_equal": original_read == chat_read,
        "normalized_thread_list_equal": original_list == chat_list,
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
        ),
        "original_has_plan_item_completed": original_plan["contains_plan_item_completed"],
        "chat_journal_has_plan_item_completed": chat_journal[
            "contains_plan_item_completed"
        ],
        "plan_item_completed_counts_equal": original_plan["plan_item_completed_count"]
        == chat_journal["plan_item_completed_count"],
        "plan_completed_texts_equal": original_plan["plan_completed_texts"]
        == chat_journal["plan_completed_texts"],
        "original_has_full_message_response": original_plan[
            "contains_full_message_response"
        ],
        "chat_journal_has_full_message_response": chat_journal[
            "contains_full_message_response"
        ],
        "line_counts_equal": original_plan["line_count"] == chat_journal["line_count"],
        "chat_timeline_has_item_completed_mapping": chat_timeline.get(
            "item_completed_status_event_count",
            0,
        )
        >= 1,
        "original_normalized_plan_notifications": original_notifications,
        "chat_backend_normalized_plan_notifications": chat_notifications,
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_plan_storage": original_plan,
        "chat_plan_storage": chat_plan,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "sleep ItemCompleted parity",
            "review mode events",
            "subagent activity",
            "goal/runtime status replay",
            "complete source transport inventory",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/plan-item-response.json", original_result)
    write_json(output_dir / "chat-backend/plan-item-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Plan Item Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that emits a Plan-mode assistant message containing
`<proposed_plan>`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and persisted item inventory were read.

## Scope

This smoke covers a source-backed open gap from the persisted item inventory:
`EventMsg::ItemCompleted` for `TurnItem::Plan`. It proves that the original
backend and `.chat` backend both persist the same completed plan item for this
app-server path, and that `.chat` also exposes a neutral timeline mapping linked
to journal source transport.

It does not prove sleep `ItemCompleted`, review mode, subagent activity,
goal/runtime status replay, full source-transport inventory, or final
user-indistinguishability.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- original `thread/read` response succeeded: `{summary['original_thread_read_exit_ok']}`
- `.chat` backend `thread/read` response succeeded: `{summary['chat_backend_thread_read_exit_ok']}`
- normalized original vs `.chat` plan notifications equal: `{summary['normalized_plan_notifications_equal']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- original rollout has expected plan `ItemCompleted`: `{summary['original_has_plan_item_completed']}`
- `.chat` journal has expected plan `ItemCompleted`: `{summary['chat_journal_has_plan_item_completed']}`
- plan `ItemCompleted` counts equal: `{summary['plan_item_completed_counts_equal']}`
- plan completed texts equal: `{summary['plan_completed_texts_equal']}`
- original rollout has full assistant message response: `{summary['original_has_full_message_response']}`
- `.chat` journal has full assistant message response: `{summary['chat_journal_has_full_message_response']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- `.chat` timeline has neutral item-completed mapping: `{summary['chat_timeline_has_item_completed_mapping']}`

## Normalized Plan Notifications

```json
{json.dumps({'original': original_notifications, 'chat-backend': chat_notifications}, indent=2, sort_keys=True)}
```

## Normalized Thread Read

```json
{json.dumps({'original': original_read, 'chat-backend': chat_read}, indent=2, sort_keys=True)}
```

## Original Plan Storage

```json
{json.dumps(original_plan, indent=2, sort_keys=True)}
```

## `.chat` Plan Storage

```json
{json.dumps(chat_plan, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/plan-item-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/plan-item-response.json
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
        and summary["normalized_plan_notifications_equal"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["original_has_plan_item_completed"]
        and summary["chat_journal_has_plan_item_completed"]
        and summary["plan_item_completed_counts_equal"]
        and summary["plan_completed_texts_equal"]
        and summary["original_has_full_message_response"]
        and summary["chat_journal_has_full_message_response"]
        and summary["line_counts_equal"]
        and summary["chat_timeline_has_item_completed_mapping"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
