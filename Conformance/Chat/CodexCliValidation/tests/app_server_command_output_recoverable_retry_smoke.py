#!/usr/bin/env python3
"""Run command-output recoverable retry smoke for the `.chat` backend.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The adapted `.chat` backend runs with a one-shot recoverable failpoint
after a selected shell command `function_call_output` is synced to canonical
`journal.ndjson` and `timeline.ndjson`, but before standard projections are
rebuilt.

The process must stay alive, avoid duplicating the already durable command
output, finish the turn, rebuild projections, and match the original backend
oracle for read/list/search and request-context behavior. This is not a final
command, H05, crash-recovery, or user-indistinguishability claim.
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
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_search,
    send_thread_start,
    send_turn_start,
)
from app_server_command_execution_smoke import (  # noqa: E402
    FAIL_CALL_ID,
    FINAL_TEXT,
    SUCCESS_CALL_ID,
    USER_TEXT,
    SequenceResponsesServer,
)
from app_server_command_output_failpoint_crash_smoke import (  # noqa: E402
    TARGETS as COMMAND_OUTPUT_TARGETS,
    any_package,
    chat_journal_signatures,
    original_rollout_signatures,
    signatures_contain_function_call,
    signatures_contain_function_call_output,
    summarize_command_crash_timeline,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402


RECOVERABLE_FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT"
RECOVERABLE_MARKER_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT_MARKER"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
DEFAULT_TARGET = "failing-command-output"
TARGETS = {
    key: {
        **value,
        "scope": value["scope"].replace(
            "failpoint-crash-smoke",
            "recoverable-retry-smoke",
        ),
        "output_prefix": value["output_prefix"].replace(
            "failpoint-crash-smoke",
            "recoverable-retry-smoke",
        ),
    }
    for key, value in COMMAND_OUTPUT_TARGETS.items()
}

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_execution_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_output_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_recoverable_append_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def with_recoverable_failpoint_env(
    marker_path: pathlib.Path,
    failpoint_needle: str,
) -> dict[str, str | None]:
    marker_path.write_text("fire-once\n")
    old = {
        RECOVERABLE_FAILPOINT_ENV: os.environ.get(RECOVERABLE_FAILPOINT_ENV),
        RECOVERABLE_MARKER_ENV: os.environ.get(RECOVERABLE_MARKER_ENV),
        FAILPOINT_NEEDLE_ENV: os.environ.get(FAILPOINT_NEEDLE_ENV),
    }
    os.environ[RECOVERABLE_FAILPOINT_ENV] = FAILPOINT_NAME
    os.environ[RECOVERABLE_MARKER_ENV] = str(marker_path)
    os.environ[FAILPOINT_NEEDLE_ENV] = failpoint_needle
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
    failpoint_needle: str = TARGETS[DEFAULT_TARGET]["needle"],
) -> JsonRpcClient:
    if recoverable_marker is None:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    old = with_recoverable_failpoint_env(recoverable_marker, failpoint_needle)
    try:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    finally:
        restore_env(old)


def valid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("valid_line_count") or 0)


def invalid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("invalid_line_count") or 0)


def chat_package_for(observation: dict[str, Any]) -> pathlib.Path:
    package = observation.get("package")
    if not package:
        raise RuntimeError("expected observed .chat package path")
    return pathlib.Path(package)


def without_loaded_status(value: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(value)
    normalized.pop("thread_status_type", None)
    normalized.pop("listed_thread_status_type", None)
    return normalized


def package_has_journal_final_text(summary: dict[str, Any]) -> bool:
    return any_package(summary, "journal_contains_final_text")


def package_has_timeline_final_text(summary: dict[str, Any]) -> bool:
    return any_package(summary, "timeline_contains_final_text")


def package_has_timeline_task_complete(summary: dict[str, Any]) -> bool:
    return any_package(summary, "timeline_contains_task_complete")


def run_chat_backend_command_output_recoverable_retry(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    marker_path: pathlib.Path,
    failpoint_needle: str,
) -> dict[str, Any]:
    with SequenceResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            recoverable_marker=marker_path,
            failpoint_needle=failpoint_needle,
        )
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-command-output-recoverable",
                USER_TEXT,
            )
            first_process_exit_code_before_close = first_client.process.poll()
        finally:
            first_stderr = close_or_collect(first_client)

        marker_consumed = not marker_path.exists()
        pre_fresh_summary = summarize_chat_packages(chat_root)
        pre_fresh_observation = observe_package(chat_root, thread_id, "plain")
        package_path = chat_package_for(pre_fresh_observation)
        pre_fresh_signatures = chat_journal_signatures(package_path)
        pre_fresh_timeline = summarize_command_crash_timeline(chat_root)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_response = send_thread_read(second_client, 102, thread_id)
            list_response = send_thread_list(second_client, 103)
            search_response = send_thread_search(second_client, 104)
            post_fresh_observation = observe_package(chat_root, thread_id, "plain")
            post_fresh_summary = summarize_chat_packages(chat_root)
            post_fresh_signatures = chat_journal_signatures(package_path)
            post_fresh_timeline = summarize_command_crash_timeline(chat_root)
            second_process_exit_code_before_close = second_client.process.poll()
        finally:
            second_stderr = close_or_collect(second_client)

    return {
        "thread_id": thread_id,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "first_process_exit_code_before_close": first_process_exit_code_before_close,
        "second_initialize_response": second_initialize_response,
        "thread_read_response": read_response,
        "thread_list_response": list_response,
        "thread_search_response": search_response,
        "normalized_thread_read": normalize_thread_response(read_response, thread_id),
        "normalized_thread_list": normalize_thread_list_response(list_response, thread_id),
        "normalized_thread_search": normalize_thread_search_response(
            search_response,
            thread_id,
        ),
        "pre_fresh_summary": pre_fresh_summary,
        "post_fresh_summary": post_fresh_summary,
        "pre_fresh_observation": pre_fresh_observation,
        "post_fresh_observation": post_fresh_observation,
        "pre_fresh_source_signatures": pre_fresh_signatures,
        "post_fresh_source_signatures": post_fresh_signatures,
        "pre_fresh_timeline_summary": pre_fresh_timeline,
        "post_fresh_timeline_summary": post_fresh_timeline,
        "marker_consumed": marker_consumed,
        "marker_path": str(marker_path),
        "mock_server_summary": mock_server.summary(),
        "first_stderr_tail": first_stderr[-6000:],
        "second_stderr_tail": second_stderr[-6000:],
        "second_process_exit_code_before_close": second_process_exit_code_before_close,
    }


def run_original_command_output_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with SequenceResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = start_client(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)
            turn_start_response = send_turn_start(
                client,
                3,
                thread_id,
                "client-user-command-output-recoverable-original",
                USER_TEXT,
            )
            read_response = send_thread_read(client, 4, thread_id)
            list_response = send_thread_list(client, 5)
            search_response = send_thread_search(client, 6)
            process_exit_code_before_close = client.process.poll()
        finally:
            stderr = close_or_collect(client)

    return {
        "thread_id": thread_id,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "thread_read_response": read_response,
        "thread_list_response": list_response,
        "thread_search_response": search_response,
        "normalized_thread_read": normalize_thread_response(read_response, thread_id),
        "normalized_thread_list": normalize_thread_list_response(list_response, thread_id),
        "normalized_thread_search": normalize_thread_search_response(
            search_response,
            thread_id,
        ),
        "mock_server_summary": mock_server.summary(),
        "stderr_tail": stderr[-6000:],
        "process_exit_code_before_close": process_exit_code_before_close,
    }


def run_original_command_output_fresh_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with SequenceResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-command-output-recoverable-original-fresh",
                USER_TEXT,
            )
            first_process_exit_code_before_close = first_client.process.poll()
        finally:
            first_stderr = close_or_collect(first_client)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_response = send_thread_read(second_client, 102, thread_id)
            list_response = send_thread_list(second_client, 103)
            search_response = send_thread_search(second_client, 104)
            second_process_exit_code_before_close = second_client.process.poll()
        finally:
            second_stderr = close_or_collect(second_client)

    return {
        "thread_id": thread_id,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "second_initialize_response": second_initialize_response,
        "thread_read_response": read_response,
        "thread_list_response": list_response,
        "thread_search_response": search_response,
        "normalized_thread_read": normalize_thread_response(read_response, thread_id),
        "normalized_thread_list": normalize_thread_list_response(list_response, thread_id),
        "normalized_thread_search": normalize_thread_search_response(
            search_response,
            thread_id,
        ),
        "mock_server_summary": mock_server.summary(),
        "first_stderr_tail": first_stderr[-6000:],
        "second_stderr_tail": second_stderr[-6000:],
        "first_process_exit_code_before_close": first_process_exit_code_before_close,
        "second_process_exit_code_before_close": second_process_exit_code_before_close,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--target",
        choices=sorted(TARGETS),
        default=DEFAULT_TARGET,
        help="command output boundary to recover after",
    )
    parser.add_argument("--output-dir", type=pathlib.Path, default=None)
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()
    target = TARGETS[args.target]

    output_dir = (
        args.output_dir
        or validation_results_root()
        / (target["output_prefix"] + "-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    ).resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

    run_root = output_dir / "run"
    original_workspace = run_root / "original" / "workspace"
    original_home = run_root / "original" / "codex-home"
    chat_workspace = run_root / "chat-backend" / "workspace"
    chat_home = run_root / "chat-backend" / "codex-home"
    chat_root = run_root / "chat-backend" / "chat-store"
    marker_path = run_root / "chat-backend" / "recoverable-failpoint.marker"
    for path in [original_workspace, original_home, chat_workspace, chat_home, chat_root]:
        path.mkdir(parents=True, exist_ok=True)
    marker_path.parent.mkdir(parents=True, exist_ok=True)
    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]
    original_result = run_original_command_output_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        original_workspace,
        original_home,
        [],
    )
    original_fresh_workspace = run_root / "original-fresh" / "workspace"
    original_fresh_home = run_root / "original-fresh" / "codex-home"
    original_fresh_workspace.mkdir(parents=True, exist_ok=True)
    original_fresh_home.mkdir(parents=True, exist_ok=True)
    original_fresh_result = run_original_command_output_fresh_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        original_fresh_workspace,
        original_fresh_home,
        [],
    )
    chat_result = run_chat_backend_command_output_recoverable_retry(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
        marker_path,
        target["needle"],
    )

    original_storage = summarize_original_storage(original_home)
    original_signatures = original_rollout_signatures(original_home)
    chat_signatures = chat_result["post_fresh_source_signatures"]
    chat_pre_count = valid_line_count(chat_result["pre_fresh_observation"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_fresh_observation"], "timeline")
    post_timeline = chat_result["post_fresh_timeline_summary"]

    retains_success_command_call = any_package(
        post_timeline,
        "timeline_has_success_command_call",
    ) and signatures_contain_function_call(chat_signatures, SUCCESS_CALL_ID)
    retains_success_command_output = any_package(
        post_timeline,
        "timeline_has_success_command_output",
    ) and signatures_contain_function_call_output(
        chat_signatures,
        SUCCESS_CALL_ID,
        "contains_success_stdout",
        "contains_success_stderr",
    )
    retains_failure_command_call = any_package(
        post_timeline,
        "timeline_has_failure_command_call",
    ) and signatures_contain_function_call(chat_signatures, FAIL_CALL_ID)
    retains_failure_command_output = (
        any_package(post_timeline, "timeline_has_failure_command_output")
        and signatures_contain_function_call_output(
            chat_signatures,
            FAIL_CALL_ID,
            "contains_failure_stdout",
            "contains_failure_stderr",
        )
    )
    read_response_contains_final_answer = FINAL_TEXT in json.dumps(
        chat_result["thread_read_response"],
        ensure_ascii=False,
    )
    read_matches_fresh_original = (
        chat_result["normalized_thread_read"]
        == original_fresh_result["normalized_thread_read"]
    )
    list_matches_fresh_original = (
        chat_result["normalized_thread_list"]
        == original_fresh_result["normalized_thread_list"]
    )
    search_matches_fresh_original = (
        chat_result["normalized_thread_search"]
        == original_fresh_result["normalized_thread_search"]
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": target["scope"],
        "matrix_slice": ["T01", "T02", "T03-adjacent", "H05"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": RECOVERABLE_FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "marker_env": RECOVERABLE_MARKER_ENV,
            "marker_path": str(marker_path),
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": target["needle"],
            "target": args.target,
            "boundary": (
                "return one recoverable append error after "
                f"{target['retained_output_label']} reaches canonical "
                "journal/timeline and before projection rebuild"
            ),
        },
        "binary_checks": binary_checks,
        "chat_backend_process_survived_recoverable_error": (
            chat_result["first_process_exit_code_before_close"] is None
        ),
        "chat_backend_marker_consumed_once": chat_result["marker_consumed"],
        "chat_backend_turn_completed_after_retry": (
            "error" not in (chat_result["turn_start_response"].get("response") or {})
            and not chat_result["turn_start_response"].get("notification_errors")
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
        "normalized_thread_read_matches_fresh_original": read_matches_fresh_original,
        "normalized_thread_list_matches_fresh_original": list_matches_fresh_original,
        "normalized_thread_search_matches_fresh_original": search_matches_fresh_original,
        "mock_model_request_summary_matches_original": (
            chat_result["mock_server_summary"] == original_result["mock_server_summary"]
        ),
        "loaded_status_lifecycle_comparison": {
            "original_thread_read": original_result["normalized_thread_read"].get(
                "thread_status_type"
            ),
            "fresh_original_thread_read": original_fresh_result[
                "normalized_thread_read"
            ].get("thread_status_type"),
            "chat_backend_thread_read": chat_result["normalized_thread_read"].get(
                "thread_status_type"
            ),
            "original_thread_list": original_result["normalized_thread_list"].get(
                "listed_thread_status_type"
            ),
            "fresh_original_thread_list": original_fresh_result[
                "normalized_thread_list"
            ].get("listed_thread_status_type"),
            "chat_backend_thread_list": chat_result["normalized_thread_list"].get(
                "listed_thread_status_type"
            ),
            "interpretation": (
                "Live original status remains idle because that oracle reads "
                "inside the still-loaded app-server process. Fresh original and "
                "fresh .chat reads both reopen persisted storage and should "
                "surface notLoaded. Fresh-vs-fresh equality is the parity check "
                "for this durable read/list/search slice."
            ),
        },
        "chat_backend_retains_success_command_call": retains_success_command_call,
        "chat_backend_retains_success_command_output": retains_success_command_output,
        "chat_backend_retains_failure_command_call": retains_failure_command_call,
        "chat_backend_retains_failure_command_output": retains_failure_command_output,
        "chat_backend_retains_final_answer_in_journal": package_has_journal_final_text(
            post_timeline,
        ),
        "chat_backend_retains_final_answer_in_timeline": package_has_timeline_final_text(
            post_timeline,
        ),
        "chat_backend_retains_task_complete_in_timeline": package_has_timeline_task_complete(
            post_timeline,
        ),
        "chat_backend_read_shows_final_answer": read_response_contains_final_answer,
        "original_line_count": len(original_signatures),
        "chat_backend_line_count": len(chat_signatures),
        "chat_backend_timeline_line_count_before_fresh_read": chat_pre_count,
        "chat_backend_timeline_line_count_after_fresh_read": chat_post_count,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures": chat_signatures,
        "original_normalized_thread_read": original_result["normalized_thread_read"],
        "fresh_original_normalized_thread_read": original_fresh_result[
            "normalized_thread_read"
        ],
        "chat_backend_normalized_thread_read": chat_result["normalized_thread_read"],
        "original_normalized_thread_list": original_result["normalized_thread_list"],
        "fresh_original_normalized_thread_list": original_fresh_result[
            "normalized_thread_list"
        ],
        "chat_backend_normalized_thread_list": chat_result["normalized_thread_list"],
        "original_normalized_thread_search": original_result["normalized_thread_search"],
        "fresh_original_normalized_thread_search": original_fresh_result[
            "normalized_thread_search"
        ],
        "chat_backend_normalized_thread_search": chat_result["normalized_thread_search"],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "fresh_original_mock_server_summary": original_fresh_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_storage_summary": original_storage,
        "chat_backend_storage_summary": chat_result["post_fresh_summary"],
        "chat_backend_pre_fresh_timeline_summary": chat_result[
            "pre_fresh_timeline_summary"
        ],
        "chat_backend_post_fresh_timeline_summary": post_timeline,
        "not_yet_proven": target["not_yet_proven"],
        "original": original_result,
        "fresh_original": original_fresh_result,
        "chat_backend": chat_result,
    }
    summary["passed"] = all(
        [
            summary["chat_backend_process_survived_recoverable_error"],
            summary["chat_backend_marker_consumed_once"],
            summary["chat_backend_turn_completed_after_retry"],
            summary["chat_backend_projections_ok_before_fresh_read"],
            summary["chat_backend_projections_ok_after_fresh_read"],
            summary["chat_backend_no_invalid_canonical_lines"],
            summary["chat_backend_timeline_stable_across_fresh_read"],
            summary["chat_backend_line_count_matches_original"],
            summary["chat_backend_source_signatures_match_original"],
            summary["normalized_thread_read_matches_fresh_original"],
            summary["normalized_thread_list_matches_fresh_original"],
            summary["normalized_thread_search_matches_fresh_original"],
            summary["mock_model_request_summary_matches_original"],
            summary["chat_backend_retains_success_command_call"],
            summary["chat_backend_retains_success_command_output"],
            summary["chat_backend_retains_failure_command_call"],
            summary["chat_backend_retains_failure_command_output"],
            summary["chat_backend_retains_final_answer_in_journal"],
            summary["chat_backend_retains_final_answer_in_timeline"],
            (
                summary["chat_backend_retains_task_complete_in_timeline"]
                if target["retains_task_complete"]
                else True
            ),
            summary["chat_backend_read_shows_final_answer"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow command-output recoverable retry boundary: the "
        "adapted .chat backend survives a one-shot recoverable append error "
        f"after {target['retained_output_label']} is canonical and before "
        "projection rebuild, drains the durable prefix without duplication, "
"finishes the command turn, rebuilds projections, preserves both "
"success and failure command_call/command_output events plus the final "
        "answer, and matches fresh original durable read/list/search behavior "
        "plus mock request behavior for this slice. It records live-vs-fresh "
        "loaded-status lifecycle differences separately and is not full command "
        "crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/command-execution-normal-response.json", original_result)
    write_json(
        output_dir / "original/command-execution-fresh-response.json",
        original_fresh_result,
    )
    write_json(
        output_dir / "chat-backend/command-output-recoverable-response.json",
        chat_result,
    )

    report = f"""# App-Server Command Output Recoverable Retry Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow command-execution recoverable retry boundary. The
