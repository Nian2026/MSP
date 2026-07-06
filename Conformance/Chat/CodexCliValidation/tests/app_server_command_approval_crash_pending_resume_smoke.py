#!/usr/bin/env python3
"""Run pending command approval process-restart parity smoke.

This smoke intentionally kills the app-server process after a command approval
request is emitted and before the request is answered. It then starts a fresh
app-server with the same CODEX_HOME and compares original Codex behavior with
the `.chat` backend behavior.
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

from app_server_command_approval_pending_resume_smoke import COMMAND_CALL_ID
from app_server_command_approval_pending_resume_smoke import COMMAND_USER_TEXT
from app_server_command_approval_pending_resume_smoke import SEED_ASSISTANT_TEXT
from app_server_command_approval_pending_resume_smoke import SEED_USER_TEXT
from app_server_command_approval_pending_resume_smoke import STDOUT_MARKER
from app_server_command_approval_pending_resume_smoke import PendingCommandApprovalResponsesServer
from app_server_command_approval_pending_resume_smoke import receive_command_approval_request
from app_server_command_approval_pending_resume_smoke import response_input_contains
from app_server_command_approval_smoke import normalize_approval_request
from app_server_command_approval_smoke import normalized_live_sequence
from app_server_command_approval_smoke import status_type
from app_server_command_approval_smoke import write_approval_config
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


def kill_client_process(client: JsonRpcClient) -> dict[str, Any]:
    started_at = time.time()
    if client.process.poll() is None:
        client.process.kill()
    try:
        client.process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        client.process.terminate()
        client.process.wait(timeout=10)
    assert client.process.stderr is not None
    stderr = client.process.stderr.read()
    return {
        "exit_code": client.process.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stderr_tail": stderr[-6000:],
    }


def receive_optional_command_approval_request(
    client: JsonRpcClient,
    call_id: str,
    timeout_seconds: int = 3,
) -> dict[str, Any] | None:
    try:
        return receive_command_approval_request(client, call_id, timeout_seconds)
    except TimeoutError:
        return None


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
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
        "second_response_input_contains_command_user_text": response_input_contains(
            second_body,
            COMMAND_USER_TEXT,
        ),
        "third_response_input_contains_command_user_text": response_input_contains(
            third_body,
            COMMAND_USER_TEXT,
        ),
        "third_response_input_contains_call_id": response_input_contains(
            third_body,
            COMMAND_CALL_ID,
        ),
        "third_response_input_contains_stdout": response_input_contains(
            third_body,
            STDOUT_MARKER,
        ),
        "third_response_input_contains_function_output": response_input_contains(
            third_body,
            "function_call_output",
        ),
    }


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
        "contains_command_user_text": COMMAND_USER_TEXT in serialized,
        "contains_command_item": "commandExecution" in serialized,
        "contains_call_id": COMMAND_CALL_ID in serialized,
        "contains_stdout": STDOUT_MARKER in serialized,
    }


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


def normalize_optional_approval_request(
    request: dict[str, Any] | None,
    expected: dict[str, str | None],
) -> dict[str, Any] | None:
    if request is None:
        return None
    return normalize_approval_request(request, expected)  # type: ignore[arg-type]


def summarize_pending_crash_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = [
            (((line.get("source_transport") or {}).get("payload") or {}).get("payload") or {})
            for line in journal_lines
        ]
        packages.append(
            {
                "package": str(package),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_command_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_call"
                ),
                "timeline_command_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_output"
                ),
                "timeline_policy_event_count": sum(
                    1
                    for line in timeline_lines
                    if line.get("type") in {"policy_request", "policy_decision"}
                ),
                "journal_shell_command_call_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                ),
                "journal_function_output_call_ids": [
                    payload.get("call_id")
                    for payload in journal_payloads
                    if payload.get("type") == "function_call_output"
                ],
                "journal_contains_command_marker": any(
                    STDOUT_MARKER in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_pending_crash_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
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
                    and (item.get("payload") or {}).get("type")
                    == "function_call_output"
                ],
                "contains_command_marker": any(
                    STDOUT_MARKER in json.dumps(item, ensure_ascii=False)
                    for item in lines
                ),
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def command_pending_storage_equivalent(
    original_summary: dict[str, Any],
    chat_summary: dict[str, Any],
) -> bool:
    original_rollouts = original_summary.get("rollouts") or []
    chat_packages = chat_summary.get("packages") or []
    if len(original_rollouts) != 1 or len(chat_packages) != 1:
        return False
    original = original_rollouts[0]
    chat = chat_packages[0]
    original_has_call = "shell_command" in original["function_call_names"]
    original_outputs = original["function_call_output_call_ids"]
    return (
        chat["timeline_policy_event_count"] == 0
        and chat["journal_shell_command_call_count"] == (1 if original_has_call else 0)
        and chat["timeline_command_call_count"] == (1 if original_has_call else 0)
        and chat["timeline_command_output_count"] == len(original_outputs)
        and chat["journal_function_output_call_ids"] == original_outputs
        and chat["journal_contains_command_marker"] == original["contains_command_marker"]
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

    with PendingCommandApprovalResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        thread_id = None
        command_turn_id = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)

            seed_turn_id, seed_turn_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-pending-command-approval-crash-seed",
                SEED_USER_TEXT,
            )
            seed_turn_completed = first_client.receive_until_method(
                "turn/completed",
                timeout_seconds=60,
            )

            command_turn_id, command_turn_response = send_turn_start(
                first_client,
                4,
                thread_id,
                "client-user-pending-command-approval-crash-command",
                COMMAND_USER_TEXT,
            )
            initial_approval_request = receive_command_approval_request(
                first_client,
                COMMAND_CALL_ID,
            )
        finally:
            crash_observation = kill_client_process(first_client)

        restarted_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        try:
            restart_initialize_response = send_initialize(restarted_client, 10)
            restart_resume_response = send_thread_resume(restarted_client, 11, thread_id)
            replayed_approval_request = receive_optional_command_approval_request(
                restarted_client,
                COMMAND_CALL_ID,
                timeout_seconds=3,
            )
            restart_thread_read = send_thread_read(restarted_client, 12, thread_id)
            restart_thread_list = send_thread_list(restarted_client, 13)
        finally:
            restart_stderr = restarted_client.close()

    expected = {
        "thread_id": thread_id,
        "turn_id": command_turn_id,
        "call_id": COMMAND_CALL_ID,
        "command_marker": STDOUT_MARKER,
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
        "command_turn_id": command_turn_id,
        "command_turn_response": command_turn_response,
        "initial_approval_request": initial_approval_request,
        "normalized_initial_approval_request": normalize_approval_request(
            initial_approval_request,
            expected,  # type: ignore[arg-type]
        ),
        "crash_observation": crash_observation,
        "restart_initialize_response": restart_initialize_response,
        "restart_resume_response": restart_resume_response,
        "normalized_restart_resume": normalize_thread_response(
            restart_resume_response,
            thread_id,
        ),
        "replayed_approval_request_after_restart": replayed_approval_request,
        "normalized_replayed_approval_request_after_restart": normalize_optional_approval_request(
            replayed_approval_request,
            expected,
        ),
        "restart_thread_read": restart_thread_read,
        "normalized_restart_read": normalize_thread_response(
            restart_thread_read,
            thread_id,
        ),
        "restart_read_path_observation": summarize_path_observation(
            restart_thread_read,
            thread_id,
        ),
        "restart_thread_list": restart_thread_list,
        "normalized_restart_list": normalize_thread_list_response(
            restart_thread_list,
            thread_id,
        ),
        "initial_live_sequence": normalized_live_sequence(first_client.received),
        "restart_live_sequence": normalized_live_sequence(restarted_client.received),
        "first_jsonrpc_sent": first_client.sent,
        "first_jsonrpc_received": first_client.received,
        "restart_jsonrpc_sent": restarted_client.sent,
        "restart_jsonrpc_received": restarted_client.received,
        "restart_stderr_tail": restart_stderr[-6000:],
        "restart_process_exit_code": restarted_client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_pending_crash_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_pending_crash_original_rollouts(
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
            "app-server-command-approval-crash-pending-resume-smoke-"
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
        original_result["normalized_replayed_approval_request_after_restart"] is not None
    )
    chat_replayed_after_restart = (
        chat_result["normalized_replayed_approval_request_after_restart"] is not None
    )
    restarted_replay_equal = (
        original_result["normalized_replayed_approval_request_after_restart"]
        == chat_result["normalized_replayed_approval_request_after_restart"]
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-command-approval-crash-pending-resume-smoke",
        "binary_checks": binary_checks,
        "original_seed_turn_exit_ok": "result" in original_result["seed_turn_response"],
        "chat_backend_seed_turn_exit_ok": "result" in chat_result["seed_turn_response"],
        "original_command_turn_exit_ok": "result" in original_result["command_turn_response"],
        "chat_backend_command_turn_exit_ok": "result" in chat_result["command_turn_response"],
        "original_process_was_killed": original_result["crash_observation"]["exit_code"] is not None
        and original_result["crash_observation"]["exit_code"] < 0,
        "chat_backend_process_was_killed": chat_result["crash_observation"]["exit_code"] is not None
        and chat_result["crash_observation"]["exit_code"] < 0,
        "normalized_initial_approval_request_equal": (
            original_result["normalized_initial_approval_request"]
            == chat_result["normalized_initial_approval_request"]
        ),
        "original_restart_resume_exit_ok": "result" in original_result["restart_resume_response"],
        "chat_backend_restart_resume_exit_ok": "result" in chat_result["restart_resume_response"],
        "normalized_restart_resume_equal": (
            original_result["normalized_restart_resume"]
            == chat_result["normalized_restart_resume"]
        ),
        "original_replayed_approval_after_restart": original_replayed_after_restart,
        "chat_backend_replayed_approval_after_restart": chat_replayed_after_restart,
        "restarted_replayed_approval_equal": restarted_replay_equal,
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
        "command_pending_storage_equivalent": command_pending_storage_equivalent(
            original_result["original_rollout_summary"],
            chat_result["chat_timeline_summary"],
        ),
        "journal_line_count_matches_original": (
            original_rollout_lines is not None and original_rollout_lines == chat_journal_lines
        ),
        "original_rollout_line_count": original_rollout_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_initial_approval_request": original_result[
            "normalized_initial_approval_request"
        ],
        "chat_backend_normalized_initial_approval_request": chat_result[
            "normalized_initial_approval_request"
        ],
        "original_normalized_restart_resume": original_result["normalized_restart_resume"],
        "chat_backend_normalized_restart_resume": chat_result["normalized_restart_resume"],
        "original_normalized_replayed_approval_after_restart": original_result[
            "normalized_replayed_approval_request_after_restart"
        ],
        "chat_backend_normalized_replayed_approval_after_restart": chat_result[
            "normalized_replayed_approval_request_after_restart"
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
            "approval-flow crash during durable write boundaries",
            "complete global Codex data-fidelity report",
        ],
        "all_scenarios_ok": False,
    }
    summary["all_scenarios_ok"] = all(
        [
            summary["original_seed_turn_exit_ok"],
            summary["chat_backend_seed_turn_exit_ok"],
            summary["original_command_turn_exit_ok"],
            summary["chat_backend_command_turn_exit_ok"],
            summary["original_process_was_killed"],
            summary["chat_backend_process_was_killed"],
            summary["normalized_initial_approval_request_equal"],
            summary["original_restart_resume_exit_ok"],
            summary["chat_backend_restart_resume_exit_ok"],
            summary["normalized_restart_resume_equal"],
            summary["restarted_replayed_approval_equal"],
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
            summary["command_pending_storage_equivalent"],
            summary["journal_line_count_matches_original"],
        ]
    )

    write_json(
        output_dir / "original/command-approval-crash-pending-resume-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/command-approval-crash-pending-resume-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Command Approval Crash Pending Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with `approval_policy = "untrusted"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, T06
approval reports, existing approval/pending-resume tests, and relevant vendored
Codex approval/persistence source files were read.

## Scope

This smoke covers a shell command turn whose
`item/commandExecution/requestApproval` request is still pending, then kills
the app-server process before any approval response is sent. It starts a fresh
app-server with the same `CODEX_HOME` and compares `thread/resume`,
`thread/read`, `thread/list`, live notifications, and durable storage between
the original backend and the `.chat` backend.

The test intentionally follows original Codex behavior. If the original backend
does not restore an in-memory pending approval after process death, the `.chat`
backend must match that behavior rather than fabricating a stronger durable
approval contract.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-approval-crash-pending-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/command-approval-crash-pending-resume-response.json
```

## Not Yet Proven

This smoke does not prove crash behavior at every durable write boundary, and
it does not replace the complete global Codex data-fidelity report.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
