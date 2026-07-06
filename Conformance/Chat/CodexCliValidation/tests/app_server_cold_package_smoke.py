#!/usr/bin/env python3
"""Run cold-package representation app-server parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend. The
`.chat` run intentionally moves a durable `<thread-id>.chat/` package to the
internal cold sibling representation `<thread-id>.chat.cold/`, then verifies
that normal app-server read/list/search/resume/append/delete behavior remains
indistinguishable from the original backend for this slice.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import shutil
import sys
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
    read_json_lines,
    status_type,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    normalize_delete_error,
    normalize_empty_response,
)


FIRST_USER_TEXT = "Persist this cold package validation turn."
SECOND_USER_TEXT = "Continue after cold package materialization."
ASSISTANT_TEXT = "Cold package representation answer from mock model."
SEARCH_TERM = "cold package validation"

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Spec/Chat/CorePackage.md",
    "Spec/Chat/TimelineEvents.md",
    "Spec/Chat/CommandTimeline.md",
    "Spec/Chat/Projections.md",
    "Spec/Chat/ContextAndJournal.md",
    "Spec/Chat/Conformance.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/CODEX_BACKEND_MAPPING.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_index_repair_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_list_search_archive_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_durable_turn_smoke.py",
]


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "first_response_model": first_body.get("model"),
        "second_response_model": second_body.get("model"),
        "first_response_input_contains_first_user_text": response_input_contains(
            first_body, FIRST_USER_TEXT
        ),
        "first_response_input_contains_second_user_text": response_input_contains(
            first_body, SECOND_USER_TEXT
        ),
        "second_response_input_contains_first_user_text": response_input_contains(
            second_body, FIRST_USER_TEXT
        ),
        "second_response_input_contains_first_assistant_text": response_input_contains(
            second_body, ASSISTANT_TEXT
        ),
        "second_response_input_contains_second_user_text": response_input_contains(
            second_body, SECOND_USER_TEXT
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


def send_thread_search(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/search",
            "params": {
                "limit": 10,
                "archived": False,
                "searchTerm": SEARCH_TERM,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_resume(
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
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_delete(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/delete",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def receive_thread_deleted_optional(
    client: JsonRpcClient,
    thread_id: str | None,
) -> dict[str, Any] | None:
    for message in client.received:
        if message.get("method") != "thread/deleted":
            continue
        params = message.get("params") or {}
        if thread_id is None or params.get("threadId") == thread_id:
            return message
    try:
        return client.receive_until_method("thread/deleted", timeout_seconds=5)
    except TimeoutError:
        return None


def normalize_delete_notification(
    notification: dict[str, Any] | None,
    thread_id: str | None,
) -> dict[str, Any]:
    params = (notification or {}).get("params") or {}
    return {
        "seen": notification is not None,
        "thread_id_matches": thread_id is not None and params.get("threadId") == thread_id,
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
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    listed_thread = None
    if thread_id is not None:
        listed_thread = next(
            (thread for thread in threads if thread.get("id") == thread_id),
            None,
        )
    if listed_thread is None and threads:
        listed_thread = threads[0]

    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_started_thread": listed_thread is not None
        and listed_thread.get("id") == thread_id,
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
                "listed_thread_status_type": status_type(listed_thread.get("status")),
                "listed_thread_turn_count": len(listed_thread.get("turns") or []),
            }
        )
    return normalized


def normalize_thread_search_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    matched_result = None
    if thread_id is not None:
        matched_result = next(
            (
                item
                for item in data
                if ((item.get("thread") or {}).get("id") == thread_id)
            ),
            None,
        )
    if matched_result is None and data:
        matched_result = data[0]

    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "result_count": len(data),
        "contains_started_thread": matched_result is not None
        and ((matched_result.get("thread") or {}).get("id") == thread_id),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }
    if matched_result is not None:
        thread = matched_result.get("thread") or {}
        snippet = matched_result.get("snippet") or ""
        normalized.update(
            {
                "snippet": snippet,
                "snippet_contains_search_term": SEARCH_TERM.lower()
                in snippet.lower(),
                "thread_preview": thread.get("preview"),
                "thread_source": thread.get("source"),
                "thread_status_type": status_type(thread.get("status")),
                "thread_model": thread.get("model"),
                "thread_model_provider": thread.get("modelProvider"),
                "thread_turn_count": len(thread.get("turns") or []),
            }
        )
    return normalized


def cold_package_path(chat_root: pathlib.Path, thread_id: str | None) -> pathlib.Path:
    return chat_root / f"{thread_id}.chat.cold"


def plain_package_path(chat_root: pathlib.Path, thread_id: str | None) -> pathlib.Path:
    return chat_root / f"{thread_id}.chat"


def package_summary(package: pathlib.Path, representation: str) -> dict[str, Any]:
    manifest_path = package / "manifest.json"
    timeline_path = package / "timeline.ndjson"
    journal_path = package / "journal.ndjson"
    index_path = package / "indexes/thread-metadata.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    index = json.loads(index_path.read_text()) if index_path.exists() else None
    timeline_lines = read_json_lines(timeline_path)
    journal_lines = read_json_lines(journal_path)
    return {
        "package": str(package),
        "representation": representation,
        "manifest_exists": manifest_path.exists(),
        "timeline_exists": timeline_path.exists(),
        "journal_exists": journal_path.exists(),
        "index_exists": index_path.exists(),
        "timeline_line_count": len(timeline_lines),
        "journal_line_count": len(journal_lines),
        "manifest_format": (manifest or {}).get("format"),
        "conversation_id": ((manifest or {}).get("conversation") or {}).get("id"),
        "index_thread_id": (index or {}).get("thread_id"),
        "index_rollout_path": (index or {}).get("rollout_path"),
        "timeline_event_types": [line.get("type") for line in timeline_lines],
        "journal_source_schemas": [
            ((line.get("source_transport") or {}).get("schema"))
            for line in journal_lines
        ],
    }


def summarize_chat_representations(chat_root: pathlib.Path) -> dict[str, Any]:
    plain_packages = sorted(chat_root.glob("*.chat"))
    cold_packages = sorted(chat_root.glob("*.chat.cold"))
    return {
        "chat_root": str(chat_root),
        "plain_count": len(plain_packages),
        "cold_count": len(cold_packages),
        "plain_packages": [
            package_summary(package, "plain") for package in plain_packages
        ],
        "cold_packages": [
            package_summary(package, "cold") for package in cold_packages
        ],
    }


def move_plain_to_cold(
    chat_root: pathlib.Path,
    thread_id: str | None,
) -> dict[str, Any]:
    plain = plain_package_path(chat_root, thread_id)
    cold = cold_package_path(chat_root, thread_id)
    before = summarize_chat_representations(chat_root)
    if not plain.exists():
        return {
            "moved": False,
            "reason": "plain package missing",
            "plain": str(plain),
            "cold": str(cold),
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }
    if cold.exists():
        return {
            "moved": False,
            "reason": "cold package already exists",
            "plain": str(plain),
            "cold": str(cold),
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }
    shutil.move(str(plain), str(cold))
    return {
        "moved": True,
        "plain": str(plain),
        "cold": str(cold),
        "before": before,
        "after": summarize_chat_representations(chat_root),
    }


def copy_plain_to_cold_sibling(
    chat_root: pathlib.Path,
    thread_id: str | None,
) -> dict[str, Any]:
    plain = plain_package_path(chat_root, thread_id)
    cold = cold_package_path(chat_root, thread_id)
    before = summarize_chat_representations(chat_root)
    if not plain.exists():
        return {
            "copied": False,
            "reason": "plain package missing",
            "plain": str(plain),
            "cold": str(cold),
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }
    if cold.exists():
        shutil.rmtree(cold)
    shutil.copytree(plain, cold)
    return {
        "copied": True,
        "plain": str(plain),
        "cold": str(cold),
        "before": before,
        "after": summarize_chat_representations(chat_root),
    }


def original_line_count(summary: dict[str, Any]) -> int | None:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return None
    return rollouts[0].get("line_count")


def chat_active_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("plain_packages") or summary.get("cold_packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("journal_line_count")


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

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client, 2, workspace
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-cold-package-1",
                FIRST_USER_TEXT,
            )
            first_read_response = send_thread_read(first_client, 4, thread_id)
        finally:
            first_stderr = first_client.close()

        storage_after_first_turn = (
            summarize_chat_representations(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        cold_move = (
            move_plain_to_cold(chat_root, thread_id)
            if tree_name == "chat-backend"
            else {"moved": False, "note": "original backend remains plain oracle"}
        )
        storage_after_cold_move = (
            summarize_chat_representations(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            cold_read_response = send_thread_read(second_client, 102, thread_id)
            cold_list_response = send_thread_list(second_client, 103)
            cold_search_response = send_thread_search(second_client, 104)
            storage_after_cold_read_ops = (
                summarize_chat_representations(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            resume_response = send_thread_resume(second_client, 105, thread_id)
            storage_after_resume = (
                summarize_chat_representations(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            second_turn_start_response = send_turn_start(
                second_client,
                106,
                thread_id,
                "client-user-message-cold-package-2",
                SECOND_USER_TEXT,
            )
            final_read_response = send_thread_read(second_client, 107, thread_id)
            final_list_response = send_thread_list(second_client, 108)
            final_search_response = send_thread_search(second_client, 109)
            storage_after_second_turn = (
                summarize_chat_representations(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            sibling_copy = (
                copy_plain_to_cold_sibling(chat_root, thread_id)
                if tree_name == "chat-backend"
                else {
                    "copied": False,
                    "note": "original backend has no .chat cold sibling",
                }
            )
            sibling_read_response = send_thread_read(second_client, 110, thread_id)
            sibling_list_response = send_thread_list(second_client, 111)
            sibling_search_response = send_thread_search(second_client, 112)
            storage_with_plain_and_cold = (
                summarize_chat_representations(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            delete_response = send_thread_delete(second_client, 113, thread_id)
            delete_notification = receive_thread_deleted_optional(second_client, thread_id)
            read_after_delete_response = send_thread_read(second_client, 114, thread_id)
            list_after_delete_response = send_thread_list(second_client, 115)
            search_after_delete_response = send_thread_search(second_client, 116)
            storage_after_delete = (
                summarize_chat_representations(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
        finally:
            second_stderr = second_client.close()

        return {
            "tree": tree_name,
            "command": first_client.command,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "thread_id": thread_id,
            "first_process": {
                "initialize_response": first_initialize_response,
                "thread_start_response": thread_start_response,
                "turn_start_response": first_turn_start_response,
                "thread_read_response": first_read_response,
                "jsonrpc_sent": first_client.sent,
                "jsonrpc_received": first_client.received,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "initialize_response": second_initialize_response,
                "cold_read_response": cold_read_response,
                "cold_list_response": cold_list_response,
                "cold_search_response": cold_search_response,
                "resume_response": resume_response,
                "second_turn_start_response": second_turn_start_response,
                "final_read_response": final_read_response,
                "final_list_response": final_list_response,
                "final_search_response": final_search_response,
                "sibling_read_response": sibling_read_response,
                "sibling_list_response": sibling_list_response,
                "sibling_search_response": sibling_search_response,
                "delete_response": delete_response,
                "delete_notification": delete_notification,
                "read_after_delete_response": read_after_delete_response,
                "list_after_delete_response": list_after_delete_response,
                "search_after_delete_response": search_after_delete_response,
                "jsonrpc_sent": second_client.sent,
                "jsonrpc_received": second_client.received,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "storage_after_first_turn": storage_after_first_turn,
            "cold_move": cold_move,
            "storage_after_cold_move": storage_after_cold_move,
            "storage_after_cold_read_ops": storage_after_cold_read_ops,
            "storage_after_resume": storage_after_resume,
            "storage_after_second_turn": storage_after_second_turn,
            "sibling_copy": sibling_copy,
            "storage_with_plain_and_cold": storage_with_plain_and_cold,
            "storage_after_delete": storage_after_delete,
            "normalized_cold_read": normalize_thread_response(cold_read_response, thread_id),
            "normalized_cold_list": normalize_thread_list_response(
                cold_list_response, thread_id
            ),
            "normalized_cold_search": normalize_thread_search_response(
                cold_search_response, thread_id
            ),
            "normalized_resume": normalize_thread_response(resume_response, thread_id),
            "normalized_final_read": normalize_thread_response(
                final_read_response, thread_id
            ),
            "normalized_final_list": normalize_thread_list_response(
                final_list_response, thread_id
            ),
            "normalized_final_search": normalize_thread_search_response(
                final_search_response, thread_id
            ),
            "normalized_sibling_read": normalize_thread_response(
                sibling_read_response, thread_id
            ),
            "normalized_sibling_list": normalize_thread_list_response(
                sibling_list_response, thread_id
            ),
            "normalized_sibling_search": normalize_thread_search_response(
                sibling_search_response, thread_id
            ),
            "normalized_delete_response": normalize_empty_response(delete_response),
            "normalized_delete_notification": normalize_delete_notification(
                delete_notification, thread_id
            ),
            "normalized_read_after_delete_error": normalize_delete_error(
                read_after_delete_response
            ),
            "normalized_list_after_delete": normalize_thread_list_response(
                list_after_delete_response, thread_id
            ),
            "normalized_search_after_delete": normalize_thread_search_response(
                search_after_delete_response, thread_id
            ),
        }


def cold_only_not_materialized(summary: dict[str, Any]) -> bool:
    return summary.get("plain_count") == 0 and summary.get("cold_count") == 1


def materialized_plain_only(summary: dict[str, Any]) -> bool:
    return summary.get("plain_count") == 1 and summary.get("cold_count") == 0


def plain_and_cold_sibling(summary: dict[str, Any]) -> bool:
    return summary.get("plain_count") == 1 and summary.get("cold_count") == 1


def deleted_all_representations(summary: dict[str, Any]) -> bool:
    return summary.get("plain_count") == 0 and summary.get("cold_count") == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-cold-package-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)
    (output_dir / "original").mkdir()
    (output_dir / "chat-backend").mkdir()

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
        [
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    comparison_keys = [
        "normalized_cold_read",
        "normalized_cold_list",
        "normalized_cold_search",
        "normalized_resume",
        "normalized_final_read",
        "normalized_final_list",
        "normalized_final_search",
        "normalized_sibling_read",
        "normalized_sibling_list",
        "normalized_sibling_search",
        "normalized_delete_response",
        "normalized_delete_notification",
        "normalized_read_after_delete_error",
        "normalized_list_after_delete",
        "normalized_search_after_delete",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    original_first_lines = original_line_count(original_result["storage_after_first_turn"])
    original_final_lines = original_line_count(original_result["storage_after_second_turn"])
    chat_cold_lines = chat_active_journal_line_count(
        chat_result["storage_after_cold_read_ops"]
    )
    chat_final_lines = chat_active_journal_line_count(
        chat_result["storage_after_second_turn"]
    )
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    mock_second_turn_context_ok = all(
        [
            original_mock["response_request_count"] == 2,
            chat_mock["response_request_count"] == 2,
            original_mock["second_response_input_contains_first_user_text"],
            chat_mock["second_response_input_contains_first_user_text"],
            original_mock["second_response_input_contains_first_assistant_text"],
            chat_mock["second_response_input_contains_first_assistant_text"],
            original_mock["second_response_input_contains_second_user_text"],
            chat_mock["second_response_input_contains_second_user_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-package-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "comparisons": comparisons,
        "all_normalized_comparisons_equal": all(comparisons.values()),
        "chat_backend_cold_move_succeeded": chat_result["cold_move"].get("moved")
        is True,
        "cold_only_after_move": cold_only_not_materialized(
            chat_result["storage_after_cold_move"]
        ),
        "cold_only_after_read_list_search": cold_only_not_materialized(
            chat_result["storage_after_cold_read_ops"]
        ),
        "resume_materialized_to_plain": materialized_plain_only(
            chat_result["storage_after_resume"]
        ),
        "second_turn_kept_plain_materialized": materialized_plain_only(
            chat_result["storage_after_second_turn"]
        ),
        "plain_and_cold_sibling_created": chat_result["sibling_copy"].get("copied")
        is True
        and plain_and_cold_sibling(chat_result["storage_with_plain_and_cold"]),
        "delete_removed_plain_and_cold": deleted_all_representations(
            chat_result["storage_after_delete"]
        ),
        "chat_cold_journal_lines_match_original_first_turn": original_first_lines
        is not None
        and original_first_lines == chat_cold_lines,
        "chat_final_journal_lines_match_original_final_turn": original_final_lines
        is not None
        and original_final_lines == chat_final_lines,
        "mock_response_request_counts_equal": original_mock["response_request_count"]
        == chat_mock["response_request_count"],
        "mock_second_turn_context_ok": mock_second_turn_context_ok,
        "original_first_turn_rollout_lines": original_first_lines,
        "chat_cold_journal_lines": chat_cold_lines,
        "original_final_rollout_lines": original_final_lines,
        "chat_final_journal_lines": chat_final_lines,
        "original": {
            "cold_read": original_result["normalized_cold_read"],
            "cold_list": original_result["normalized_cold_list"],
            "cold_search": original_result["normalized_cold_search"],
            "resume": original_result["normalized_resume"],
            "final_read": original_result["normalized_final_read"],
            "final_list": original_result["normalized_final_list"],
            "final_search": original_result["normalized_final_search"],
            "sibling_read": original_result["normalized_sibling_read"],
            "sibling_list": original_result["normalized_sibling_list"],
            "sibling_search": original_result["normalized_sibling_search"],
            "delete_response": original_result["normalized_delete_response"],
            "delete_notification": original_result["normalized_delete_notification"],
            "read_after_delete_error": original_result[
                "normalized_read_after_delete_error"
            ],
            "list_after_delete": original_result["normalized_list_after_delete"],
            "search_after_delete": original_result["normalized_search_after_delete"],
        },
        "chat_backend": {
            "cold_read": chat_result["normalized_cold_read"],
            "cold_list": chat_result["normalized_cold_list"],
            "cold_search": chat_result["normalized_cold_search"],
            "resume": chat_result["normalized_resume"],
            "final_read": chat_result["normalized_final_read"],
            "final_list": chat_result["normalized_final_list"],
            "final_search": chat_result["normalized_final_search"],
            "sibling_read": chat_result["normalized_sibling_read"],
            "sibling_list": chat_result["normalized_sibling_list"],
            "sibling_search": chat_result["normalized_sibling_search"],
            "delete_response": chat_result["normalized_delete_response"],
            "delete_notification": chat_result["normalized_delete_notification"],
            "read_after_delete_error": chat_result["normalized_read_after_delete_error"],
            "list_after_delete": chat_result["normalized_list_after_delete"],
            "search_after_delete": chat_result["normalized_search_after_delete"],
            "cold_move": chat_result["cold_move"],
            "sibling_copy": chat_result["sibling_copy"],
            "storage_after_cold_move": chat_result["storage_after_cold_move"],
            "storage_after_cold_read_ops": chat_result["storage_after_cold_read_ops"],
            "storage_after_resume": chat_result["storage_after_resume"],
            "storage_after_second_turn": chat_result["storage_after_second_turn"],
            "storage_with_plain_and_cold": chat_result["storage_with_plain_and_cold"],
            "storage_after_delete": chat_result["storage_after_delete"],
        },
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "proved": [
            "app-server thread/read can read a cold-only .chat package without materializing plain storage",
            "app-server thread/list and thread/search discover a cold-only .chat package without materializing plain storage",
            "app-server thread/resume materializes the cold package back to plain before the follow-up append",
            "follow-up turn after cold materialization preserves prior user and assistant context",
            "when plain and cold siblings both exist, app-server read/list/search expose one logical thread matching original behavior",
            "thread/delete removes both plain and cold .chat representations",
            "covered cold and final journal line counts match original rollout line counts",
        ],
        "not_yet_proven": [
            "actual compressed single-file .chat container format",
            "background cold-history compression worker",
            "CLI-level user-indistinguishability",
            "crash during cold-history representation transition",
            "complete cold-history parity for every Codex lifecycle path",
            "final complete data fidelity",
        ],
    }

    write_json(output_dir / "original/cold-package-response.json", original_result)
    write_json(output_dir / "chat-backend/cold-package-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Cold Package Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

This pass read the public `.chat` spec files,
vendor manifest, baseline checks, backend mapping, parity matrix, current
progress/data-fidelity reports, and the adapted `ChatThreadStore` cold package
implementation before editing.

## Scope

This smoke covers a narrow H01-H03 app-server slice:

```text
create one durable thread
move <thread-id>.chat/ to <thread-id>.chat.cold/
thread/read while cold-only
thread/list while cold-only
thread/search while cold-only
verify cold-only read/list/search did not materialize plain .chat/
thread/resume
verify resume materialized .chat.cold/ back to .chat/
append a follow-up turn
create a duplicate cold sibling beside plain .chat/
verify read/list/search still expose one logical thread
thread/delete
verify plain and cold sibling are both removed
```

It does not prove the final compressed container format, background cold-history
compression, CLI-level indistinguishability, crash during representation
transition, or complete cold-history parity.

## Result

- cold move succeeded: `{summary['chat_backend_cold_move_succeeded']}`
- cold-only after move: `{summary['cold_only_after_move']}`
- cold-only after read/list/search: `{summary['cold_only_after_read_list_search']}`
- resume materialized to plain: `{summary['resume_materialized_to_plain']}`
- second turn kept plain materialized: `{summary['second_turn_kept_plain_materialized']}`
- plain+cold sibling created: `{summary['plain_and_cold_sibling_created']}`
- delete removed plain+cold: `{summary['delete_removed_plain_and_cold']}`
- normalized original vs `.chat` comparisons all equal: `{summary['all_normalized_comparisons_equal']}`
- cold journal lines matched original first-turn rollout lines: `{summary['chat_cold_journal_lines_match_original_first_turn']}`
- final journal lines matched original final rollout lines: `{summary['chat_final_journal_lines_match_original_final_turn']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- second turn received prior context: `{summary['mock_second_turn_context_ok']}`

## Comparisons

```json
{json.dumps(summary['comparisons'], indent=2, sort_keys=True)}
```

## Storage States

```json
{json.dumps({
  'after_cold_move': summary['chat_backend']['storage_after_cold_move'],
  'after_cold_read_ops': summary['chat_backend']['storage_after_cold_read_ops'],
  'after_resume': summary['chat_backend']['storage_after_resume'],
  'after_second_turn': summary['chat_backend']['storage_after_second_turn'],
  'with_plain_and_cold': summary['chat_backend']['storage_with_plain_and_cold'],
  'after_delete': summary['chat_backend']['storage_after_delete'],
}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cold-package-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-package-response.json
```
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["chat_backend_cold_move_succeeded"],
            summary["cold_only_after_move"],
            summary["cold_only_after_read_list_search"],
            summary["resume_materialized_to_plain"],
            summary["second_turn_kept_plain_materialized"],
            summary["plain_and_cold_sibling_created"],
            summary["delete_removed_plain_and_cold"],
            summary["all_normalized_comparisons_equal"],
            summary["chat_cold_journal_lines_match_original_first_turn"],
            summary["chat_final_journal_lines_match_original_final_turn"],
            summary["mock_response_request_counts_equal"],
            summary["mock_second_turn_context_ok"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
