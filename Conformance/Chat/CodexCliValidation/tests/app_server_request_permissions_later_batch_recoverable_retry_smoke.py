#!/usr/bin/env python3
"""Run request_permissions later-batch recoverable retry smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend completes the existing two-turn request_permissions
scenario as the oracle. The adapted `.chat` backend runs the same two-turn
scenario with a one-shot recoverable failpoint after the later session-grant
shell command `function_call_output` has reached canonical `journal.ndjson` and
`timeline.ndjson`, and before standard projections are rebuilt.

The process must stay alive, complete the second turn, avoid duplicating the
already durable approval or command outputs, rebuild projections, and match the
original backend for the covered fresh app-server read/list/search surface. This
is not a final T06, H05, crash-recovery, or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_package_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    normalize_thread_list_response,
    normalize_thread_response,
    utc_now_iso,
    write_json,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    summarize_chat_packages,
    summarize_original_storage,
)
from app_server_file_change_pending_resume_smoke import (  # noqa: E402
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_start,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
)
from app_server_request_permissions_approval_output_failpoint_smoke import (  # noqa: E402
    chat_journal_signatures,
    invalid_line_count,
    original_rollout_signatures,
    package_contains_approval_output,
    valid_line_count,
)
from app_server_request_permissions_smoke import (  # noqa: E402
    CALL_ID,
    COMMAND_CALL_ID,
    COMMAND_OUTPUT_TEXT,
    FIRST_FINAL_TEXT,
    SECOND_FINAL_TEXT,
    SECOND_USER_TEXT,
    USER_TEXT,
    RequestPermissionsResponsesServer,
    command_items_from_thread_read,
    first_requested_write_path,
    normalize_thread_read_visible,
    run_tree as run_normal_request_permissions_tree,
    summarize_chat_timeline,
    summarize_original_rollouts,
    write_request_permissions_config,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402


RECOVERABLE_FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT"
RECOVERABLE_MARKER_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT_MARKER"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "Exit code: 0"
SEARCH_TERM = "request_permissions approval smoke"

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_later_batch_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_approval_output_recoverable_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_output_recoverable_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_recoverable_append_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def with_recoverable_failpoint_env(marker_path: pathlib.Path) -> dict[str, str | None]:
    marker_path.write_text("fire-once\n")
    old = {
        RECOVERABLE_FAILPOINT_ENV: os.environ.get(RECOVERABLE_FAILPOINT_ENV),
        RECOVERABLE_MARKER_ENV: os.environ.get(RECOVERABLE_MARKER_ENV),
        FAILPOINT_NEEDLE_ENV: os.environ.get(FAILPOINT_NEEDLE_ENV),
    }
    os.environ[RECOVERABLE_FAILPOINT_ENV] = FAILPOINT_NAME
    os.environ[RECOVERABLE_MARKER_ENV] = str(marker_path)
    os.environ[FAILPOINT_NEEDLE_ENV] = FAILPOINT_NEEDLE
    return old


def restore_env(old: dict[str, str | None]) -> None:
    for key, value in old.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


def start_client(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    recoverable_marker: pathlib.Path | None = None,
) -> JsonRpcClient:
    if recoverable_marker is None:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    old = with_recoverable_failpoint_env(recoverable_marker)
    try:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    finally:
        restore_env(old)


def send_request_permissions_first_turn(
    client: JsonRpcClient,
    thread_id: str | None,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": "client-user-request-permissions-later-batch-retry",
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
    turn_start_response = client.receive_until_response(3, timeout_seconds=30)
    permission_request = client.receive_until_method(
        "item/permissions/requestApproval",
        timeout_seconds=30,
    )
    granted_write_path = first_requested_write_path(permission_request)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": permission_request.get("id"),
            "result": {
                "permissions": {
                    "fileSystem": {
                        "write": [granted_write_path],
                    },
                },
                "scope": "session",
                "strictAutoReview": None,
            },
        }
    )
    first_turn_completed_notification = client.receive_until_method(
        "turn/completed",
        timeout_seconds=90,
    )
    return turn_start_response, permission_request, first_turn_completed_notification


def send_completed_turn_start(
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
            ("turn/completed", 90),
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


def send_thread_search_request(
    client: JsonRpcClient,
    request_id: int,
) -> dict[str, Any]:
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


def normalize_request_permissions_search_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    matched_result = next(
        (
            item
            for item in data
            if ((item.get("thread") or {}).get("id") == thread_id)
        ),
        None,
    )
    snippet = (matched_result or {}).get("snippet") or ""
    thread = (matched_result or {}).get("thread") or {}
    return {
        "has_error": "error" in response,
        "result_count": len(data),
        "contains_started_thread": matched_result is not None,
        "snippet_contains_search_term": SEARCH_TERM.lower() in snippet.lower(),
        "thread_preview": thread.get("preview"),
        "thread_status_type": status_type(thread.get("status")),
        "thread_model_provider": thread.get("modelProvider"),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def status_type(value: Any) -> Any:
    if isinstance(value, dict):
        return value.get("type")
    return value


def fresh_read_list_search(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    thread_id: str | None,
) -> dict[str, Any]:
    client = start_client(codex_bin, workspace, codex_home, config_overrides)
    stderr = ""
    try:
        initialize_response = send_initialize(client, 101)
        read_response = send_thread_read(client, 102, thread_id)
        list_response = send_thread_list(client, 103)
        search_response = send_thread_search_request(client, 104)
        process_exit_code_before_close = client.process.poll()
    finally:
        stderr = close_or_collect(client)
    return {
        "initialize_response": initialize_response,
        "thread_read_response": read_response,
        "thread_list_response": list_response,
        "thread_search_response": search_response,
        "normalized_thread_read": normalize_thread_response(read_response, thread_id),
        "normalized_thread_read_visible": normalize_thread_read_visible(read_response),
        "normalized_thread_read_command_items": command_items_from_thread_read(read_response),
        "normalized_thread_list": normalize_thread_list_response(list_response, thread_id),
        "normalized_thread_search": normalize_request_permissions_search_response(
            search_response,
            thread_id,
        ),
        "stderr_tail": stderr[-6000:],
        "process_exit_code_before_close": process_exit_code_before_close,
    }


def chat_package_for(observation: dict[str, Any]) -> pathlib.Path:
    package = observation.get("package")
    if not package:
        raise RuntimeError("expected observed .chat package path")
    return pathlib.Path(package)


def package_contains_first_final(summary: dict[str, Any]) -> bool:
    return any(
        FIRST_FINAL_TEXT in path.read_text()
        for package in summary.get("packages") or []
        for path in [
            pathlib.Path(package["package"]) / "timeline.ndjson",
            pathlib.Path(package["package"]) / "journal.ndjson",
        ]
        if path.exists()
    )


def package_contains_second_final(summary: dict[str, Any]) -> bool:
    return any(
        SECOND_FINAL_TEXT in path.read_text()
        for package in summary.get("packages") or []
        for path in [
            pathlib.Path(package["package"]) / "timeline.ndjson",
            pathlib.Path(package["package"]) / "journal.ndjson",
        ]
        if path.exists()
    )


def package_contains_session_command_output(summary: dict[str, Any]) -> bool:
    return any(
        package.get("timeline_has_command_call")
        and package.get("timeline_has_command_output")
        and package.get("timeline_contains_command_call_id")
        and package.get("timeline_contains_command_output")
        and package.get("journal_has_command_function_call")
        and package.get("journal_has_command_function_call_output")
        and package.get("journal_contains_command_output")
        for package in summary.get("packages") or []
    )


def signature_count_for_call_output(
    signatures: list[dict[str, Any]],
    call_id: str,
) -> int:
    return sum(
        1
        for signature in signatures
        if signature.get("payload_type") == "function_call_output"
        and signature.get("call_id") == call_id
    )


def signature_contains_call(
    signatures: list[dict[str, Any]],
    call_id: str,
) -> bool:
    return any(
        signature.get("payload_type") == "function_call"
        and signature.get("call_id") == call_id
        for signature in signatures
    )


def run_chat_backend_later_batch_recoverable_retry(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    marker_path: pathlib.Path,
) -> dict[str, Any]:
    with RequestPermissionsResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            recoverable_marker=marker_path,
        )
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)
            (
                turn_start_response,
                permission_request,
                first_turn_completed_notification,
            ) = send_request_permissions_first_turn(client, thread_id)
            second_turn_start_response = send_completed_turn_start(
                client,
                4,
                thread_id,
                "client-user-request-permissions-session-command-retry",
                SECOND_USER_TEXT,
            )
            final_thread_read_response = send_thread_read(client, 5, thread_id)
            process_exit_code_before_close = client.process.poll()
        finally:
            stderr = close_or_collect(client)

        marker_consumed = not marker_path.exists()
        pre_fresh_observation = observe_package(chat_root, thread_id, "plain")
        package_path = chat_package_for(pre_fresh_observation)
        pre_fresh_signatures = chat_journal_signatures(package_path)
        pre_fresh_summary = summarize_chat_packages(chat_root)
        pre_fresh_timeline = summarize_chat_timeline(chat_root)

        fresh = fresh_read_list_search(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
        )
        post_fresh_observation = observe_package(chat_root, thread_id, "plain")
        post_fresh_signatures = chat_journal_signatures(package_path)
        post_fresh_summary = summarize_chat_packages(chat_root)
        post_fresh_timeline = summarize_chat_timeline(chat_root)

    return {
        "thread_id": thread_id,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "permission_request": permission_request,
        "first_turn_completed_notification": first_turn_completed_notification,
        "second_turn_start_response": second_turn_start_response,
        "final_thread_read_response": final_thread_read_response,
        "process_exit_code_before_close": process_exit_code_before_close,
        "stderr_tail": stderr[-6000:],
        "marker_consumed": marker_consumed,
        "pre_fresh_observation": pre_fresh_observation,
        "post_fresh_observation": post_fresh_observation,
        "pre_fresh_summary": pre_fresh_summary,
        "post_fresh_summary": post_fresh_summary,
        "pre_fresh_timeline_summary": pre_fresh_timeline,
        "post_fresh_timeline_summary": post_fresh_timeline,
        "pre_fresh_source_signatures": pre_fresh_signatures,
        "post_fresh_source_signatures": post_fresh_signatures,
        "normalized_final_thread_read_visible": normalize_thread_read_visible(
            final_thread_read_response,
        ),
        "normalized_final_thread_read_command_items": command_items_from_thread_read(
            final_thread_read_response,
        ),
        "fresh": fresh,
        "mock_server_summary": mock_server.summary(),
        "workspace_effect": {
            "session_grant_file_exists": (workspace / "session-grant.txt").exists(),
            "session_grant_file_text": (workspace / "session-grant.txt").read_text()
            if (workspace / "session-grant.txt").exists()
            else None,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-request-permissions-later-batch-recoverable-retry-smoke-"
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
    original_result = run_normal_request_permissions_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    original_home = pathlib.Path(original_result["codex_home"])
    original_workspace = pathlib.Path(original_result["workspace"])
    original_thread_id = (
        ((original_result["thread_start_response"].get("result") or {}).get("thread") or {}).get(
            "id"
        )
    )
    original_fresh_result = fresh_read_list_search(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        original_workspace,
        original_home,
        [],
        original_thread_id,
    )

    chat_workspace = run_root / "chat-backend" / "workspace"
    chat_home = run_root / "chat-backend" / "codex-home"
    chat_root = run_root / "chat-backend" / "chat-store"
    marker_path = run_root / "chat-backend" / "recoverable-later-batch.marker"
    for path in [chat_workspace, chat_home, chat_root]:
        path.mkdir(parents=True, exist_ok=True)
    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]
    chat_result = run_chat_backend_later_batch_recoverable_retry(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
        marker_path,
    )

    original_storage = original_result["original_storage_summary"]
    original_rollout_summary = summarize_original_rollouts(original_home)
    original_signatures = original_rollout_signatures(original_home)
    chat_signatures = chat_result["post_fresh_source_signatures"]
    chat_pre_count = valid_line_count(chat_result["pre_fresh_observation"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_fresh_observation"], "timeline")
    post_timeline = chat_result["post_fresh_timeline_summary"]
    fresh_chat = chat_result["fresh"]
    workspace_effect = chat_result["workspace_effect"]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-request-permissions-later-batch-recoverable-retry-smoke",
        "matrix_slice": ["T06", "T01-adjacent", "H05", "H04-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": RECOVERABLE_FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "marker_env": RECOVERABLE_MARKER_ENV,
            "marker_path": str(marker_path),
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": FAILPOINT_NEEDLE,
            "boundary": (
                "return one recoverable append error after the later "
                "session-grant shell command function_call_output reaches "
                "canonical journal/timeline and before projection rebuild"
            ),
        },
        "binary_checks": binary_checks,
        "chat_backend_process_survived_recoverable_error": (
            chat_result["process_exit_code_before_close"] is None
        ),
        "chat_backend_marker_consumed_once": chat_result["marker_consumed"],
        "chat_backend_second_turn_completed_after_retry": (
            "error" not in (chat_result["second_turn_start_response"].get("response") or {})
            and not chat_result["second_turn_start_response"].get("notification_errors")
        ),
        "chat_backend_projections_ok_before_fresh_read": all_projections_repaired(
            chat_result["pre_fresh_observation"],
        ),
        "chat_backend_projections_ok_after_fresh_read": all_projections_repaired(
            chat_result["post_fresh_observation"],
        ),
        "chat_backend_no_invalid_canonical_lines": (
            invalid_line_count(chat_result["pre_fresh_observation"], "timeline") == 0
            and invalid_line_count(chat_result["pre_fresh_observation"], "journal") == 0
            and invalid_line_count(chat_result["post_fresh_observation"], "timeline") == 0
            and invalid_line_count(chat_result["post_fresh_observation"], "journal") == 0
        ),
        "chat_backend_timeline_stable_across_fresh_read": chat_pre_count == chat_post_count,
        "chat_backend_line_count_matches_original": (
            len(chat_signatures) == len(original_signatures)
        ),
        "chat_backend_source_signatures_match_original": (
            chat_signatures == original_signatures
        ),
        "chat_backend_retains_approval_output": package_contains_approval_output(
            post_timeline,
        ),
        "chat_backend_retains_first_final_answer": package_contains_first_final(
            post_timeline,
        ),
        "chat_backend_retains_session_command_call": signature_contains_call(
            chat_signatures,
            COMMAND_CALL_ID,
        ),
        "chat_backend_retains_session_command_output": package_contains_session_command_output(
            post_timeline,
        ),
        "chat_backend_retains_second_final_answer": package_contains_second_final(
            post_timeline,
        ),
        "chat_backend_command_output_not_duplicated": (
            signature_count_for_call_output(chat_signatures, COMMAND_CALL_ID) == 1
        ),
        "chat_backend_approval_output_not_duplicated": (
            signature_count_for_call_output(chat_signatures, CALL_ID) == 1
        ),
        "normalized_final_thread_read_visible_matches_original": (
            chat_result["normalized_final_thread_read_visible"]
            == original_result["normalized_final_thread_read_visible"]
        ),
        "normalized_final_thread_read_command_items_match_original": (
            chat_result["normalized_final_thread_read_command_items"]
            == original_result["normalized_final_thread_read_command_items"]
        ),
        "fresh_normalized_thread_read_visible_matches_original": (
            fresh_chat["normalized_thread_read_visible"]
            == original_fresh_result["normalized_thread_read_visible"]
        ),
        "fresh_normalized_thread_read_command_items_match_original": (
            fresh_chat["normalized_thread_read_command_items"]
            == original_fresh_result["normalized_thread_read_command_items"]
        ),
        "fresh_normalized_thread_list_matches_original": (
            fresh_chat["normalized_thread_list"]
            == original_fresh_result["normalized_thread_list"]
        ),
        "fresh_normalized_thread_search_matches_original": (
            fresh_chat["normalized_thread_search"]
            == original_fresh_result["normalized_thread_search"]
        ),
        "mock_server_summary_matches_original": (
            chat_result["mock_server_summary"] == original_result["mock_server_summary"]
        ),
        "workspace_effect_matches_original": (
            workspace_effect == original_result["workspace_effect"]
        ),
        "chat_backend_workspace_side_effect_exists": (
            workspace_effect["session_grant_file_exists"]
            and COMMAND_OUTPUT_TEXT in (workspace_effect["session_grant_file_text"] or "")
        ),
        "original_line_count": len(original_signatures),
        "chat_backend_line_count": len(chat_signatures),
        "chat_backend_timeline_line_count_before_fresh_read": chat_pre_count,
        "chat_backend_timeline_line_count_after_fresh_read": chat_post_count,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures": chat_signatures,
        "original_rollout_summary": original_rollout_summary,
        "original_storage_summary": original_storage,
        "chat_backend_storage_summary": chat_result["post_fresh_summary"],
        "original_normalized_final_thread_read_visible": original_result[
            "normalized_final_thread_read_visible"
        ],
        "chat_backend_normalized_final_thread_read_visible": chat_result[
            "normalized_final_thread_read_visible"
        ],
        "original_normalized_final_thread_read_command_items": original_result[
            "normalized_final_thread_read_command_items"
        ],
        "chat_backend_normalized_final_thread_read_command_items": chat_result[
            "normalized_final_thread_read_command_items"
        ],
        "original_fresh_normalized_thread_read_visible": original_fresh_result[
            "normalized_thread_read_visible"
        ],
        "chat_backend_fresh_normalized_thread_read_visible": fresh_chat[
            "normalized_thread_read_visible"
        ],
        "original_fresh_normalized_thread_list": original_fresh_result[
            "normalized_thread_list"
        ],
        "chat_backend_fresh_normalized_thread_list": fresh_chat["normalized_thread_list"],
        "original_fresh_normalized_thread_search": original_fresh_result[
            "normalized_thread_search"
        ],
        "chat_backend_fresh_normalized_thread_search": fresh_chat[
            "normalized_thread_search"
        ],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "chat_backend_post_fresh_timeline_summary": post_timeline,
        "not_yet_proven": [
            "process abort after request_permissions second final answer or task completion",
            "broader approval crash variants across network, file-change, freeform apply_patch, and additional-permissions flows",
            "arbitrary real filesystem I/O failures outside this validation failpoint",
            "background compression crash recovery",
            "true process-kill rollback/lifecycle parity",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
        "original": original_result,
        "original_fresh": original_fresh_result,
        "chat_backend": chat_result,
    }
    summary["passed"] = all(
        [
            summary["chat_backend_process_survived_recoverable_error"],
            summary["chat_backend_marker_consumed_once"],
            summary["chat_backend_second_turn_completed_after_retry"],
            summary["chat_backend_projections_ok_before_fresh_read"],
            summary["chat_backend_projections_ok_after_fresh_read"],
            summary["chat_backend_no_invalid_canonical_lines"],
            summary["chat_backend_timeline_stable_across_fresh_read"],
            summary["chat_backend_line_count_matches_original"],
            summary["chat_backend_source_signatures_match_original"],
            summary["chat_backend_retains_approval_output"],
            summary["chat_backend_retains_first_final_answer"],
            summary["chat_backend_retains_session_command_call"],
            summary["chat_backend_retains_session_command_output"],
            summary["chat_backend_retains_second_final_answer"],
            summary["chat_backend_command_output_not_duplicated"],
            summary["chat_backend_approval_output_not_duplicated"],
            summary["normalized_final_thread_read_visible_matches_original"],
            summary["normalized_final_thread_read_command_items_match_original"],
            summary["fresh_normalized_thread_read_visible_matches_original"],
            summary["fresh_normalized_thread_read_command_items_match_original"],
            summary["fresh_normalized_thread_list_matches_original"],
            summary["fresh_normalized_thread_search_matches_original"],
            summary["mock_server_summary_matches_original"],
            summary["workspace_effect_matches_original"],
            summary["chat_backend_workspace_side_effect_exists"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow app-server request_permissions later-batch "
        "recoverable retry slice: after the standalone approval output and "
        "first final answer are durable, the adapted .chat backend survives a "
        "one-shot recoverable append error after the later session-grant shell "
        "command function_call_output becomes canonical and before projection "
        "rebuild, drains that durable prefix without duplicating approval or "
        "command outputs, completes the second turn, rebuilds projections, "
        "retains the second final answer, and matches original visible "
        "read/list/search and mock request behavior for this slice. It is not "
        "final approval crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/request-permissions-normal-response.json",
        original_result,
    )
    write_json(
        output_dir / "original/request-permissions-fresh-response.json",
        original_fresh_result,
    )
    write_json(
        output_dir
        / "chat-backend/request-permissions-later-batch-recoverable-response.json",
        chat_result,
    )

    report = f"""# App-Server Request Permissions Later-Batch Recoverable Retry Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow later-batch T06/H05 boundary. The adapted backend
