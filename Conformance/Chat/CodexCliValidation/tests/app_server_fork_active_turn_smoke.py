#!/usr/bin/env python3
"""Run active-turn fork parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers the interrupted active-turn fork
slice: fork while the source turn is in progress, reject `lastTurnId` when it
points at that in-progress turn, then let the source turn complete and compare
the final source and fork state.
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
from app_server_fork_smoke import snapshot_path_content  # noqa: E402


SEED_USER_TEXT = "Active fork source seed turn."
ACTIVE_USER_TEXT = "Active fork source turn still running."
SEED_ASSISTANT_TEXT = "Active fork seed answer from mock model."
ACTIVE_ASSISTANT_TEXT = "Active fork delayed answer from mock model."


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


class DelayedActiveForkMockResponsesServer(MockResponsesServer):
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
            f"resp-active-fork-smoke-{counter}",
            f"msg-active-fork-smoke-{counter}",
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
                first_body, SEED_USER_TEXT
            ),
            "first_response_input_contains_active_user_text": response_input_contains(
                first_body, ACTIVE_USER_TEXT
            ),
            "second_response_input_contains_seed_user_text": response_input_contains(
                second_body, SEED_USER_TEXT
            ),
            "second_response_input_contains_seed_assistant_text": response_input_contains(
                second_body, SEED_ASSISTANT_TEXT
            ),
            "second_response_input_contains_active_user_text": response_input_contains(
                second_body, ACTIVE_USER_TEXT
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


def send_thread_fork(
    client: JsonRpcClient,
    request_id: int,
    source_thread_id: str | None,
    *,
    last_turn_id: str | None = None,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "threadId": source_thread_id,
        "excludeTurns": False,
    }
    if last_turn_id is not None:
        params["lastTurnId"] = last_turn_id
    start_index = len(client.received)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/fork",
            "params": params,
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    started_notification = None
    notification_error = None
    if "error" not in response:
        try:
            started_notification = client.receive_until_method(
                "thread/started", timeout_seconds=30
            )
        except TimeoutError as exc:
            notification_error = str(exc)
    return {
        "response": response,
        "thread_started_notification": started_notification,
        "notification_error": notification_error,
        "notification_methods_after_request": [
            message.get("method")
            for message in client.received[start_index:]
            if message.get("method") is not None
        ],
    }


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


def turn_id_from_response(response: dict[str, Any]) -> str | None:
    return ((response.get("result") or {}).get("turn") or {}).get("id")


def normalize_thread_response(
    response: dict[str, Any],
    expected_thread_id: str | None,
) -> dict[str, Any]:
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_id_matches": expected_thread_id is not None
        and thread.get("id") == expected_thread_id,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
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


def normalize_fork_response(
    fork_result: dict[str, Any],
    source_thread_id: str | None,
    source_path: str | None,
) -> dict[str, Any]:
    response = fork_result["response"]
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    thread_path = thread.get("path")
    started_thread = (
        ((fork_result.get("thread_started_notification") or {}).get("params") or {}).get("thread")
        or {}
    )
    return {
        "has_error": "error" in response,
        "notification_error": fork_result.get("notification_error"),
        "notification_methods_after_request": fork_result.get(
            "notification_methods_after_request"
        ),
        "thread_id_present": thread.get("id") is not None,
        "thread_id_differs_from_source": source_thread_id is not None
        and thread.get("id") != source_thread_id,
        "session_id_equals_thread_id": thread.get("sessionId") == thread.get("id"),
        "forked_from_matches_source": source_thread_id is not None
        and thread.get("forkedFromId") == source_thread_id,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread_path is not None,
        "path_differs_from_source": thread_path is not None and thread_path != source_path,
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
        "thread_started_seen": fork_result.get("thread_started_notification") is not None,
        "started_thread_id_matches": started_thread.get("id") == thread.get("id"),
        "started_thread_turn_count": len(started_thread.get("turns") or []),
    }


def normalize_error_response(response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error") or {}
    message = error.get("message") or ""
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message_contains_in_progress": "in-progress turn" in message,
        "message_contains_last_turn_id": "lastTurnId" in message,
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    expected_thread_ids: list[str | None],
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    ids = {thread.get("id") for thread in threads}
    expected = [thread_id for thread_id in expected_thread_ids if thread_id is not None]
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_all_expected_threads": all(thread_id in ids for thread_id in expected),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
        "expected_thread_count": len(expected),
    }


def original_line_counts(summary: dict[str, Any]) -> list[int]:
    return sorted(
        item.get("line_count")
        for item in (summary.get("rollouts") or [])
        if item.get("line_count") is not None
    )


def chat_line_counts(summary: dict[str, Any]) -> list[int]:
    return sorted(
        package.get("journal_line_count")
        for package in (summary.get("packages") or [])
        if package.get("journal_line_count") is not None
    )


def source_history_line_count(tree_name: str, summary: dict[str, Any]) -> int | None:
    if tree_name == "chat-backend":
        packages = summary.get("packages") or []
        if len(packages) != 1:
            return None
        return packages[0].get("journal_line_count")
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return None
    return rollouts[0].get("line_count")


def summarize_tree_storage(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return summarize_chat_packages(chat_root)
    return summarize_original_storage(codex_home)


def wait_for_source_history_line_count(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    minimum_line_count: int,
    timeout_seconds: float = 5.0,
) -> dict[str, Any]:
    deadline = time.time() + timeout_seconds
    last_summary: dict[str, Any] = {}
    while time.time() < deadline:
        last_summary = summarize_tree_storage(tree_name, codex_home, chat_root)
        line_count = source_history_line_count(tree_name, last_summary)
        if line_count is not None and line_count >= minimum_line_count:
            return {
                "ready": True,
                "line_count": line_count,
                "summary": last_summary,
            }
        time.sleep(0.05)
    line_count = source_history_line_count(tree_name, last_summary)
    return {
        "ready": False,
        "line_count": line_count,
        "summary": last_summary,
    }


def canonical_snapshot_path_content(path_string: str | None) -> dict[str, Any]:
    snapshot = snapshot_path_content(path_string)
    if snapshot.get("kind") != "directory":
        return snapshot
    canonical_files = {
        "timeline.ndjson",
        "journal.ndjson",
    }
    filtered = [
        file_info
        for file_info in snapshot.get("files", [])
        if file_info.get("relative_path") in canonical_files
    ]
    return {
        **snapshot,
        "files": filtered,
        "canonical_filter": sorted(canonical_files),
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

    with DelayedActiveForkMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            source_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )

            seed_turn_response = send_turn_start_response_only(
                client,
                3,
                source_thread_id,
                "client-user-message-active-fork-seed",
                SEED_USER_TEXT,
            )
            seed_turn_started = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            seed_turn_completed = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            active_turn_response = send_turn_start_response_only(
                client,
                4,
                source_thread_id,
                "client-user-message-active-fork-running",
                ACTIVE_USER_TEXT,
            )
            active_turn_id = turn_id_from_response(active_turn_response)
            active_turn_notification_start = len(client.received)
            active_turn_started = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            active_item_completed = receive_method_since(
                client,
                "item/completed",
                active_turn_notification_start,
                timeout_seconds=30,
            )
            active_history_ready = wait_for_source_history_line_count(
                tree_name,
                codex_home,
                chat_root,
                minimum_line_count=16,
            )

            source_read_while_active_response = send_thread_read(
                client, 5, source_thread_id
            )
            source_path = thread_from_response(source_read_while_active_response).get("path")
            source_snapshot_before_fork = snapshot_path_content(source_path)
            source_canonical_snapshot_before_fork = canonical_snapshot_path_content(
                source_path
            )
            pre_active_fork_storage = summarize_tree_storage(
                tree_name, codex_home, chat_root
            )

            completion_wait_start = len(client.received)
            active_fork = send_thread_fork(client, 6, source_thread_id)
            active_fork_thread = thread_from_response(active_fork["response"])
            active_fork_thread_id = active_fork_thread.get("id")
            active_fork_read_response = send_thread_read(
                client, 7, active_fork_thread_id
            )

            in_progress_last_turn_fork = send_thread_fork(
                client,
                8,
                source_thread_id,
                last_turn_id=active_turn_id,
            )

            source_snapshot_after_active_fork = snapshot_path_content(source_path)
            source_canonical_snapshot_after_active_fork = canonical_snapshot_path_content(
                source_path
            )
            post_active_fork_storage = summarize_tree_storage(
                tree_name, codex_home, chat_root
            )

            active_turn_completed = receive_method_since(
                client,
                "turn/completed",
                completion_wait_start,
                timeout_seconds=60,
            )

            final_source_read_response = send_thread_read(client, 9, source_thread_id)
            final_fork_read_response = send_thread_read(client, 10, active_fork_thread_id)
            final_list_response = send_thread_list(client, 11)
            final_storage = summarize_tree_storage(tree_name, codex_home, chat_root)
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "seed_turn_response": seed_turn_response,
        "seed_turn_started_notification": seed_turn_started,
        "seed_turn_completed_notification": seed_turn_completed,
        "active_turn_response": active_turn_response,
        "active_turn_started_notification": active_turn_started,
        "active_item_completed_notification": active_item_completed,
        "active_history_ready": active_history_ready,
        "active_turn_completed_notification": active_turn_completed,
        "source_read_while_active_response": source_read_while_active_response,
        "active_fork": active_fork,
        "active_fork_read_response": active_fork_read_response,
        "in_progress_last_turn_fork": in_progress_last_turn_fork,
        "final_source_read_response": final_source_read_response,
        "final_fork_read_response": final_fork_read_response,
        "final_list_response": final_list_response,
        "normalized_source_while_active": normalize_thread_response(
            source_read_while_active_response,
            source_thread_id,
        ),
        "normalized_active_fork": normalize_fork_response(
            active_fork,
            source_thread_id,
            source_path,
        ),
        "normalized_active_fork_read": normalize_thread_response(
            active_fork_read_response,
            active_fork_thread_id,
        ),
        "normalized_in_progress_last_turn_fork_error": normalize_error_response(
            in_progress_last_turn_fork["response"]
        ),
        "normalized_final_source": normalize_thread_response(
            final_source_read_response,
            source_thread_id,
        ),
        "normalized_final_fork": normalize_thread_response(
            final_fork_read_response,
            active_fork_thread_id,
        ),
        "normalized_final_list": normalize_thread_list_response(
            final_list_response,
            [source_thread_id, active_fork_thread_id],
        ),
        "source_snapshot_before_fork": source_snapshot_before_fork,
        "source_snapshot_after_active_fork": source_snapshot_after_active_fork,
        "source_canonical_snapshot_before_fork": source_canonical_snapshot_before_fork,
        "source_canonical_snapshot_after_active_fork": source_canonical_snapshot_after_active_fork,
        "source_full_snapshot_unchanged_after_active_fork": (
            source_snapshot_before_fork == source_snapshot_after_active_fork
        ),
        "source_snapshot_unchanged_after_active_fork": (
            source_canonical_snapshot_before_fork
            == source_canonical_snapshot_after_active_fork
        ),
        "pre_active_fork_storage_summary": pre_active_fork_storage,
        "post_active_fork_storage_summary": post_active_fork_storage,
        "final_storage_summary": final_storage,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-fork-active-turn-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    comparison_keys = [
        "normalized_source_while_active",
        "normalized_active_fork",
        "normalized_active_fork_read",
        "normalized_in_progress_last_turn_fork_error",
        "normalized_final_source",
        "normalized_final_fork",
        "normalized_final_list",
        "source_snapshot_unchanged_after_active_fork",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    original_pre_counts = original_line_counts(
        original_result["pre_active_fork_storage_summary"]
    )
    chat_pre_counts = chat_line_counts(chat_result["pre_active_fork_storage_summary"])
    original_post_counts = original_line_counts(
        original_result["post_active_fork_storage_summary"]
    )
    chat_post_counts = chat_line_counts(chat_result["post_active_fork_storage_summary"])
    original_final_counts = original_line_counts(original_result["final_storage_summary"])
    chat_final_counts = chat_line_counts(chat_result["final_storage_summary"])

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-fork-active-turn-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_active_fork_fields_equal": all(comparisons.values()),
        "original_source_active_has_in_progress_turn": "inProgress"
        in original_result["normalized_source_while_active"]["turn_statuses"],
        "chat_backend_source_active_has_in_progress_turn": "inProgress"
        in chat_result["normalized_source_while_active"]["turn_statuses"],
        "original_active_history_ready_before_read": original_result["active_history_ready"][
            "ready"
        ],
        "chat_backend_active_history_ready_before_read": chat_result["active_history_ready"][
            "ready"
        ],
        "original_active_fork_succeeded": not original_result["normalized_active_fork"][
            "has_error"
        ],
        "chat_backend_active_fork_succeeded": not chat_result["normalized_active_fork"][
            "has_error"
        ],
        "original_active_fork_has_no_delayed_assistant_text": not original_result[
            "normalized_active_fork"
        ]["contains_active_assistant_text"],
        "chat_backend_active_fork_has_no_delayed_assistant_text": not chat_result[
            "normalized_active_fork"
        ]["contains_active_assistant_text"],
        "original_active_fork_read_has_no_delayed_assistant_text": not original_result[
            "normalized_active_fork_read"
        ]["contains_active_assistant_text"],
        "chat_backend_active_fork_read_has_no_delayed_assistant_text": not chat_result[
            "normalized_active_fork_read"
        ]["contains_active_assistant_text"],
        "original_in_progress_last_turn_fork_rejected": original_result[
            "normalized_in_progress_last_turn_fork_error"
        ]["has_error"],
        "chat_backend_in_progress_last_turn_fork_rejected": chat_result[
            "normalized_in_progress_last_turn_fork_error"
        ]["has_error"],
        "original_in_progress_last_turn_error_is_specific": (
            original_result["normalized_in_progress_last_turn_fork_error"][
                "message_contains_in_progress"
            ]
            and original_result["normalized_in_progress_last_turn_fork_error"][
                "message_contains_last_turn_id"
            ]
        ),
        "chat_backend_in_progress_last_turn_error_is_specific": (
            chat_result["normalized_in_progress_last_turn_fork_error"][
                "message_contains_in_progress"
            ]
            and chat_result["normalized_in_progress_last_turn_fork_error"][
                "message_contains_last_turn_id"
            ]
        ),
        "original_source_completed_after_fork": original_result["normalized_final_source"][
            "turn_statuses"
        ]
        == ["completed", "completed"],
        "chat_backend_source_completed_after_fork": chat_result["normalized_final_source"][
            "turn_statuses"
        ]
        == ["completed", "completed"],
        "original_final_source_contains_delayed_assistant_text": original_result[
            "normalized_final_source"
        ]["contains_active_assistant_text"],
        "chat_backend_final_source_contains_delayed_assistant_text": chat_result[
            "normalized_final_source"
        ]["contains_active_assistant_text"],
        "original_final_fork_still_excludes_delayed_assistant_text": not original_result[
            "normalized_final_fork"
        ]["contains_active_assistant_text"],
        "chat_backend_final_fork_still_excludes_delayed_assistant_text": not chat_result[
            "normalized_final_fork"
        ]["contains_active_assistant_text"],
        "original_source_unchanged_by_active_fork_before_completion": original_result[
            "source_snapshot_unchanged_after_active_fork"
        ],
        "chat_backend_source_unchanged_by_active_fork_before_completion": chat_result[
            "source_snapshot_unchanged_after_active_fork"
        ],
        "final_list_contains_source_and_fork_in_original": original_result[
            "normalized_final_list"
        ]["contains_all_expected_threads"],
        "final_list_contains_source_and_fork_in_chat_backend": chat_result[
            "normalized_final_list"
        ]["contains_all_expected_threads"],
        "mock_response_request_counts_equal": original_result["mock_server_summary"][
            "response_request_count"
        ]
        == chat_result["mock_server_summary"]["response_request_count"],
        "mock_no_extra_model_request_for_active_fork": (
            original_result["mock_server_summary"]["response_request_count"] == 2
            and chat_result["mock_server_summary"]["response_request_count"] == 2
        ),
        "pre_active_fork_line_counts_equal": original_pre_counts == chat_pre_counts,
        "post_active_fork_line_counts_equal": original_post_counts == chat_post_counts,
        "final_line_counts_equal": original_final_counts == chat_final_counts,
        "original": {key: original_result[key] for key in comparison_keys},
        "chat_backend": {key: chat_result[key] for key in comparison_keys},
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_active_history_ready": original_result["active_history_ready"],
        "chat_backend_active_history_ready": chat_result["active_history_ready"],
        "original_storage": {
            "pre_active_fork": original_result["pre_active_fork_storage_summary"],
            "post_active_fork": original_result["post_active_fork_storage_summary"],
            "final": original_result["final_storage_summary"],
        },
        "chat_package": {
            "pre_active_fork": chat_result["pre_active_fork_storage_summary"],
            "post_active_fork": chat_result["post_active_fork_storage_summary"],
            "final": chat_result["final_storage_summary"],
        },
        "not_yet_proven": [
            "rollback parity",
            "compaction/context restore parity",
            "command execution parity",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/fork-active-turn-response.json", original_result)
    write_json(output_dir / "chat-backend/fork-active-turn-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Active-Turn Fork Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a delayed local
mock Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, and current progress report
were read. Relevant vendored Codex source was also read:

```text
app-server/src/request_processors/thread_processor.rs
app-server/tests/suite/v2/thread_fork.rs
core/src/thread_manager.rs
core/src/thread_manager_tests.rs
core/src/thread_rollout_truncation.rs
core/src/thread_rollout_truncation_tests.rs
```

## Scope

This smoke covers:

```text
thread/start
turn/start seed + turn/completed
turn/start active + turn/started
item/completed for the active user message
thread/read source while active
thread/fork while source turn is in progress
thread/read active fork
thread/fork lastTurnId=<in-progress turn>
source turn/completed
thread/read source
thread/read fork
thread/list active
```

It proves only the interrupted active-turn fork slice and the in-progress
`lastTurnId` rejection slice. It does not prove rollback, compaction, command
execution, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability.

## Result

- all normalized active-fork fields equal: `{summary['all_normalized_active_fork_fields_equal']}`
- original source showed an in-progress turn before fork: `{summary['original_source_active_has_in_progress_turn']}`
- `.chat` source showed an in-progress turn before fork: `{summary['chat_backend_source_active_has_in_progress_turn']}`
- original active history reached mid-turn durable state before read: `{summary['original_active_history_ready_before_read']}`
- `.chat` active history reached mid-turn durable state before read: `{summary['chat_backend_active_history_ready_before_read']}`
- original active fork succeeded: `{summary['original_active_fork_succeeded']}`
- `.chat` active fork succeeded: `{summary['chat_backend_active_fork_succeeded']}`
- original active fork excluded delayed assistant text: `{summary['original_active_fork_has_no_delayed_assistant_text']}`
- `.chat` active fork excluded delayed assistant text: `{summary['chat_backend_active_fork_has_no_delayed_assistant_text']}`
- original in-progress `lastTurnId` fork rejected: `{summary['original_in_progress_last_turn_fork_rejected']}`
- `.chat` in-progress `lastTurnId` fork rejected: `{summary['chat_backend_in_progress_last_turn_fork_rejected']}`
- original rejection identified `lastTurnId` and in-progress turn: `{summary['original_in_progress_last_turn_error_is_specific']}`
- `.chat` rejection identified `lastTurnId` and in-progress turn: `{summary['chat_backend_in_progress_last_turn_error_is_specific']}`
- original source completed after fork: `{summary['original_source_completed_after_fork']}`
- `.chat` source completed after fork: `{summary['chat_backend_source_completed_after_fork']}`
- original final source contains delayed assistant text: `{summary['original_final_source_contains_delayed_assistant_text']}`
- `.chat` final source contains delayed assistant text: `{summary['chat_backend_final_source_contains_delayed_assistant_text']}`
- original final fork still excludes delayed assistant text: `{summary['original_final_fork_still_excludes_delayed_assistant_text']}`
- `.chat` final fork still excludes delayed assistant text: `{summary['chat_backend_final_fork_still_excludes_delayed_assistant_text']}`
- original source storage unchanged by active fork before completion: `{summary['original_source_unchanged_by_active_fork_before_completion']}`
- `.chat` source package unchanged by active fork before completion: `{summary['chat_backend_source_unchanged_by_active_fork_before_completion']}`
- final list contains source and fork in original: `{summary['final_list_contains_source_and_fork_in_original']}`
- final list contains source and fork in `.chat`: `{summary['final_list_contains_source_and_fork_in_chat_backend']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- no extra model request was made for active fork: `{summary['mock_no_extra_model_request_for_active_fork']}`
- pre-active-fork line counts equal: `{summary['pre_active_fork_line_counts_equal']}`
- post-active-fork line counts equal: `{summary['post_active_fork_line_counts_equal']}`
- final line counts equal: `{summary['final_line_counts_equal']}`

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

## `.chat` Package Observations

```json
{json.dumps(summary['chat_package'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/fork-active-turn-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/fork-active-turn-response.json
```
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_active_fork_fields_equal"],
            summary["original_source_active_has_in_progress_turn"],
            summary["chat_backend_source_active_has_in_progress_turn"],
            summary["original_active_history_ready_before_read"],
            summary["chat_backend_active_history_ready_before_read"],
            summary["original_active_fork_succeeded"],
            summary["chat_backend_active_fork_succeeded"],
            summary["original_active_fork_has_no_delayed_assistant_text"],
            summary["chat_backend_active_fork_has_no_delayed_assistant_text"],
            summary["original_active_fork_read_has_no_delayed_assistant_text"],
            summary["chat_backend_active_fork_read_has_no_delayed_assistant_text"],
            summary["original_in_progress_last_turn_fork_rejected"],
            summary["chat_backend_in_progress_last_turn_fork_rejected"],
            summary["original_in_progress_last_turn_error_is_specific"],
            summary["chat_backend_in_progress_last_turn_error_is_specific"],
            summary["original_source_completed_after_fork"],
            summary["chat_backend_source_completed_after_fork"],
            summary["original_final_source_contains_delayed_assistant_text"],
            summary["chat_backend_final_source_contains_delayed_assistant_text"],
            summary["original_final_fork_still_excludes_delayed_assistant_text"],
            summary["chat_backend_final_fork_still_excludes_delayed_assistant_text"],
            summary["original_source_unchanged_by_active_fork_before_completion"],
            summary["chat_backend_source_unchanged_by_active_fork_before_completion"],
            summary["final_list_contains_source_and_fork_in_original"],
            summary["final_list_contains_source_and_fork_in_chat_backend"],
            summary["mock_response_request_counts_equal"],
            summary["mock_no_extra_model_request_for_active_fork"],
            summary["pre_active_fork_line_counts_equal"],
            summary["post_active_fork_line_counts_equal"],
            summary["final_line_counts_equal"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
