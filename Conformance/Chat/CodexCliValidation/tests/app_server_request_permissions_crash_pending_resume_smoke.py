#!/usr/bin/env python3
"""Run pending request_permissions process-restart parity smoke.

This smoke intentionally kills the app-server process after a standalone
`request_permissions` approval request is emitted and before the request is
answered. It then starts a fresh app-server with the same CODEX_HOME and
compares original Codex behavior with the `.chat` backend behavior.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys
import time
from typing import Any

from app_server_command_approval_crash_pending_resume_smoke import kill_client_process
from app_server_command_approval_crash_pending_resume_smoke import response_request_bodies
from app_server_command_approval_smoke import normalized_live_sequence as command_live_sequence
from app_server_command_approval_smoke import status_type
from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import JsonRpcClient
from app_server_durable_turn_smoke import ensure_binary
from app_server_durable_turn_smoke import read_json_lines
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json
from app_server_file_change_pending_resume_smoke import send_initialize
from app_server_file_change_pending_resume_smoke import send_thread_list
from app_server_file_change_pending_resume_smoke import send_thread_read
from app_server_file_change_pending_resume_smoke import send_thread_resume
from app_server_file_change_pending_resume_smoke import send_thread_start
from app_server_file_change_pending_resume_smoke import send_turn_start
from app_server_file_change_pending_resume_smoke import storage_line_count
from app_server_request_permissions_smoke import CALL_ID
from app_server_request_permissions_smoke import REQUEST_REASON
from app_server_request_permissions_smoke import USER_TEXT
from app_server_request_permissions_smoke import RequestPermissionsResponsesServer
from app_server_request_permissions_smoke import ev_final_message
from app_server_request_permissions_smoke import ev_request_permissions_call
from app_server_request_permissions_smoke import normalize_permission_request
from app_server_request_permissions_smoke import path_role
from app_server_request_permissions_smoke import serialized_contains_scope
from app_server_request_permissions_smoke import write_request_permissions_config


SEED_USER_TEXT = "Seed history before pending request permissions crash."
SEED_ASSISTANT_TEXT = "Seed history persisted before pending request permissions crash."
REQUEST_USER_TEXT = "Run request permissions and keep it pending during restart."

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_approval_crash_pending_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_approval_pending_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_file_change_pending_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/protocol_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class PendingCrashRequestPermissionsResponsesServer(RequestPermissionsResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        # The crash slice only needs a completed seed turn followed by a
        # pending request_permissions function call.
        self.responses = [
            ev_final_message(
                "resp-request-permissions-crash-seed",
                "msg-request-permissions-crash-seed",
                SEED_ASSISTANT_TEXT,
            ),
            ev_request_permissions_call(
                "resp-request-permissions-crash-call",
                CALL_ID,
            ),
        ]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "first_response_input_contains_seed_user_text": body_contains(
            first_body,
            SEED_USER_TEXT,
        ),
        "second_response_input_contains_seed_user_text": body_contains(
            second_body,
            SEED_USER_TEXT,
        ),
        "second_response_input_contains_seed_assistant_text": body_contains(
            second_body,
            SEED_ASSISTANT_TEXT,
        ),
        "second_response_input_contains_request_user_text": body_contains(
            second_body,
            REQUEST_USER_TEXT,
        ),
        "second_response_input_contains_request_permissions": serialized_contains(
            second_body,
            "request_permissions",
        ),
        "second_response_input_contains_request_reason": serialized_contains(
            second_body,
            REQUEST_REASON,
        ),
    }


def receive_permission_request(
    client: JsonRpcClient,
    call_id: str,
    timeout_seconds: int = 30,
) -> dict[str, Any]:
    return client.receive_until(
        lambda message: message.get("method") == "item/permissions/requestApproval"
        and (message.get("params") or {}).get("itemId") == call_id,
        timeout_seconds=timeout_seconds,
        description=f"permissions approval request for {call_id}",
    )


def receive_optional_permission_request(
    client: JsonRpcClient,
    call_id: str,
    timeout_seconds: int = 3,
) -> dict[str, Any] | None:
    try:
        return receive_permission_request(client, call_id, timeout_seconds)
    except TimeoutError:
        return None


def normalize_optional_permission_request(
    request: dict[str, Any] | None,
    expected: dict[str, str | None],
    workspace: pathlib.Path,
) -> dict[str, Any] | None:
    if request is None:
        return None
    return normalize_permission_request(
        request,
        expected,  # type: ignore[arg-type]
        workspace,
    )


def normalize_thread_response(response: dict[str, Any], thread_id: str | None) -> dict[str, Any]:
    result = response.get("result") or {}
    thread = result.get("thread") or {}
    page = result.get("initialTurnsPage") or {}
    thread_turns = thread.get("turns") or []
    page_turns = page.get("data") or []
    all_turns = thread_turns + page_turns
    serialized = json.dumps(all_turns, ensure_ascii=False)
    error = response.get("error") or {}
    return {
        "has_error": "error" in response,
        "error_code": error.get("code"),
        "error_message": error.get("message"),
        "thread_id_matches": thread_id is not None and thread.get("id") == thread_id,
        "thread_status_type": status_type(thread.get("status")),
        "path_present": thread.get("path") is not None,
        "thread_turn_count": len(thread_turns),
        "initial_turns_page_present": bool(page),
        "initial_turns_page_count": len(page_turns),
        "all_turn_statuses": [status_type(turn.get("status")) for turn in all_turns],
        "all_item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in all_turns
        ],
        "contains_seed_user_text": SEED_USER_TEXT in serialized,
        "contains_seed_assistant_text": SEED_ASSISTANT_TEXT in serialized,
        "contains_request_user_text": REQUEST_USER_TEXT in serialized,
        "contains_request_reason": REQUEST_REASON in serialized,
        "contains_request_permissions_item": "request_permissions" in serialized,
        "contains_call_id": CALL_ID in serialized,
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    listed = None
    if thread_id is not None:
        listed = next((thread for thread in threads if thread.get("id") == thread_id), None)
    if listed is None and threads:
        listed = threads[0]
    error = response.get("error") or {}
    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "error_code": error.get("code"),
        "error_message": error.get("message"),
        "thread_count": len(threads),
        "contains_started_thread": listed is not None
        and thread_id is not None
        and listed.get("id") == thread_id,
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }
    if listed is not None:
        normalized.update(
            {
                "listed_thread_ephemeral": listed.get("ephemeral"),
                "listed_thread_model_provider": listed.get("modelProvider"),
                "listed_thread_model": listed.get("model"),
                "listed_thread_name": listed.get("name"),
                "listed_thread_preview": listed.get("preview"),
                "listed_thread_source": listed.get("source"),
                "listed_thread_status_type": status_type(listed.get("status")),
                "listed_thread_turn_count": len(listed.get("turns") or []),
            }
        )
    return normalized


def normalize_permission_live_sequence(
    received: list[dict[str, Any]],
    workspace: pathlib.Path,
) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/permissions/requestApproval":
            permissions = params.get("permissions") or {}
            file_system = permissions.get("fileSystem") or {}
            sequence.append(
                {
                    "event": "permissionsRequest",
                    "itemId": params.get("itemId"),
                    "reasonMatches": params.get("reason") == REQUEST_REASON,
                    "cwdRole": path_role(params.get("cwd"), workspace),
                    "writeCount": len(file_system.get("write") or []),
                    "writeRoles": [
                        path_role(path, workspace) for path in file_system.get("write") or []
                    ],
                }
            )
        elif method == "serverRequest/resolved":
            sequence.append(
                {
                    "event": "serverRequestResolved",
                    "requestIdPresent": params.get("requestId") is not None,
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    # Include generic command status events if restart unexpectedly continues.
    return sequence + [
        event
        for event in command_live_sequence(received)
        if event.get("event") not in {"turnCompleted"}
    ]


def summarize_request_permissions_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = [
            (((line.get("source_transport") or {}).get("payload") or {}).get("payload") or {})
            for line in journal_lines
        ]
        serialized_timeline = json.dumps(timeline_lines, ensure_ascii=False)
        serialized_journal = json.dumps(journal_payloads, ensure_ascii=False)
        packages.append(
            {
                "package": str(package),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_tool_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "tool_call"
                ),
                "timeline_tool_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "tool_output"
                ),
                "timeline_command_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_call"
                ),
                "timeline_contains_request_permissions": "request_permissions"
                in serialized_timeline,
                "timeline_contains_request_reason": REQUEST_REASON in serialized_timeline,
                "journal_function_call_names": [
                    payload.get("name")
                    for payload in journal_payloads
                    if payload.get("type") == "function_call"
                ],
                "journal_function_call_output_call_ids": [
                    payload.get("call_id")
                    for payload in journal_payloads
                    if payload.get("type") == "function_call_output"
                ],
                "journal_has_request_permissions_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "request_permissions"
                    for payload in journal_payloads
                ),
                "journal_has_function_call_output": any(
                    payload.get("type") == "function_call_output"
                    and payload.get("call_id") == CALL_ID
                    for payload in journal_payloads
                ),
                "journal_contains_request_reason": REQUEST_REASON in serialized_journal,
                "journal_contains_session_scope": serialized_contains_scope(
                    serialized_journal,
                    "session",
                ),
                "journal_contains_turn_scope": serialized_contains_scope(
                    serialized_journal,
                    "turn",
                ),
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_request_permissions_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
        serialized_lines = json.dumps(lines, ensure_ascii=False)
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "payload_types": [item.get("type") for item in lines],
                "response_item_types": [
                    ((item.get("payload") or {}).get("type"))
                    for item in lines
                    if item.get("type") == "response_item"
                ],
                "function_call_names": [
                    ((item.get("payload") or {}).get("name"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call"
                ],
                "function_call_output_call_ids": [
                    ((item.get("payload") or {}).get("call_id"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call_output"
                ],
                "contains_request_permissions": "request_permissions" in serialized_lines,
                "contains_request_reason": REQUEST_REASON in serialized_lines,
                "contains_session_scope": serialized_contains_scope(
                    serialized_lines,
                    "session",
                ),
                "contains_turn_scope": serialized_contains_scope(serialized_lines, "turn"),
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def request_permissions_pending_storage_equivalent(
    original_summary: dict[str, Any],
    chat_summary: dict[str, Any],
) -> bool:
    original_rollouts = original_summary.get("rollouts") or []
    chat_packages = chat_summary.get("packages") or []
    if len(original_rollouts) != 1 or len(chat_packages) != 1:
        return False
    original = original_rollouts[0]
    chat = chat_packages[0]
    original_has_call = "request_permissions" in original["function_call_names"]
    original_outputs = original["function_call_output_call_ids"]
    return (
        chat["journal_has_request_permissions_call"] == original_has_call
        and chat["timeline_tool_call_count"] == (1 if original_has_call else 0)
        and chat["timeline_tool_output_count"] == len(original_outputs)
        and chat["journal_function_call_output_call_ids"] == original_outputs
        and chat["journal_contains_request_reason"] == original["contains_request_reason"]
        and not chat["timeline_command_call_count"]
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

    with PendingCrashRequestPermissionsResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        thread_id = None
        request_turn_id = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)

            seed_turn_id, seed_turn_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-pending-request-permissions-crash-seed",
                SEED_USER_TEXT,
            )
            seed_turn_completed = first_client.receive_until_method(
                "turn/completed",
                timeout_seconds=60,
            )

            request_turn_id, request_turn_response = send_turn_start(
                first_client,
                4,
                thread_id,
                "client-user-pending-request-permissions-crash-request",
                REQUEST_USER_TEXT,
            )
            initial_permission_request = receive_permission_request(first_client, CALL_ID)
        finally:
            crash_observation = kill_client_process(first_client)

        restarted_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        try:
            restart_initialize_response = send_initialize(restarted_client, 10)
            restart_resume_response = send_thread_resume(restarted_client, 11, thread_id)
            replayed_permission_request = receive_optional_permission_request(
                restarted_client,
                CALL_ID,
                timeout_seconds=3,
            )
            restart_thread_read = send_thread_read(restarted_client, 12, thread_id)
            restart_thread_list = send_thread_list(restarted_client, 13)
        finally:
            restart_stderr = restarted_client.close()

    expected = {
        "thread_id": thread_id,
        "turn_id": request_turn_id,
        "call_id": CALL_ID,
    }
    result: dict[str, Any] = {
        "tree": tree_name,
        "command": first_client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "seed_turn_id": seed_turn_id,
        "seed_turn_response": seed_turn_response,
        "seed_turn_completed": seed_turn_completed,
        "request_turn_id": request_turn_id,
        "request_turn_response": request_turn_response,
        "initial_permission_request": initial_permission_request,
        "normalized_initial_permission_request": normalize_permission_request(
            initial_permission_request,
            expected,  # type: ignore[arg-type]
            workspace,
        ),
        "crash_observation": crash_observation,
        "restart_initialize_response": restart_initialize_response,
        "restart_resume_response": restart_resume_response,
        "normalized_restart_resume": normalize_thread_response(
            restart_resume_response,
            thread_id,
        ),
        "replayed_permission_request_after_restart": replayed_permission_request,
        "normalized_replayed_permission_request_after_restart": (
            normalize_optional_permission_request(
                replayed_permission_request,
                expected,
                workspace,
            )
        ),
        "restart_thread_read": restart_thread_read,
        "normalized_restart_read": normalize_thread_response(
            restart_thread_read,
            thread_id,
        ),
        "restart_thread_list": restart_thread_list,
        "normalized_restart_list": normalize_thread_list_response(
            restart_thread_list,
            thread_id,
        ),
        "initial_live_sequence": normalize_permission_live_sequence(
            first_client.received,
            workspace,
        ),
        "restart_live_sequence": normalize_permission_live_sequence(
            restarted_client.received,
            workspace,
        ),
        "first_jsonrpc_sent": first_client.sent,
        "first_jsonrpc_received": first_client.received,
        "restart_jsonrpc_sent": restarted_client.sent,
        "restart_jsonrpc_received": restarted_client.received,
        "restart_stderr_tail": restart_stderr[-6000:],
        "restart_process_exit_code": restarted_client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_request_permissions_chat_timeline(
            chat_root
        )
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_request_permissions_original_rollouts(
            codex_home
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-request-permissions-crash-pending-resume-smoke-"
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

    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_rollout_lines = storage_line_count(original_storage, "rollouts")
    chat_packages = chat_package.get("packages") or []
    chat_journal_lines = (
        chat_packages[0].get("journal_line_count") if len(chat_packages) == 1 else None
    )
    chat_timeline_lines = (
        chat_packages[0].get("timeline_line_count") if len(chat_packages) == 1 else None
    )
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    original_replayed_after_restart = (
        original_result["normalized_replayed_permission_request_after_restart"] is not None
    )
    chat_replayed_after_restart = (
        chat_result["normalized_replayed_permission_request_after_restart"] is not None
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-request-permissions-crash-pending-resume-smoke",
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_seed_turn_exit_ok": "result" in original_result["seed_turn_response"],
        "chat_backend_seed_turn_exit_ok": "result" in chat_result["seed_turn_response"],
        "original_request_turn_exit_ok": "result" in original_result["request_turn_response"],
        "chat_backend_request_turn_exit_ok": "result" in chat_result["request_turn_response"],
        "original_process_was_killed": original_result["crash_observation"]["exit_code"] is not None
        and original_result["crash_observation"]["exit_code"] < 0,
        "chat_backend_process_was_killed": chat_result["crash_observation"]["exit_code"] is not None
        and chat_result["crash_observation"]["exit_code"] < 0,
        "normalized_initial_permission_request_equal": (
            original_result["normalized_initial_permission_request"]
            == chat_result["normalized_initial_permission_request"]
        ),
        "original_restart_resume_exit_ok": "result" in original_result["restart_resume_response"],
        "chat_backend_restart_resume_exit_ok": "result" in chat_result["restart_resume_response"],
        "normalized_restart_resume_equal": (
            original_result["normalized_restart_resume"]
            == chat_result["normalized_restart_resume"]
        ),
        "original_replayed_permission_after_restart": original_replayed_after_restart,
        "chat_backend_replayed_permission_after_restart": chat_replayed_after_restart,
        "restarted_replayed_permission_equal": (
            original_result["normalized_replayed_permission_request_after_restart"]
            == chat_result["normalized_replayed_permission_request_after_restart"]
        ),
        "original_restart_thread_read_exit_ok": "result" in original_result["restart_thread_read"],
        "chat_backend_restart_thread_read_exit_ok": "result" in chat_result["restart_thread_read"],
        "normalized_restart_read_equal": (
            original_result["normalized_restart_read"]
            == chat_result["normalized_restart_read"]
        ),
        "original_restart_thread_list_exit_ok": "result" in original_result["restart_thread_list"],
        "chat_backend_restart_thread_list_exit_ok": "result" in chat_result["restart_thread_list"],
        "normalized_restart_list_equal": (
            original_result["normalized_restart_list"]
            == chat_result["normalized_restart_list"]
        ),
        "initial_live_sequence_equal": (
            original_result["initial_live_sequence"] == chat_result["initial_live_sequence"]
        ),
        "restart_live_sequence_equal": (
            original_result["restart_live_sequence"] == chat_result["restart_live_sequence"]
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"] == chat_mock["response_request_count"]
        ),
        "mock_context_equal": original_mock == chat_mock,
        "request_permissions_pending_storage_equivalent": (
            request_permissions_pending_storage_equivalent(
                original_result["original_rollout_summary"],
                chat_result["chat_timeline_summary"],
            )
        ),
        "journal_line_count_matches_original": (
            original_rollout_lines is not None and original_rollout_lines == chat_journal_lines
        ),
        "timeline_line_count_matches_original": (
            original_rollout_lines is not None and original_rollout_lines == chat_timeline_lines
        ),
        "original_rollout_line_count": original_rollout_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_initial_permission_request": original_result[
            "normalized_initial_permission_request"
        ],
        "chat_backend_normalized_initial_permission_request": chat_result[
            "normalized_initial_permission_request"
        ],
        "original_normalized_restart_resume": original_result["normalized_restart_resume"],
        "chat_backend_normalized_restart_resume": chat_result["normalized_restart_resume"],
        "original_normalized_replayed_permission_after_restart": original_result[
            "normalized_replayed_permission_request_after_restart"
        ],
        "chat_backend_normalized_replayed_permission_after_restart": chat_result[
            "normalized_replayed_permission_request_after_restart"
        ],
        "original_normalized_restart_read": original_result["normalized_restart_read"],
        "chat_backend_normalized_restart_read": chat_result["normalized_restart_read"],
        "original_normalized_restart_list": original_result["normalized_restart_list"],
        "chat_backend_normalized_restart_list": chat_result["normalized_restart_list"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_crash_observation": original_result["crash_observation"],
        "chat_backend_crash_observation": chat_result["crash_observation"],
        "original_storage_summary": original_storage,
        "original_rollout_summary": original_result["original_rollout_summary"],
        "chat_package_summary": chat_package,
        "chat_timeline_summary": chat_result["chat_timeline_summary"],
        "not_yet_proven": [
            "request_permissions crash during durable write boundaries",
            "CLI/TUI request_permissions process-kill parity",
            "complete global Codex data-fidelity report",
        ],
        "all_scenarios_ok": False,
    }
    summary["all_scenarios_ok"] = all(
        [
            summary["original_seed_turn_exit_ok"],
            summary["chat_backend_seed_turn_exit_ok"],
            summary["original_request_turn_exit_ok"],
            summary["chat_backend_request_turn_exit_ok"],
            summary["original_process_was_killed"],
            summary["chat_backend_process_was_killed"],
            summary["normalized_initial_permission_request_equal"],
            summary["original_restart_resume_exit_ok"],
            summary["chat_backend_restart_resume_exit_ok"],
            summary["normalized_restart_resume_equal"],
            summary["restarted_replayed_permission_equal"],
            summary["original_restart_thread_read_exit_ok"],
            summary["chat_backend_restart_thread_read_exit_ok"],
            summary["normalized_restart_read_equal"],
            summary["original_restart_thread_list_exit_ok"],
            summary["chat_backend_restart_thread_list_exit_ok"],
            summary["normalized_restart_list_equal"],
            summary["initial_live_sequence_equal"],
            summary["restart_live_sequence_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_context_equal"],
            summary["request_permissions_pending_storage_equivalent"],
            summary["journal_line_count_matches_original"],
            summary["timeline_line_count_matches_original"],
        ]
    )

    write_json(
        output_dir / "original/request-permissions-crash-pending-resume-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/request-permissions-crash-pending-resume-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Request Permissions Crash Pending Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with the standalone `request_permissions` tool enabled.

## Gate

Before this work, the public `.chat` gate note, spec files,
vendor manifest, baseline checks, backend mapping, parity matrix, current
parity/data-fidelity/user-visible/crash reports, existing request-permissions
and pending-crash tests, and relevant vendored Codex routing/persistence source
files were read.

## Scope

This smoke covers a turn whose `item/permissions/requestApproval` request is
still pending, then kills the app-server process before any approval response
is sent. It starts a fresh app-server with the same `CODEX_HOME` and compares
`thread/resume`, `thread/read`, `thread/list`, live notifications, mock model
request context, and durable storage between the original backend and the
`.chat` backend.

The test intentionally follows original Codex behavior. If the original backend
does not restore an in-memory pending permissions prompt after process death,
the `.chat` backend must match that behavior rather than fabricating a stronger
durable approval contract.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-crash-pending-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-crash-pending-resume-response.json
```

## Not Yet Proven

This smoke does not prove crash behavior at every durable write boundary, does
not cover the CLI/TUI process-kill surface, and does not replace the complete
global Codex data-fidelity report.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
