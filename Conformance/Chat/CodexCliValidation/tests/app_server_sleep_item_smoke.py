#!/usr/bin/env python3
"""Run app-server sleep ItemCompleted parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers the persisted
`EventMsg::ItemCompleted` path for `TurnItem::Sleep`, proving that the original
backend and `.chat` backend keep the same durable sleep completion fact.
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


USER_TEXT = "Sleep briefly for .chat validation."
ASSISTANT_TEXT = "Sleep complete from mock model."
CALL_ID = "sleep-item-smoke-1"
DURATION_MS = 2_000
CURRENT_TIME_AT = 1_781_717_655


def sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def ev_response_created(response_id: str) -> dict[str, Any]:
    return {"type": "response.created", "response": {"id": response_id}}


def ev_function_call_with_namespace(
    call_id: str,
    namespace: str,
    name: str,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "function_call",
            "call_id": call_id,
            "namespace": namespace,
            "name": name,
            "arguments": json.dumps(arguments, separators=(",", ":")),
        },
    }


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
                "input_tokens": 9,
                "input_tokens_details": None,
                "output_tokens": 12,
                "output_tokens_details": None,
                "total_tokens": 21,
            },
        },
    }


def sleep_tool_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_function_call_with_namespace(
                CALL_ID,
                "clock",
                "sleep",
                {"duration_ms": DURATION_MS},
            ),
            ev_completed(response_id),
        ]
    )


def final_answer_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_assistant_message("msg-sleep-item-smoke-final", ASSISTANT_TEXT),
            ev_completed(response_id),
        ]
    )


class SleepResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        response_id = f"resp-sleep-item-smoke-{counter}"
        if counter == 1:
            return sleep_tool_sse_response(response_id)
        return final_answer_sse_response(response_id)

    def summary(self) -> dict[str, Any]:
        base = super().summary()
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        serialized = [
            json.dumps(request["json"], ensure_ascii=False) for request in response_requests
        ]
        base.update(
            {
                "first_response_input_contains_user_text": any(
                    USER_TEXT in body for body in serialized[:1]
                ),
                "response_request_mentions_clock_namespace": any(
                    '"clock"' in body for body in serialized
                ),
                "response_request_count": len(response_requests),
            }
        )
        return base


def write_sleep_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write(
            "\n[features.current_time_reminder]\n"
            "enabled = true\n"
            "sleep_tool = true\n"
            'clock_source = "external"\n'
        )


def send_sleep_turn_start(
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
                "clientUserMessageId": "client-user-message-sleep-item-smoke",
                "input": [
                    {
                        "type": "text",
                        "text": USER_TEXT,
                        "textElements": [],
                    }
                ],
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications: list[dict[str, Any]] = [
        message for message in client.received[start_index:] if message.get("method")
    ]
    current_time_requests: list[dict[str, Any]] = []
    current_time_responses: list[dict[str, Any]] = []
    current_time_values = iter(
        [
            CURRENT_TIME_AT,
            CURRENT_TIME_AT,
            CURRENT_TIME_AT + 1,
            CURRENT_TIME_AT + 2,
            CURRENT_TIME_AT + 2,
        ]
    )
    notification_errors: list[str] = []

    while True:
        if any(message.get("method") == "turn/completed" for message in notifications):
            break
        try:
            message = client.receive_until(
                lambda payload: payload.get("method") is not None,
                45,
                "sleep turn notification or request",
            )
        except TimeoutError as exc:
            notification_errors.append(str(exc))
            break

        method = message.get("method")
        if method == "currentTime/read":
            params = message.get("params") or {}
            current_time_requests.append(
                {
                    "id": message.get("id"),
                    "thread_id": params.get("threadId"),
                }
            )
            try:
                current_time_at = next(current_time_values)
            except StopIteration:
                current_time_at = CURRENT_TIME_AT + 2
            response_message = {
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {"currentTimeAt": current_time_at},
            }
            current_time_responses.append(response_message)
            client.send(response_message)
        else:
            notifications.append(message)

    return {
        "response": response,
        "notifications": notifications,
        "current_time_requests": current_time_requests,
        "current_time_responses": current_time_responses,
        "notification_errors": notification_errors,
    }


def normalize_sleep_notifications(turn_start_result: dict[str, Any]) -> dict[str, Any]:
    notifications = turn_start_result.get("notifications") or []
    sleep_started_items = []
    sleep_completed_items = []
    agent_message_items = []
    turn_status = None
    for message in notifications:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/started":
            item = params.get("item") or {}
            if item.get("type") == "sleep":
                sleep_started_items.append(item)
        elif method == "item/completed":
            item = params.get("item") or {}
            if item.get("type") == "sleep":
                sleep_completed_items.append(item)
            elif item.get("type") == "agentMessage":
                agent_message_items.append(item)
        elif method == "turn/completed":
            status = (params.get("turn") or {}).get("status")
            turn_status = status.get("type") if isinstance(status, dict) else status

    return {
        "has_error": "error" in turn_start_result.get("response", {}),
        "notification_methods": [message.get("method") for message in notifications],
        "current_time_request_count": len(
            turn_start_result.get("current_time_requests") or []
        ),
        "current_time_response_values": [
            ((response.get("result") or {}).get("currentTimeAt"))
            for response in turn_start_result.get("current_time_responses") or []
        ],
        "sleep_started_count": len(sleep_started_items),
        "sleep_completed_count": len(sleep_completed_items),
        "sleep_started_items": sleep_started_items,
        "sleep_completed_items": sleep_completed_items,
        "agent_message_item_count": len(agent_message_items),
        "agent_message_texts": [item.get("text") for item in agent_message_items],
        "turn_status": turn_status,
    }


def normalize_thread_read_for_sleep(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    item_types_by_turn = []
    item_count_by_turn = []
    sleep_items = []
    agent_message_texts = []
    user_message_texts = []
    for turn in turns:
        items = turn.get("items") or []
        item_count_by_turn.append(len(items))
        item_types_by_turn.append([item.get("type") for item in items])
        for item in items:
            item_type = item.get("type")
            if item_type == "sleep":
                sleep_items.append(item)
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
        "contains_assistant_text": ASSISTANT_TEXT in agent_message_texts,
        "sleep_item_count": len(sleep_items),
        "sleep_items": sleep_items,
        "agent_message_texts": agent_message_texts,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_rollout_sleep_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    event_msg_types: list[str] = []
    response_types: list[str] = []
    sleep_completed_items: list[dict[str, Any]] = []
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
                if completed_item.get("type") in {"Sleep", "sleep"}:
                    sleep_completed_items.append(completed_item)

    return {
        "line_count": len(items),
        "response_types": response_types,
        "event_msg_types": event_msg_types,
        "item_completed_types": item_completed_types,
        "sleep_item_completed_count": len(sleep_completed_items),
        "sleep_completed_items": sleep_completed_items,
        "contains_sleep_item_completed": any(
            item.get("id") == CALL_ID
            and item.get("duration_ms", item.get("durationMs")) == DURATION_MS
            for item in sleep_completed_items
        ),
        "contains_final_assistant_message": ASSISTANT_TEXT in agent_message_texts,
    }


def summarize_original_sleep_storage(codex_home: pathlib.Path) -> dict[str, Any]:
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
    summary = summarize_rollout_sleep_sources(all_items)
    summary.update(
        {
            "codex_home": str(codex_home),
            "rollouts": rollouts,
        }
    )
    return summary


def summarize_chat_sleep_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_rollout_sleep_sources([]),
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
        "journal": summarize_rollout_sleep_sources(source_items),
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

    with SleepResponsesServer() as mock_server:
        write_sleep_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                client,
                2,
                workspace,
            )
            turn_start_result = send_sleep_turn_start(client, 3, started_thread_id)
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
            "normalized_sleep_notifications": normalize_sleep_notifications(
                turn_start_result
            ),
            "normalized_thread_read": normalize_thread_read_for_sleep(
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
            result["chat_sleep_storage"] = summarize_chat_sleep_package(chat_root)
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
            result["original_sleep_storage"] = summarize_original_sleep_storage(
                codex_home
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-sleep-item-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_sleep = original_result["original_sleep_storage"]
    chat_sleep = chat_result["chat_sleep_storage"]
    chat_journal = chat_sleep["journal"]
    chat_timeline = chat_sleep["timeline"]
    original_notifications = original_result["normalized_sleep_notifications"]
    chat_notifications = chat_result["normalized_sleep_notifications"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-sleep-item-smoke",
        "binary_checks": binary_checks,
        "original_turn_start_exit_ok": "result"
        in original_result["turn_start_result"]["response"],
        "chat_backend_turn_start_exit_ok": "result"
        in chat_result["turn_start_result"]["response"],
        "original_thread_read_exit_ok": "result" in original_result["thread_read_response"],
        "chat_backend_thread_read_exit_ok": "result" in chat_result["thread_read_response"],
        "normalized_sleep_notifications_equal": original_notifications == chat_notifications,
        "normalized_thread_read_equal": original_read == chat_read,
        "normalized_thread_list_equal": original_list == chat_list,
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
        ),
        "original_has_sleep_item_completed": original_sleep[
            "contains_sleep_item_completed"
        ],
        "chat_journal_has_sleep_item_completed": chat_journal[
            "contains_sleep_item_completed"
        ],
        "sleep_item_completed_counts_equal": original_sleep[
            "sleep_item_completed_count"
        ]
        == chat_journal["sleep_item_completed_count"],
        "sleep_completed_items_equal": original_sleep["sleep_completed_items"]
        == chat_journal["sleep_completed_items"],
        "original_has_final_assistant_message": original_sleep[
            "contains_final_assistant_message"
        ],
        "chat_journal_has_final_assistant_message": chat_journal[
            "contains_final_assistant_message"
        ],
        "line_counts_equal": original_sleep["line_count"] == chat_journal["line_count"],
        "chat_timeline_has_item_completed_mapping": chat_timeline.get(
            "item_completed_status_event_count",
            0,
        )
        >= 1,
        "original_normalized_sleep_notifications": original_notifications,
        "chat_backend_normalized_sleep_notifications": chat_notifications,
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_sleep_storage": original_sleep,
        "chat_sleep_storage": chat_sleep,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "review mode events",
            "subagent activity",
            "goal/runtime status replay",
            "tool-search and broad web-search parity",
            "complete source transport inventory",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/sleep-item-response.json", original_result)
    write_json(output_dir / "chat-backend/sleep-item-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Sleep Item Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that emits a `clock.sleep` function call through the namespace
tool path.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and persisted item inventory were read.

## Scope

This smoke covers a source-backed open gap from the persisted item inventory:
`EventMsg::ItemCompleted` for `TurnItem::Sleep`. It proves that the original
backend and `.chat` backend both persist the same completed sleep item for this
app-server path, and that `.chat` also exposes a neutral timeline mapping linked
to journal source transport.

It does not prove review mode, subagent activity, goal/runtime status replay,
full source-transport inventory, or final user-indistinguishability.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- original `thread/read` response succeeded: `{summary['original_thread_read_exit_ok']}`
- `.chat` backend `thread/read` response succeeded: `{summary['chat_backend_thread_read_exit_ok']}`
- normalized original vs `.chat` sleep notifications equal: `{summary['normalized_sleep_notifications_equal']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- original rollout has expected sleep `ItemCompleted`: `{summary['original_has_sleep_item_completed']}`
- `.chat` journal has expected sleep `ItemCompleted`: `{summary['chat_journal_has_sleep_item_completed']}`
- sleep `ItemCompleted` counts equal: `{summary['sleep_item_completed_counts_equal']}`
- sleep completed items equal: `{summary['sleep_completed_items_equal']}`
- original rollout has final assistant message response: `{summary['original_has_final_assistant_message']}`
- `.chat` journal has final assistant message response: `{summary['chat_journal_has_final_assistant_message']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- `.chat` timeline has neutral item-completed mapping: `{summary['chat_timeline_has_item_completed_mapping']}`

## Normalized Sleep Notifications

```json
{json.dumps({'original': original_notifications, 'chat-backend': chat_notifications}, indent=2, sort_keys=True)}
```

## Normalized Thread Read

```json
{json.dumps({'original': original_read, 'chat-backend': chat_read}, indent=2, sort_keys=True)}
```

## Original Sleep Storage

```json
{json.dumps(original_sleep, indent=2, sort_keys=True)}
```

## `.chat` Sleep Storage

```json
{json.dumps(chat_sleep, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/sleep-item-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/sleep-item-response.json
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
        and summary["normalized_sleep_notifications_equal"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["original_has_sleep_item_completed"]
        and summary["chat_journal_has_sleep_item_completed"]
        and summary["sleep_item_completed_counts_equal"]
        and summary["sleep_completed_items_equal"]
        and summary["original_has_final_assistant_message"]
        and summary["chat_journal_has_final_assistant_message"]
        and summary["line_counts_equal"]
        and summary["chat_timeline_has_item_completed_mapping"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