adapted backend returns one recoverable append error after
{target['retained_output_label']} reaches canonical `journal.ndjson` and
`timeline.ndjson`, but before projection rebuild.

The adapted backend uses:

```text
{RECOVERABLE_FAILPOINT_ENV}={FAILPOINT_NAME}
{RECOVERABLE_MARKER_ENV}={marker_path}
{FAILPOINT_NEEDLE_ENV}={target['needle']}
```

## Result

- `.chat` backend process survived recoverable error: `{summary['chat_backend_process_survived_recoverable_error']}`
- one-shot marker was consumed: `{summary['chat_backend_marker_consumed_once']}`
- turn completed after retry: `{summary['chat_backend_turn_completed_after_retry']}`
- projections valid before fresh read: `{summary['chat_backend_projections_ok_before_fresh_read']}`
- projections valid after fresh read: `{summary['chat_backend_projections_ok_after_fresh_read']}`
- no invalid canonical lines: `{summary['chat_backend_no_invalid_canonical_lines']}`
- timeline count stable across fresh read: `{summary['chat_backend_timeline_stable_across_fresh_read']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- line count matches original: `{summary['chat_backend_line_count_matches_original']}` (`{len(chat_signatures)}` == `{len(original_signatures)}`)
- source signatures match original: `{summary['chat_backend_source_signatures_match_original']}`
- normalized thread/read matches fresh original: `{summary['normalized_thread_read_matches_fresh_original']}`
- normalized thread/list matches fresh original: `{summary['normalized_thread_list_matches_fresh_original']}`
- normalized thread/search matches fresh original: `{summary['normalized_thread_search_matches_fresh_original']}`
- mock model request summary matches original: `{summary['mock_model_request_summary_matches_original']}`
- success command call/output retained: `{summary['chat_backend_retains_success_command_call']}` / `{summary['chat_backend_retains_success_command_output']}`
- failing command call/output retained: `{summary['chat_backend_retains_failure_command_call']}` / `{summary['chat_backend_retains_failure_command_output']}`
- final assistant answer retained in journal: `{summary['chat_backend_retains_final_answer_in_journal']}`
- final assistant answer retained in timeline: `{summary['chat_backend_retains_final_answer_in_timeline']}`
- task_complete retained in timeline: `{summary['chat_backend_retains_task_complete_in_timeline']}`
- final assistant answer visible in fresh read: `{summary['chat_backend_read_shows_final_answer']}`

Loaded status difference is recorded, not hidden:

```json
{json.dumps(summary['loaded_status_lifecycle_comparison'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-execution-normal-response.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-execution-fresh-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/command-output-recoverable-response.json
```

## Not Yet Proven

This smoke does not prove {", ".join(summary['not_yet_proven'])}.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
