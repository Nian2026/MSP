#!/usr/bin/env python3
"""Run active-turn rollback parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers a narrow RB04 slice: attempt
`thread/rollback` while a turn is in progress, verify both backends reject the
request the same way, then let the turn complete and verify no rollback marker
was persisted and final history remains intact.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import time
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
    sse_response,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_rollback_smoke import (  # noqa: E402
    count_rollback_markers,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_rollback,
    send_thread_start,
    storage_line_counts,
    timeline_event_count,
)


SEED_USER_TEXT = "Active rollback seed turn."
ACTIVE_USER_TEXT = "Active rollback running turn."
SEED_ASSISTANT_TEXT = "Active rollback seed answer from mock model."
ACTIVE_ASSISTANT_TEXT = "Active rollback delayed answer from mock model."
ROLLBACK_ACTIVE_ERROR_TEXT = "Cannot rollback while a turn is in progress."


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


class DelayedActiveRollbackMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ACTIVE_ASSISTANT_TEXT)
        self._responses = [
            (SEED_ASSISTANT_TEXT, 0.0),
            (ACTIVE_ASSISTANT_TEXT, 2.0),
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        index = min(counter - 1, len(self._responses) - 1)
        answer_text, delay_seconds = self._responses[index]
        if delay_seconds:
            time.sleep(delay_seconds)
        return sse_response(
            f"resp-active-rollback-smoke-{counter}",
            f"msg-active-rollback-smoke-{counter}",
            answer_text,
        )

    def summary(self) -> dict[str, Any]:
        bodies = response_request_bodies(self.requests)
        first_body = bodies[0] if len(bodies) > 0 else {}
        second_body = bodies[1] if len(bodies) > 1 else {}
        return {
            "request_count": len(self.requests),
            "response_request_count": len(bodies),
            "paths": [request["path"] for request in self.requests],
            "first_response_input_contains_seed_user_text": response_input_contains(
                first_body,
                SEED_USER_TEXT,
            ),
            "second_response_input_contains_seed_user_text": response_input_contains(
                second_body,
                SEED_USER_TEXT,
            ),
            "second_response_input_contains_seed_assistant_text": response_input_contains(
                second_body,
                SEED_ASSISTANT_TEXT,
            ),
            "second_response_input_contains_active_user_text": response_input_contains(
                second_body,
                ACTIVE_USER_TEXT,
            ),
        }


def send_turn_start_response_only(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    client_user_message_id: str,
    text: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": client_user_message_id,
                "input": [
                    {
                        "type": "text",
                        "text": text,
                        "textElements": [],
                    }
                ],
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def receive_method_since(
    client: JsonRpcClient,
    method: str,
    since_index: int,
    timeout_seconds: int,
) -> dict[str, Any]:
    for message in client.received[since_index:]:
        if message.get("method") == method:
            return message
    return client.receive_until_method(method, timeout_seconds=timeout_seconds)


def thread_from_response(response: dict[str, Any]) -> dict[str, Any]:
    return (response.get("result") or {}).get("thread") or {}


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": thread.get("model"),
        "model_provider": thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_seed_user_text": SEED_USER_TEXT in serialized_turns,
        "contains_active_user_text": ACTIVE_USER_TEXT in serialized_turns,
        "contains_seed_assistant_text": SEED_ASSISTANT_TEXT in serialized_turns,
        "contains_active_assistant_text": ACTIVE_ASSISTANT_TEXT in serialized_turns,
    }


def normalize_rollback_error(rollback_result: dict[str, Any]) -> dict[str, Any]:
    response = rollback_result["response"]
    error = response.get("error") or {}
    message = error.get("message") or ""
    methods = rollback_result.get("notification_methods_after_request") or []
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message": message,
        "message_contains_active_turn_error": ROLLBACK_ACTIVE_ERROR_TEXT in message,
        "deprecation_notice_seen": "deprecationNotice" in methods,
        "thread_rolled_back_notification_seen": "thread/rolledBack" in methods,
        "notification_methods_after_request": methods,
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    ids = {thread.get("id") for thread in threads}
    target = next((thread for thread in threads if thread.get("id") == thread_id), None)
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_thread": thread_id in ids if thread_id is not None else False,
        "target_preview": (target or {}).get("preview"),
        "target_status_type": status_type((target or {}).get("status")),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def tree_storage_summary(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return summarize_chat_packages(chat_root)
    return summarize_original_storage(codex_home)


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

    with DelayedActiveRollbackMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)

            seed_turn_response = send_turn_start_response_only(
                client,
                3,
                thread_id,
                "client-user-message-active-rollback-seed",
                SEED_USER_TEXT,
            )
            seed_turn_started = client.receive_until_method(
                "turn/started",
                timeout_seconds=30,
            )
            seed_turn_completed = client.receive_until_method(
                "turn/completed",
                timeout_seconds=60,
            )

            active_turn_response = send_turn_start_response_only(
                client,
                4,
                thread_id,
                "client-user-message-active-rollback-running",
                ACTIVE_USER_TEXT,
            )
            active_notifications_start = len(client.received)
            active_turn_started = client.receive_until_method(
                "turn/started",
                timeout_seconds=30,
            )
            active_item_completed = receive_method_since(
                client,
                "item/completed",
                active_notifications_start,
                timeout_seconds=30,
            )

            read_while_active_response = send_thread_read(client, 5, thread_id)
            storage_before_rollback_attempt = tree_storage_summary(
                tree_name,
                codex_home,
                chat_root,
            )

            rollback_attempt = send_thread_rollback(client, 6, thread_id, 1)
            storage_after_rollback_attempt = tree_storage_summary(
                tree_name,
                codex_home,
                chat_root,
            )

            active_turn_completed = receive_method_since(
                client,
                "turn/completed",
                active_notifications_start,
                timeout_seconds=60,
            )

            final_read_response = send_thread_read(client, 7, thread_id)
            final_list_response = send_thread_list(client, 8)
            final_storage = tree_storage_summary(tree_name, codex_home, chat_root)
            rollback_marker_count = count_rollback_markers(
                tree_name,
                codex_home,
                chat_root,
            )
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "seed_turn_response": seed_turn_response,
        "seed_turn_started_notification": seed_turn_started,
        "seed_turn_completed_notification": seed_turn_completed,
        "active_turn_response": active_turn_response,
        "active_turn_started_notification": active_turn_started,
        "active_item_completed_notification": active_item_completed,
        "active_turn_completed_notification": active_turn_completed,
        "read_while_active_response": read_while_active_response,
        "rollback_attempt": rollback_attempt,
        "final_read_response": final_read_response,
        "final_list_response": final_list_response,
        "mock_server_summary": mock_server.summary(),
        "storage_before_rollback_attempt": storage_before_rollback_attempt,
        "storage_after_rollback_attempt": storage_after_rollback_attempt,
        "final_storage": final_storage,
        "storage_line_counts_before_rollback_attempt": storage_line_counts(
            storage_before_rollback_attempt,
            tree_name,
        ),
        "storage_line_counts_after_rollback_attempt": storage_line_counts(
            storage_after_rollback_attempt,
            tree_name,
        ),
        "storage_line_counts_final": storage_line_counts(final_storage, tree_name),
        "rollback_marker_count": rollback_marker_count,
        "normalized_read_while_active": normalize_thread_response(
            read_while_active_response,
        ),
        "normalized_rollback_error": normalize_rollback_error(rollback_attempt),
        "normalized_final_read": normalize_thread_response(final_read_response),
        "normalized_final_list": normalize_thread_list_response(
            final_list_response,
            thread_id,
        ),
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def compare_keys(
    original: dict[str, Any],
    chat_backend: dict[str, Any],
    keys: list[str],
) -> dict[str, bool]:
    return {key: original[key] == chat_backend[key] for key in keys}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-rollback-active-turn-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
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

    normalized_keys = [
        "normalized_read_while_active",
        "normalized_rollback_error",
        "normalized_final_read",
        "normalized_final_list",
    ]
    comparisons = compare_keys(original_result, chat_result, normalized_keys)
    original_error = original_result["normalized_rollback_error"]
    chat_error = chat_result["normalized_rollback_error"]
    original_final = original_result["normalized_final_read"]
    chat_final = chat_result["normalized_final_read"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    active_rollback_rejected = all(
        [
            original_error["has_error"],
            chat_error["has_error"],
            original_error["message_contains_active_turn_error"],
            chat_error["message_contains_active_turn_error"],
            not original_error["thread_rolled_back_notification_seen"],
            not chat_error["thread_rolled_back_notification_seen"],
        ]
    )
    final_history_intact = all(
        [
            original_final["turn_count"] == 2,
            chat_final["turn_count"] == 2,
            original_final["contains_seed_user_text"],
            chat_final["contains_seed_user_text"],
            original_final["contains_active_user_text"],
            chat_final["contains_active_user_text"],
            original_final["contains_seed_assistant_text"],
            chat_final["contains_seed_assistant_text"],
            original_final["contains_active_assistant_text"],
            chat_final["contains_active_assistant_text"],
        ]
    )
    active_context_ok = all(
        [
            original_mock["response_request_count"] == 2,
            chat_mock["response_request_count"] == 2,
            original_mock["second_response_input_contains_seed_user_text"],
            chat_mock["second_response_input_contains_seed_user_text"],
            original_mock["second_response_input_contains_seed_assistant_text"],
            chat_mock["second_response_input_contains_seed_assistant_text"],
            original_mock["second_response_input_contains_active_user_text"],
            chat_mock["second_response_input_contains_active_user_text"],
        ]
    )
    no_marker_written = (
        original_result["rollback_marker_count"] == 0
        and chat_result["rollback_marker_count"] == 0
    )
    chat_timeline_rollback_event_count = timeline_event_count(
        chat_result["final_storage"],
        "timeline_rollback",
    )
    no_timeline_rollback_event_written = chat_timeline_rollback_event_count == 0
    line_counts_match_after_attempt = (
        original_result["storage_line_counts_after_rollback_attempt"]
        == chat_result["storage_line_counts_after_rollback_attempt"]
    )
    line_counts_match_final = (
        original_result["storage_line_counts_final"]
        == chat_result["storage_line_counts_final"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-rollback-active-turn-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_active_rollback_fields_equal": all(comparisons.values()),
        "original_active_rollback_rejected": original_error["has_error"],
        "chat_backend_active_rollback_rejected": chat_error["has_error"],
        "active_rollback_rejected_with_same_error": active_rollback_rejected,
        "original_deprecation_notice_seen": original_error["deprecation_notice_seen"],
        "chat_backend_deprecation_notice_seen": chat_error["deprecation_notice_seen"],
        "no_thread_rolled_back_notification_seen": (
            not original_error["thread_rolled_back_notification_seen"]
            and not chat_error["thread_rolled_back_notification_seen"]
        ),
        "final_history_after_active_rollback_attempt_intact": final_history_intact,
        "active_turn_model_context_ok": active_context_ok,
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "no_rollback_marker_written": no_marker_written,
        "chat_backend_timeline_rollback_event_count": (
            chat_timeline_rollback_event_count
        ),
        "no_timeline_rollback_event_written": no_timeline_rollback_event_written,
        "line_counts_match_after_attempt": line_counts_match_after_attempt,
        "line_counts_match_final": line_counts_match_final,
        "original_storage_line_counts_after_attempt": original_result[
            "storage_line_counts_after_rollback_attempt"
        ],
        "chat_backend_storage_line_counts_after_attempt": chat_result[
            "storage_line_counts_after_rollback_attempt"
        ],
        "original_storage_line_counts_final": original_result[
            "storage_line_counts_final"
        ],
        "chat_backend_storage_line_counts_final": chat_result[
            "storage_line_counts_final"
        ],
        "original": {key: original_result[key] for key in normalized_keys},
        "chat_backend": {key: chat_result[key] for key in normalized_keys},
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_storage": {
            "before_attempt": original_result["storage_before_rollback_attempt"],
            "after_attempt": original_result["storage_after_rollback_attempt"],
            "final": original_result["final_storage"],
        },
        "chat_package": {
            "before_attempt": chat_result["storage_before_rollback_attempt"],
            "after_attempt": chat_result["storage_after_rollback_attempt"],
            "final": chat_result["final_storage"],
        },
        "not_yet_proven": [
            "rollback many turns",
            "cumulative rollback markers",
            "rollback after compaction",
            "command/tool execution parity",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/rollback-active-turn-response.json", original_result)
    write_json(output_dir / "chat-backend/rollback-active-turn-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Active-Turn Rollback Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server `thread/rollback` source, protocol definitions, core
rollback replay code, active-turn handling, and upstream rollback tests were
also read.

## Scope

This smoke covers:

```text
thread/start
turn/start seed
turn/completed seed
turn/start active
turn/started active
thread/read while active
thread/rollback numTurns=1 while active
turn/completed active
thread/read final
thread/list active
```

It proves only a narrow RB04 active-turn rollback rejection slice. It does not
prove rollback-many-turns, cumulative rollback markers, rollback after
compaction, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability.

## Result

- all normalized active-rollback fields equal: `{summary['all_normalized_active_rollback_fields_equal']}`
- original active rollback rejected: `{summary['original_active_rollback_rejected']}`
- `.chat` active rollback rejected: `{summary['chat_backend_active_rollback_rejected']}`
- active rollback rejected with same error: `{summary['active_rollback_rejected_with_same_error']}`
- original deprecation notice seen: `{summary['original_deprecation_notice_seen']}`
- `.chat` deprecation notice seen: `{summary['chat_backend_deprecation_notice_seen']}`
- no thread rolled-back notification seen: `{summary['no_thread_rolled_back_notification_seen']}`
- final history after active rollback attempt intact: `{summary['final_history_after_active_rollback_attempt_intact']}`
- active turn model context retained seed context: `{summary['active_turn_model_context_ok']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- no rollback marker written: `{summary['no_rollback_marker_written']}`
- `.chat` timeline rollback event count: `{summary['chat_backend_timeline_rollback_event_count']}`
- no timeline rollback event written: `{summary['no_timeline_rollback_event_written']}`
- line counts match after attempt: `{summary['line_counts_match_after_attempt']}`
- line counts match final: `{summary['line_counts_match_final']}`

## Comparison Booleans

```json
{json.dumps(comparisons, indent=2, sort_keys=True)}
```

## Original Normalized Fields

```json
{json.dumps(summary['original'], indent=2, sort_keys=True)}
```

## `.chat` Backend Normalized Fields

```json
{json.dumps(summary['chat_backend'], indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## Storage Observations

```json
{json.dumps({'original': summary['original_storage'], 'chat_backend': summary['chat_package']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/rollback-active-turn-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/rollback-active-turn-response.json
```

## Not Yet Proven

This smoke does not prove rollback-many-turns, cumulative rollback markers,
rollback after compaction, command/tool execution, crash recovery, cold history,
complete data fidelity, or final user-indistinguishability under normal Codex
usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_active_rollback_fields_equal"],
            summary["original_active_rollback_rejected"],
            summary["chat_backend_active_rollback_rejected"],
            summary["active_rollback_rejected_with_same_error"],
            summary["original_deprecation_notice_seen"],
            summary["chat_backend_deprecation_notice_seen"],
            summary["no_thread_rolled_back_notification_seen"],
            summary["final_history_after_active_rollback_attempt_intact"],
            summary["active_turn_model_context_ok"],
            summary["mock_response_request_counts_equal"],
            summary["no_rollback_marker_written"],
            summary["no_timeline_rollback_event_written"],
            summary["line_counts_match_after_attempt"],
            summary["line_counts_match_final"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