first persists the standalone `request_permissions` approval output and first
assistant answer, then returns one recoverable append error after the following
session-grant shell command `function_call_output` is synced to
`journal.ndjson` and `timeline.ndjson`, but before projection rebuild.

The adapted backend uses:

```text
{RECOVERABLE_FAILPOINT_ENV}={FAILPOINT_NAME}
{RECOVERABLE_MARKER_ENV}={marker_path}
{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}
```

## Result

- `.chat` backend process survived recoverable error: `{summary['chat_backend_process_survived_recoverable_error']}`
- one-shot marker was consumed: `{summary['chat_backend_marker_consumed_once']}`
- second turn completed after retry: `{summary['chat_backend_second_turn_completed_after_retry']}`
- projections valid before fresh read: `{summary['chat_backend_projections_ok_before_fresh_read']}`
- projections valid after fresh read: `{summary['chat_backend_projections_ok_after_fresh_read']}`
- no invalid canonical lines: `{summary['chat_backend_no_invalid_canonical_lines']}`
- timeline count stable across fresh read: `{summary['chat_backend_timeline_stable_across_fresh_read']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- line count matches original: `{summary['chat_backend_line_count_matches_original']}` (`{len(chat_signatures)}` == `{len(original_signatures)}`)
- source signatures match original: `{summary['chat_backend_source_signatures_match_original']}`
- approval output retained/not duplicated: `{summary['chat_backend_retains_approval_output']}` / `{summary['chat_backend_approval_output_not_duplicated']}`
- first final answer retained: `{summary['chat_backend_retains_first_final_answer']}`
- session command call/output retained: `{summary['chat_backend_retains_session_command_call']}` / `{summary['chat_backend_retains_session_command_output']}`
- session command output not duplicated: `{summary['chat_backend_command_output_not_duplicated']}`
- second final answer retained: `{summary['chat_backend_retains_second_final_answer']}`
- live final thread/read visible state matches original: `{summary['normalized_final_thread_read_visible_matches_original']}`
- live final command item projection matches original: `{summary['normalized_final_thread_read_command_items_match_original']}`
- fresh thread/read visible state matches original: `{summary['fresh_normalized_thread_read_visible_matches_original']}`
- fresh command item projection matches original: `{summary['fresh_normalized_thread_read_command_items_match_original']}`
- fresh thread/list matches original: `{summary['fresh_normalized_thread_list_matches_original']}`
- fresh thread/search matches original: `{summary['fresh_normalized_thread_search_matches_original']}`
- mock model request summary matches original: `{summary['mock_server_summary_matches_original']}`
- workspace side effect matches original: `{summary['workspace_effect_matches_original']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-normal-response.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-fresh-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-later-batch-recoverable-response.json
```

## Not Yet Proven

This smoke does not prove process abort after the second final answer or task
completion, broader approval crash variants, arbitrary real filesystem I/O
failures outside validation failpoints, background compression crash recovery,
true process-kill rollback/lifecycle parity, final crash recovery parity, or
final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
