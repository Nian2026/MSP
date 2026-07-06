#!/usr/bin/env python3
"""Run app-server rollback parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers a narrow RB01 slice: complete two
turns, rollback the last turn, verify the response/read/resume view, then send a
follow-up turn and verify replay context excludes the rolled-back turn.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_resume_smoke import send_thread_resume  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_fork_smoke import (  # noqa: E402
    response_request_bodies,
    snapshot_path_content,
)


FIRST_USER_TEXT = "Rollback parity first durable turn."
SECOND_USER_TEXT = "Rollback parity second turn to remove."
FOLLOWUP_USER_TEXT = "Rollback parity follow-up after removing the second turn."
FIRST_ASSISTANT_TEXT = "Rollback first answer from mock model."
SECOND_ASSISTANT_TEXT = "Rollback second answer that must disappear."
FOLLOWUP_ASSISTANT_TEXT = "Rollback follow-up answer from mock model."


class RollbackMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FIRST_ASSISTANT_TEXT)
        self._answers = [
            FIRST_ASSISTANT_TEXT,
            SECOND_ASSISTANT_TEXT,
            FOLLOWUP_ASSISTANT_TEXT,
        ]

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text = self._answers[min(counter - 1, len(self._answers) - 1)]
        return sse_response(
            f"resp-rollback-smoke-{counter}",
            f"msg-rollback-smoke-{counter}",
            answer_text,
        )


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    followup_body = bodies[2] if len(bodies) > 2 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "first_response_input_contains_first_user_text": response_input_contains(
            first_body, FIRST_USER_TEXT
        ),
        "second_response_input_contains_first_user_text": response_input_contains(
            second_body, FIRST_USER_TEXT
        ),
        "second_response_input_contains_first_assistant_text": response_input_contains(
            second_body, FIRST_ASSISTANT_TEXT
        ),
        "second_response_input_contains_second_user_text": response_input_contains(
            second_body, SECOND_USER_TEXT
        ),
        "followup_response_input_contains_first_user_text": response_input_contains(
            followup_body, FIRST_USER_TEXT
        ),
        "followup_response_input_contains_first_assistant_text": response_input_contains(
            followup_body, FIRST_ASSISTANT_TEXT
        ),
        "followup_response_input_contains_second_user_text": response_input_contains(
            followup_body, SECOND_USER_TEXT
        ),
        "followup_response_input_contains_second_assistant_text": response_input_contains(
            followup_body, SECOND_ASSISTANT_TEXT
        ),
        "followup_response_input_contains_followup_user_text": response_input_contains(
            followup_body, FOLLOWUP_USER_TEXT
        ),
    }


def send_initialize(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "msp-chat-validation",
                    "title": "MSP Chat Validation",
                    "version": "0.0.0",
                },
                "capabilities": {
                    "experimentalApi": True,
                    "requestAttestation": False,
                    "optOutNotificationMethods": ["account/rateLimits/updated"],
                    "mcpServerOpenaiFormElicitation": False,
                },
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    client.send({"jsonrpc": "2.0", "method": "initialized"})
    return response


def send_thread_start(
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
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    thread_id = ((response.get("result") or {}).get("thread") or {}).get("id")
    return thread_id, response


def send_turn_start(
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
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications: list[dict[str, Any]] = []
    notification_errors: list[str] = []
    if "error" not in response:
        for method, timeout_seconds in [
            ("turn/started", 30),
            ("turn/completed", 60),
        ]:
            try:
                notifications.append(
                    client.receive_until_method(method, timeout_seconds=timeout_seconds)
                )
            except TimeoutError as exc:
                notification_errors.append(str(exc))
                break
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def send_thread_read(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/read",
            "params": {
                "threadId": thread_id,
                "includeTurns": True,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_rollback(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    num_turns: int,
) -> dict[str, Any]:
    start_index = len(client.received)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/rollback",
            "params": {
                "threadId": thread_id,
                "numTurns": num_turns,
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    messages_after_request = client.received[start_index:]
    notifications = [
        message for message in messages_after_request if message.get("method") is not None
    ]
    return {
        "response": response,
        "notifications": notifications,
        "notification_methods_after_request": [
            notification.get("method") for notification in notifications
        ],
    }


def send_thread_list(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": {
                "limit": 10,
                "modelProviders": [],
                "archived": False,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


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
        "name_is_null_or_absent": thread.get("name") is None,
        "session_id_present": thread.get("sessionId") is not None,
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_followup_user_text": FOLLOWUP_USER_TEXT in serialized_turns,
        "contains_first_assistant_text": FIRST_ASSISTANT_TEXT in serialized_turns,
        "contains_second_assistant_text": SECOND_ASSISTANT_TEXT in serialized_turns,
        "contains_followup_assistant_text": FOLLOWUP_ASSISTANT_TEXT in serialized_turns,
    }


def normalize_rollback_result(rollback_result: dict[str, Any]) -> dict[str, Any]:
    response = rollback_result["response"]
    normalized = normalize_thread_response(response)
    methods = rollback_result.get("notification_methods_after_request") or []
    normalized.update(
        {
            "deprecation_notice_seen": "deprecationNotice" in methods,
            "notification_methods_after_request": methods,
        }
    )
    return normalized


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


def storage_line_counts(summary: dict[str, Any], tree_name: str) -> list[int]:
    if tree_name == "chat-backend":
        return sorted(
            package.get("journal_line_count")
            for package in (summary.get("packages") or [])
            if package.get("journal_line_count") is not None
        )
    return sorted(
        item.get("line_count")
        for item in (summary.get("rollouts") or [])
        if item.get("line_count") is not None
    )


def count_rollback_markers_in_file(path: pathlib.Path) -> int:
    if not path.exists() or path.is_dir():
        return 0
    count = 0
    for line in path.read_text().splitlines():
        if "thread_rolled_back" in line or "ThreadRolledBack" in line:
            count += 1
    return count


def count_rollback_markers(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> int:
    if tree_name == "chat-backend":
        return sum(
            count_rollback_markers_in_file(path)
            for path in chat_root.glob("*.chat/journal.ndjson")
        )
    return sum(
        count_rollback_markers_in_file(path)
        for path in codex_home.rglob("*.jsonl")
    )


def timeline_event_count(summary: dict[str, Any], event_type: str) -> int:
    return sum(
        (package.get("timeline_event_types") or []).count(event_type)
        for package in (summary.get("packages") or [])
    )


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

    with RollbackMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)

            first_turn = send_turn_start(
                client,
                3,
                thread_id,
                "client-user-message-rollback-1",
                FIRST_USER_TEXT,
            )
            second_turn = send_turn_start(
                client,
                4,
                thread_id,
                "client-user-message-rollback-2",
                SECOND_USER_TEXT,
            )

            read_before_rollback_response = send_thread_read(client, 5, thread_id)
            source_path = thread_from_response(read_before_rollback_response).get("path")
            source_snapshot_before_rollback = snapshot_path_content(source_path)
            storage_before_rollback = tree_storage_summary(tree_name, codex_home, chat_root)

            rollback = send_thread_rollback(client, 6, thread_id, 1)
            read_after_rollback_response = send_thread_read(client, 7, thread_id)
            resume_after_rollback_response = send_thread_resume(client, 8, thread_id)

            followup_turn = send_turn_start(
                client,
                9,
                thread_id,
                "client-user-message-rollback-followup",
                FOLLOWUP_USER_TEXT,
            )
            final_read_response = send_thread_read(client, 10, thread_id)
            final_list_response = send_thread_list(client, 11)
            source_snapshot_after_followup = snapshot_path_content(source_path)
            storage_after_followup = tree_storage_summary(tree_name, codex_home, chat_root)
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
        "first_turn": first_turn,
        "second_turn": second_turn,
        "read_before_rollback_response": read_before_rollback_response,
        "rollback": rollback,
        "read_after_rollback_response": read_after_rollback_response,
        "resume_after_rollback_response": resume_after_rollback_response,
        "followup_turn": followup_turn,
        "final_read_response": final_read_response,
        "final_list_response": final_list_response,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "source_snapshot_before_rollback": source_snapshot_before_rollback,
        "source_snapshot_after_followup": source_snapshot_after_followup,
        "storage_before_rollback": storage_before_rollback,
        "storage_after_followup": storage_after_followup,
        "storage_line_counts_before_rollback": storage_line_counts(
            storage_before_rollback,
            tree_name,
        ),
        "storage_line_counts_after_followup": storage_line_counts(
            storage_after_followup,
            tree_name,
        ),
        "rollback_marker_count": rollback_marker_count,
        "normalized_before_rollback": normalize_thread_response(
            read_before_rollback_response
        ),
        "normalized_rollback": normalize_rollback_result(rollback),
        "normalized_read_after_rollback": normalize_thread_response(
            read_after_rollback_response
        ),
        "normalized_resume_after_rollback": normalize_thread_response(
            resume_after_rollback_response
        ),
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
        / ("app-server-rollback-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        "normalized_before_rollback",
        "normalized_rollback",
        "normalized_read_after_rollback",
        "normalized_resume_after_rollback",
        "normalized_final_read",
        "normalized_final_list",
    ]
    comparisons = compare_keys(original_result, chat_result, normalized_keys)
    original_rollback = original_result["normalized_rollback"]
    chat_rollback = chat_result["normalized_rollback"]
    original_final = original_result["normalized_final_read"]
    chat_final = chat_result["normalized_final_read"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    rollback_response_kept_first_removed_second = all(
        [
            original_rollback["turn_count"] == 1,
            chat_rollback["turn_count"] == 1,
            original_rollback["contains_first_user_text"],
            chat_rollback["contains_first_user_text"],
            not original_rollback["contains_second_user_text"],
            not chat_rollback["contains_second_user_text"],
            original_rollback["contains_first_assistant_text"],
            chat_rollback["contains_first_assistant_text"],
            not original_rollback["contains_second_assistant_text"],
            not chat_rollback["contains_second_assistant_text"],
        ]
    )
    followup_context_ok = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["followup_response_input_contains_first_user_text"],
            chat_mock["followup_response_input_contains_first_user_text"],
            original_mock["followup_response_input_contains_first_assistant_text"],
            chat_mock["followup_response_input_contains_first_assistant_text"],
            original_mock["followup_response_input_contains_followup_user_text"],
            chat_mock["followup_response_input_contains_followup_user_text"],
            not original_mock["followup_response_input_contains_second_user_text"],
            not chat_mock["followup_response_input_contains_second_user_text"],
            not original_mock["followup_response_input_contains_second_assistant_text"],
            not chat_mock["followup_response_input_contains_second_assistant_text"],
        ]
    )
    final_history_ok = all(
        [
            original_final["turn_count"] == 2,
            chat_final["turn_count"] == 2,
            original_final["contains_first_user_text"],
            chat_final["contains_first_user_text"],
            original_final["contains_followup_user_text"],
            chat_final["contains_followup_user_text"],
            not original_final["contains_second_user_text"],
            not chat_final["contains_second_user_text"],
            not original_final["contains_second_assistant_text"],
            not chat_final["contains_second_assistant_text"],
        ]
    )
    line_counts_match_after_followup = (
        original_result["storage_line_counts_after_followup"]
        == chat_result["storage_line_counts_after_followup"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-rollback-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_rollback_fields_equal": all(comparisons.values()),
        "original_first_two_turns_before_rollback": original_result[
            "normalized_before_rollback"
        ]["turn_count"]
        == 2,
        "chat_backend_first_two_turns_before_rollback": chat_result[
            "normalized_before_rollback"
        ]["turn_count"]
        == 2,
        "original_rollback_response_succeeded": "result"
        in original_result["rollback"]["response"],
        "chat_backend_rollback_response_succeeded": "result"
        in chat_result["rollback"]["response"],
        "original_deprecation_notice_seen": original_rollback["deprecation_notice_seen"],
        "chat_backend_deprecation_notice_seen": chat_rollback["deprecation_notice_seen"],
        "rollback_response_kept_first_removed_second": (
            rollback_response_kept_first_removed_second
        ),
        "normalized_read_after_rollback_equal": comparisons[
            "normalized_read_after_rollback"
        ],
        "normalized_resume_after_rollback_equal": comparisons[
            "normalized_resume_after_rollback"
        ],
        "followup_turn_context_excludes_rolled_back_turn": followup_context_ok,
        "final_history_after_followup_ok": final_history_ok,
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "rollback_marker_counts_equal": original_result["rollback_marker_count"]
        == chat_result["rollback_marker_count"],
        "chat_backend_timeline_rollback_event_count": timeline_event_count(
            chat_result["storage_after_followup"],
            "timeline_rollback",
        ),
        "chat_backend_timeline_rollback_event_count_matches_marker_count": (
            timeline_event_count(chat_result["storage_after_followup"], "timeline_rollback")
            == chat_result["rollback_marker_count"]
        ),
        "line_counts_match_after_followup": line_counts_match_after_followup,
        "original_storage_line_counts_after_followup": original_result[
            "storage_line_counts_after_followup"
        ],
        "chat_backend_storage_line_counts_after_followup": chat_result[
            "storage_line_counts_after_followup"
        ],
        "original": {key: original_result[key] for key in normalized_keys},
        "chat_backend": {key: chat_result[key] for key in normalized_keys},
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_storage": {
            "before_rollback": original_result["storage_before_rollback"],
            "after_followup": original_result["storage_after_followup"],
        },
        "chat_package": {
            "before_rollback": chat_result["storage_before_rollback"],
            "after_followup": chat_result["storage_after_followup"],
        },
        "not_yet_proven": [
            "rollback many turns",
            "cumulative rollback markers",
            "rollback during active turn",
            "rollback after compaction",
            "command/tool execution parity",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/rollback-response.json", original_result)
    write_json(output_dir / "chat-backend/rollback-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Rollback Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server `thread/rollback` source, protocol definitions, core
rollback replay code, and upstream rollback tests were also read.

## Scope

This smoke covers:

```text
thread/start
turn/start x2
thread/read before rollback
thread/rollback numTurns=1
thread/read after rollback
thread/resume after rollback
turn/start follow-up after rollback
thread/read final
thread/list active
```

It proves only a narrow RB01 plus follow-up replay-context slice. It does not
prove rollback-many-turns, cumulative rollback markers, rollback during active
turn, rollback after compaction, crash recovery, cold history, complete data
fidelity, or final user-indistinguishability.

## Result

- all normalized rollback fields equal: `{summary['all_normalized_rollback_fields_equal']}`
- original had two turns before rollback: `{summary['original_first_two_turns_before_rollback']}`
- `.chat` had two turns before rollback: `{summary['chat_backend_first_two_turns_before_rollback']}`
- original rollback response succeeded: `{summary['original_rollback_response_succeeded']}`
- `.chat` rollback response succeeded: `{summary['chat_backend_rollback_response_succeeded']}`
- original deprecation notice seen: `{summary['original_deprecation_notice_seen']}`
- `.chat` deprecation notice seen: `{summary['chat_backend_deprecation_notice_seen']}`
- rollback response kept first turn and removed second: `{summary['rollback_response_kept_first_removed_second']}`
- read after rollback normalized equal: `{summary['normalized_read_after_rollback_equal']}`
- resume after rollback normalized equal: `{summary['normalized_resume_after_rollback_equal']}`
- follow-up model context excluded rolled-back turn: `{summary['followup_turn_context_excludes_rolled_back_turn']}`
- final history after follow-up is rollback-shaped: `{summary['final_history_after_followup_ok']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- rollback marker counts equal: `{summary['rollback_marker_counts_equal']}`
- `.chat` timeline rollback event count: `{summary['chat_backend_timeline_rollback_event_count']}`
- `.chat` timeline rollback count matches marker count: `{summary['chat_backend_timeline_rollback_event_count_matches_marker_count']}`
- line counts match after follow-up: `{summary['line_counts_match_after_followup']}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/rollback-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/rollback-response.json
```

## Not Yet Proven

This smoke does not prove rollback-many-turns, cumulative rollback markers,
rollback during active turn, rollback after compaction, command/tool execution,
crash recovery, cold history, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_rollback_fields_equal"],
            summary["original_first_two_turns_before_rollback"],
            summary["chat_backend_first_two_turns_before_rollback"],
            summary["original_rollback_response_succeeded"],
            summary["chat_backend_rollback_response_succeeded"],
            summary["original_deprecation_notice_seen"],
            summary["chat_backend_deprecation_notice_seen"],
            summary["rollback_response_kept_first_removed_second"],
            summary["normalized_read_after_rollback_equal"],
            summary["normalized_resume_after_rollback_equal"],
            summary["followup_turn_context_excludes_rolled_back_turn"],
            summary["final_history_after_followup_ok"],
            summary["mock_response_request_counts_equal"],
            summary["rollback_marker_counts_equal"],
            summary["chat_backend_timeline_rollback_event_count_matches_marker_count"],
            summary["line_counts_match_after_followup"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
