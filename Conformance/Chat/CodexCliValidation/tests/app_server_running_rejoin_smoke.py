#!/usr/bin/env python3
"""Run a running-thread rejoin app-server smoke for original vs `.chat` Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. Each tree completes one seed turn, starts a second turn whose mock model
response is deliberately delayed, calls `thread/resume` while that turn is
running, then waits for the turn to complete. The smoke checks that the resume
response sees the live in-progress turn and that the final durable thread state
still matches.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import time
import uuid
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


SEED_USER_TEXT = "Seed history before running rejoin."
RUNNING_USER_TEXT = "Keep this turn running while resume rejoins it."
SEED_ASSISTANT_TEXT = "Seed answer from mock model."
RUNNING_ASSISTANT_TEXT = "Running rejoin answer from mock model."


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


class DelayedSequenceMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(RUNNING_ASSISTANT_TEXT)
        self._responses = [
            (SEED_ASSISTANT_TEXT, 0.0),
            (RUNNING_ASSISTANT_TEXT, 2.0),
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
            f"resp-running-rejoin-smoke-{counter}",
            f"msg-running-rejoin-smoke-{counter}",
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
            "first_response_model": first_body.get("model"),
            "second_response_model": second_body.get("model"),
            "first_response_input_contains_seed_user_text": response_input_contains(
                first_body, SEED_USER_TEXT
            ),
            "first_response_input_contains_running_user_text": response_input_contains(
                first_body, RUNNING_USER_TEXT
            ),
            "second_response_input_contains_seed_user_text": response_input_contains(
                second_body, SEED_USER_TEXT
            ),
            "second_response_input_contains_seed_assistant_text": response_input_contains(
                second_body, SEED_ASSISTANT_TEXT
            ),
            "second_response_input_contains_running_user_text": response_input_contains(
                second_body, RUNNING_USER_TEXT
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


def send_thread_resume_running(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/resume",
            "params": {
                "threadId": thread_id,
                "model": "not-the-running-model",
                "cwd": "/tmp",
                "initialTurnsPage": {},
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_resume_stale_path(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    stale_path: pathlib.Path,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/resume",
            "params": {
                "threadId": thread_id,
                "path": str(stale_path),
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


def turn_id_from_turn_start(response: dict[str, Any]) -> str | None:
    return ((response.get("result") or {}).get("turn") or {}).get("id")


def status_name(value: Any) -> Any:
    return status_type(value)


def normalize_error_response(response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error") or {}
    message = error.get("message") or ""
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message_contains_stale_path": "stale path" in message,
        "message_contains_cannot_resume": "cannot resume" in message,
        "message_contains_running_thread": "running thread" in message,
    }


def normalize_override_warning(stderr_tail: str, workspace: pathlib.Path) -> dict[str, Any]:
    warning_marker = "thread/resume overrides ignored for loaded thread"
    model_marker = "model requested=not-the-running-model active=mock-model"
    cwd_marker = "cwd requested=/tmp active="
    workspace_marker = f"active={workspace}"
    return {
        "has_override_warning": warning_marker in stderr_tail,
        "contains_model_mismatch": model_marker in stderr_tail,
        "contains_cwd_mismatch": cwd_marker in stderr_tail,
        "contains_active_workspace": workspace_marker in stderr_tail,
    }


def normalize_thread_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_id_matches": thread_id is not None and thread.get("id") == thread_id,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_name(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_name(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_seed_user_text": SEED_USER_TEXT in serialized_turns,
        "contains_running_user_text": RUNNING_USER_TEXT in serialized_turns,
        "contains_seed_assistant_text": SEED_ASSISTANT_TEXT in serialized_turns,
        "contains_running_assistant_text": RUNNING_ASSISTANT_TEXT in serialized_turns,
    }


def normalize_running_resume_response(
    response: dict[str, Any],
    thread_id: str | None,
    running_turn_id: str | None,
) -> dict[str, Any]:
    normalized = normalize_thread_response(response, thread_id)
    result = response.get("result") or {}
    page = result.get("initialTurnsPage") or {}
    page_turns = page.get("data") or []
    running_turn = None
    if running_turn_id is not None:
        running_turn = next(
            (turn for turn in page_turns if turn.get("id") == running_turn_id),
            None,
        )
    if running_turn is None and page_turns:
        running_turn = page_turns[0]
    normalized.update(
        {
            "initial_turns_page_present": bool(page),
            "initial_turns_page_count": len(page_turns),
            "initial_turns_page_next_cursor_present": page.get("nextCursor") is not None,
            "initial_turns_page_backwards_cursor_present": (
                page.get("backwardsCursor") is not None
            ),
            "initial_turns_page_statuses": [
                status_name(turn.get("status")) for turn in page_turns
            ],
            "initial_turns_page_items_views": [
                turn.get("itemsView") for turn in page_turns
            ],
            "initial_turns_page_contains_running_turn": running_turn is not None
            and running_turn_id is not None
            and running_turn.get("id") == running_turn_id,
            "running_turn_status": status_name((running_turn or {}).get("status")),
            "running_turn_items_view": (running_turn or {}).get("itemsView"),
            "running_turn_item_count": len((running_turn or {}).get("items") or []),
        }
    )
    return normalized


def normalize_thread_list_response(
    response: dict[str, Any],
    started_thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result", {})
    threads = result.get("data") or []
    listed_thread = None
    if started_thread_id is not None:
        listed_thread = next(
            (thread for thread in threads if thread.get("id") == started_thread_id),
            None,
        )
    if listed_thread is None and threads:
        listed_thread = threads[0]

    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_started_thread": listed_thread is not None
        and listed_thread.get("id") == started_thread_id,
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }
    if listed_thread is not None:
        normalized.update(
            {
                "listed_thread_ephemeral": listed_thread.get("ephemeral"),
                "listed_thread_model_provider": listed_thread.get("modelProvider"),
                "listed_thread_model": listed_thread.get("model"),
                "listed_thread_name": listed_thread.get("name"),
                "listed_thread_preview": listed_thread.get("preview"),
                "listed_thread_source": listed_thread.get("source"),
                "listed_thread_status_type": status_name(listed_thread.get("status")),
                "listed_thread_turn_count": len(listed_thread.get("turns") or []),
            }
        )
    return normalized


def summarize_path_observation(response: dict[str, Any], thread_id: str | None) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    if thread_id is not None and thread.get("id") != thread_id:
        thread = {}
    path = thread.get("path")
    return {
        "thread_id": thread_id,
        "path_present": path is not None,
        "path_suffix": pathlib.Path(path).suffix if path else None,
    }


def make_stale_resume_path(tree_name: str, run_root: pathlib.Path) -> pathlib.Path:
    stale_id = uuid.uuid4()
    if tree_name == "chat-backend":
        return run_root / tree_name / "stale-chat-store" / f"{stale_id}.chat"
    return (
        run_root
        / tree_name
        / "codex-home"
        / "sessions"
        / "2025"
        / "01"
        / "01"
        / f"rollout-2025-01-01T00-00-00-{stale_id}.jsonl"
    )


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def chat_package_running_rejoin_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 8
        and package.get("journal_line_count", 0) >= 8
        and "runtime_context_snapshot" in event_types
        and "message" in event_types
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

    with DelayedSequenceMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )

            seed_turn_response = send_turn_start_response_only(
                client,
                3,
                started_thread_id,
                "client-user-message-running-rejoin-seed",
                SEED_USER_TEXT,
            )
            seed_turn_started = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            seed_turn_completed = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            running_turn_response = send_turn_start_response_only(
                client,
                4,
                started_thread_id,
                "client-user-message-running-rejoin-active",
                RUNNING_USER_TEXT,
            )
            running_turn_id = turn_id_from_turn_start(running_turn_response)
            running_turn_started = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )

            resume_wait_start = len(client.received)
            running_resume_response = send_thread_resume_running(
                client, 5, started_thread_id
            )
            stale_path = make_stale_resume_path(tree_name, run_root)
            stale_resume_response = send_thread_resume_stale_path(
                client, 6, started_thread_id, stale_path
            )
            running_turn_completed = receive_method_since(
                client,
                "turn/completed",
                resume_wait_start,
                timeout_seconds=60,
            )

            final_thread_read_response = send_thread_read(client, 7, started_thread_id)
            final_thread_list_response = send_thread_list(client, 8)
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
            "seed_turn_response": seed_turn_response,
            "seed_turn_started_notification": seed_turn_started,
            "seed_turn_completed_notification": seed_turn_completed,
            "running_turn_response": running_turn_response,
            "running_turn_started_notification": running_turn_started,
            "running_resume_response": running_resume_response,
            "stale_resume_path": str(stale_path),
            "stale_resume_response": stale_resume_response,
            "running_turn_completed_notification": running_turn_completed,
            "final_thread_read_response": final_thread_read_response,
            "final_thread_list_response": final_thread_list_response,
            "normalized_running_resume": normalize_running_resume_response(
                running_resume_response, started_thread_id, running_turn_id
            ),
            "normalized_stale_resume_error": normalize_error_response(
                stale_resume_response
            ),
            "normalized_override_warning": normalize_override_warning(
                stderr, workspace
            ),
            "normalized_final_read": normalize_thread_response(
                final_thread_read_response, started_thread_id
            ),
            "normalized_final_list": normalize_thread_list_response(
                final_thread_list_response, started_thread_id
            ),
            "thread_read_path_observation": summarize_path_observation(
                final_thread_read_response, started_thread_id
            ),
            "running_turn_id": running_turn_id,
            "jsonrpc_sent": client.sent,
            "jsonrpc_received": client.received,
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }
        if tree_name == "chat-backend":
            result["chat_package_summary"] = summarize_chat_packages(chat_root)
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-running-rejoin-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument(
        "--run-dir",
        type=pathlib.Path,
        help=(
            "Directory for heavy app-server workspaces and stores. When omitted, "
            "the run data is kept under --output-dir/run for backwards compatibility."
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)
    run_root = (args.run_dir.resolve() if args.run_dir else output_dir / "run")
    if run_root.exists():
        raise RuntimeError(f"run directory already exists: {run_root}")

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

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

    original_resume = original_result["normalized_running_resume"]
    chat_resume = chat_result["normalized_running_resume"]
    original_stale_error = original_result["normalized_stale_resume_error"]
    chat_stale_error = chat_result["normalized_stale_resume_error"]
    original_override_warning = original_result["normalized_override_warning"]
    chat_override_warning = chat_result["normalized_override_warning"]
    original_final_read = original_result["normalized_final_read"]
    chat_final_read = chat_result["normalized_final_read"]
    original_final_list = original_result["normalized_final_list"]
    chat_final_list = chat_result["normalized_final_list"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_lines = line_count(original_storage, "rollouts")
    chat_packages = chat_package.get("packages") or []
    chat_journal_lines = (
        chat_packages[0].get("journal_line_count") if len(chat_packages) == 1 else None
    )
    chat_timeline_lines = (
        chat_packages[0].get("timeline_line_count") if len(chat_packages) == 1 else None
    )

    mock_second_turn_context_ok = all(
        [
            original_mock["response_request_count"] == 2,
            chat_mock["response_request_count"] == 2,
            original_mock["second_response_input_contains_seed_user_text"],
            chat_mock["second_response_input_contains_seed_user_text"],
            original_mock["second_response_input_contains_seed_assistant_text"],
            chat_mock["second_response_input_contains_seed_assistant_text"],
            original_mock["second_response_input_contains_running_user_text"],
            chat_mock["second_response_input_contains_running_user_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-running-rejoin-smoke",
        "binary_checks": binary_checks,
        "original_seed_turn_exit_ok": "result" in original_result["seed_turn_response"],
        "chat_backend_seed_turn_exit_ok": "result" in chat_result["seed_turn_response"],
        "original_running_turn_exit_ok": "result"
        in original_result["running_turn_response"],
        "chat_backend_running_turn_exit_ok": "result"
        in chat_result["running_turn_response"],
        "original_running_resume_exit_ok": "result"
        in original_result["running_resume_response"],
        "chat_backend_running_resume_exit_ok": "result"
        in chat_result["running_resume_response"],
        "original_stale_resume_error_ok": "error"
        in original_result["stale_resume_response"],
        "chat_backend_stale_resume_error_ok": "error"
        in chat_result["stale_resume_response"],
        "original_final_read_exit_ok": "result"
        in original_result["final_thread_read_response"],
        "chat_backend_final_read_exit_ok": "result"
        in chat_result["final_thread_read_response"],
        "original_final_list_exit_ok": "result"
        in original_result["final_thread_list_response"],
        "chat_backend_final_list_exit_ok": "result"
        in chat_result["final_thread_list_response"],
        "normalized_running_resume_equal": original_resume == chat_resume,
        "normalized_stale_resume_error_equal": (
            original_stale_error == chat_stale_error
        ),
        "normalized_override_warning_equal": (
            original_override_warning == chat_override_warning
        ),
        "normalized_final_read_equal": original_final_read == chat_final_read,
        "normalized_final_list_equal": original_final_list == chat_final_list,
        "original_running_resume_saw_in_progress_turn": (
            original_resume["initial_turns_page_contains_running_turn"]
            and original_resume["running_turn_status"] == "inProgress"
        ),
        "chat_backend_running_resume_saw_in_progress_turn": (
            chat_resume["initial_turns_page_contains_running_turn"]
            and chat_resume["running_turn_status"] == "inProgress"
        ),
        "original_stale_resume_rejected": (
            original_stale_error["has_error"]
            and original_stale_error["message_contains_stale_path"]
        ),
        "chat_backend_stale_resume_rejected": (
            chat_stale_error["has_error"]
            and chat_stale_error["message_contains_stale_path"]
        ),
        "original_override_warning_ok": all(original_override_warning.values()),
        "chat_backend_override_warning_ok": all(chat_override_warning.values()),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_second_turn_context_ok": mock_second_turn_context_ok,
        "chat_package_running_rejoin_ok": chat_package_running_rejoin_ok(chat_package),
        "journal_line_count_matches_original": (
            original_lines is not None and original_lines == chat_journal_lines
        ),
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_running_resume": original_resume,
        "chat_backend_normalized_running_resume": chat_resume,
        "original_normalized_stale_resume_error": original_stale_error,
        "chat_backend_normalized_stale_resume_error": chat_stale_error,
        "original_normalized_override_warning": original_override_warning,
        "chat_backend_normalized_override_warning": chat_override_warning,
        "stale_resume_path_observations": {
            "original": original_result["stale_resume_path"],
            "chat-backend": chat_result["stale_resume_path"],
        },
        "original_normalized_final_read": original_final_read,
        "chat_backend_normalized_final_read": chat_final_read,
        "original_normalized_final_list": original_final_list,
        "chat_backend_normalized_final_list": chat_final_list,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observation"],
            "chat-backend": chat_result["thread_read_path_observation"],
        },
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "fork/rollback/compaction parity",
            "command/tool execution parity",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Running Rejoin Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local delayed
mock Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server running-resume and listener code was also read.

## Scope

This smoke covers one completed seed turn, a second delayed `turn/start`, the
`turn/started` notification, `thread/resume` while that turn is still running,
the eventual `turn/completed`, and final `thread/read` / `thread/list`.

It proves R03 running rejoin, R04 stale-path rejection, and an R05
override-mismatch warning slice for this harness. It does not prove fork,
rollback, compaction, command/tool execution, archive/search/delete, crash
recovery, complete data fidelity, or final user-indistinguishability.

## Result

- original running `thread/resume` response succeeded: `{summary['original_running_resume_exit_ok']}`
- `.chat` backend running `thread/resume` response succeeded: `{summary['chat_backend_running_resume_exit_ok']}`
- normalized original vs `.chat` running `thread/resume` fields equal: `{summary['normalized_running_resume_equal']}`
- original running resume saw the in-progress turn: `{summary['original_running_resume_saw_in_progress_turn']}`
- `.chat` backend running resume saw the in-progress turn: `{summary['chat_backend_running_resume_saw_in_progress_turn']}`
- original stale-path running `thread/resume` was rejected: `{summary['original_stale_resume_rejected']}`
- `.chat` backend stale-path running `thread/resume` was rejected: `{summary['chat_backend_stale_resume_rejected']}`
- normalized original vs `.chat` stale-path error fields equal: `{summary['normalized_stale_resume_error_equal']}`
- original override-mismatch warning was present in stderr: `{summary['original_override_warning_ok']}`
- `.chat` backend override-mismatch warning was present in stderr: `{summary['chat_backend_override_warning_ok']}`
- normalized original vs `.chat` override-mismatch warning fields equal: `{summary['normalized_override_warning_equal']}`
- normalized original vs `.chat` final `thread/read` fields equal: `{summary['normalized_final_read_equal']}`
- normalized original vs `.chat` final `thread/list` fields equal: `{summary['normalized_final_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- second model request included seed user/assistant context and running user text: `{summary['mock_second_turn_context_ok']}`
- durable `.chat` package remained readable after running rejoin: `{summary['chat_package_running_rejoin_ok']}`
- `.chat` journal line count matched original rollout line count: `{summary['journal_line_count_matches_original']}`

## Normalized Running Resume

```json
{json.dumps({'original': original_resume, 'chat-backend': chat_resume}, indent=2, sort_keys=True)}
```

## Normalized Stale Path Error

```json
{json.dumps({'original': original_stale_error, 'chat-backend': chat_stale_error}, indent=2, sort_keys=True)}
```

## Normalized Override Warning

```json
{json.dumps({'original': original_override_warning, 'chat-backend': chat_override_warning}, indent=2, sort_keys=True)}
```

## Final Thread Read

```json
{json.dumps({'original': original_final_read, 'chat-backend': chat_final_read}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
```

## Not Yet Proven

This smoke does not prove fork, rollback, compaction, command/tool execution,
archive/search/delete, crash recovery, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_seed_turn_exit_ok"],
            summary["chat_backend_seed_turn_exit_ok"],
            summary["original_running_turn_exit_ok"],
            summary["chat_backend_running_turn_exit_ok"],
            summary["original_running_resume_exit_ok"],
            summary["chat_backend_running_resume_exit_ok"],
            summary["original_stale_resume_error_ok"],
            summary["chat_backend_stale_resume_error_ok"],
            summary["original_final_read_exit_ok"],
            summary["chat_backend_final_read_exit_ok"],
            summary["original_final_list_exit_ok"],
            summary["chat_backend_final_list_exit_ok"],
            summary["normalized_running_resume_equal"],
            summary["normalized_stale_resume_error_equal"],
            summary["normalized_final_read_equal"],
            summary["normalized_final_list_equal"],
            summary["original_running_resume_saw_in_progress_turn"],
            summary["chat_backend_running_resume_saw_in_progress_turn"],
            summary["original_stale_resume_rejected"],
            summary["chat_backend_stale_resume_rejected"],
            summary["original_override_warning_ok"],
            summary["chat_backend_override_warning_ok"],
            summary["normalized_override_warning_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_second_turn_context_ok"],
            summary["chat_package_running_rejoin_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
