#!/usr/bin/env python3
"""Run command-output projection-boundary process-abort smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend completes the existing command-execution smoke as
the oracle. The adapted `.chat` backend runs with a validation failpoint that
aborts after the selected shell command `function_call_output` is synced to
canonical `journal.ndjson` and `timeline.ndjson`, but before standard
projections are rebuilt.

This proves only a narrow command-execution crash boundary. It is not a final
T01/T02/T03, H04/H05, crash-recovery, or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import time
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
    FINAL_TEXT,
    FAIL_CALL_ID,
    SUCCESS_CALL_ID,
    USER_TEXT,
    SequenceResponsesServer,
    run_tree as run_normal_command_tree,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
    projection_was_stale_before_repair,
    wait_for_process_exit,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
DEFAULT_TARGET = "first-command-output"
TARGETS = {
    "first-command-output": {
        "scope": "app-server-command-output-failpoint-crash-smoke",
        "output_prefix": "app-server-command-output-failpoint-crash-smoke",
        "needle": "function_call_output",
        "boundary": (
            "after the first shell command function_call_output is synced "
            "to journal/timeline and before projection rebuild"
        ),
        "retains_failure_output": False,
        "retains_final_answer": False,
        "retains_task_complete": False,
        "prefix_kind": "strict",
        "retained_output_label": "the first shell command output",
        "unwritten_suffix_label": "the later failing command or final answer",
        "not_yet_proven": [
            "process abort after the later failing command output",
            "process abort after final assistant answer but before task_complete",
            "recoverable I/O failure during command output append",
            "CLI/TUI command-output process-kill parity",
            "arbitrary real filesystem I/O failures outside validation failpoints",
            "final command crash recovery parity",
            "final user-indistinguishability",
        ],
    },
    "failing-command-output": {
        "scope": "app-server-command-failing-output-failpoint-crash-smoke",
        "output_prefix": "app-server-command-failing-output-failpoint-crash-smoke",
        "needle": "Exit code: 7",
        "boundary": (
            "after the later failing shell command function_call_output is "
            "synced to journal/timeline and before projection rebuild"
        ),
        "retains_failure_output": True,
        "retains_final_answer": False,
        "retains_task_complete": False,
        "prefix_kind": "strict",
        "retained_output_label": "the success and failing command outputs",
        "unwritten_suffix_label": "the final assistant answer",
        "not_yet_proven": [
            "process abort after final assistant answer but before task_complete",
            "recoverable I/O failure during command output append",
            "CLI/TUI command-output process-kill parity",
            "arbitrary real filesystem I/O failures outside validation failpoints",
            "final command crash recovery parity",
            "final user-indistinguishability",
        ],
    },
    "task-complete": {
        "scope": "app-server-command-task-complete-failpoint-crash-smoke",
        "output_prefix": "app-server-command-task-complete-failpoint-crash-smoke",
        "needle": "task_complete",
        "boundary": (
            "after the completed command turn, final assistant answer, and "
            "task_complete event are synced to journal/timeline and before "
            "projection rebuild"
        ),
        "retains_failure_output": True,
        "retains_final_answer": True,
        "retains_task_complete": True,
        "prefix_kind": "complete",
        "retained_output_label": (
            "the completed command turn through final assistant answer and task_complete"
        ),
        "unwritten_suffix_label": "projection cache updates or duplicate command events",
        "not_yet_proven": [
            "CLI/TUI command-output process-kill parity",
            "arbitrary real filesystem I/O failures outside validation failpoints",
            "final command crash recovery parity",
            "final user-indistinguishability",
        ],
    },
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
    "Conformance/Chat/CodexCliValidation/tests/app_server_h04_projection_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_pending_write_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def with_failpoint_env(failpoint_needle: str) -> dict[str, str | None]:
    old = {
        FAILPOINT_ENV: os.environ.get(FAILPOINT_ENV),
        FAILPOINT_NEEDLE_ENV: os.environ.get(FAILPOINT_NEEDLE_ENV),
    }
    os.environ[FAILPOINT_ENV] = FAILPOINT_NAME
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
    failpoint: bool = False,
    failpoint_needle: str = TARGETS[DEFAULT_TARGET]["needle"],
) -> JsonRpcClient:
    if not failpoint:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    old = with_failpoint_env(failpoint_needle)
    try:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    finally:
        restore_env(old)


def serialized_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def rollout_payload_signature(line: dict[str, Any]) -> dict[str, Any]:
    payload = line.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    serialized_payload = serialized_json(payload)
    return {
        "type": line.get("type"),
        "payload_type": payload.get("type"),
        "role": payload.get("role"),
        "name": payload.get("name"),
        "call_id": payload.get("call_id"),
        "contains_success_call_id": SUCCESS_CALL_ID in serialized_payload,
        "contains_success_stdout": "CMD_OK_STDOUT" in serialized_payload,
        "contains_success_stderr": "CMD_OK_STDERR" in serialized_payload,
        "contains_failure_call_id": FAIL_CALL_ID in serialized_payload,
        "contains_failure_stdout": "CMD_FAIL_STDOUT" in serialized_payload,
        "contains_failure_stderr": "CMD_FAIL_STDERR" in serialized_payload,
        "contains_final_text": FINAL_TEXT in serialized_payload,
    }


def original_rollout_signatures(codex_home: pathlib.Path) -> list[dict[str, Any]]:
    rollout_paths = sorted(codex_home.rglob("*.jsonl"))
    if not rollout_paths:
        return []
    return [rollout_payload_signature(line) for line in read_json_lines(rollout_paths[0])]


def chat_journal_signatures(package_path: pathlib.Path) -> list[dict[str, Any]]:
    signatures = []
    for line in read_json_lines(package_path / "journal.ndjson"):
        source_transport = line.get("source_transport") or {}
        payload = source_transport.get("payload") or {}
        signatures.append(rollout_payload_signature(payload))
    return signatures


def valid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("valid_line_count") or 0)


def invalid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("invalid_line_count") or 0)


def chat_package_for(observation: dict[str, Any]) -> pathlib.Path:
    package = observation.get("package")
    if not package:
        raise RuntimeError("expected observed .chat package path")
    return pathlib.Path(package)


def thread_id_from_start_response(response: dict[str, Any]) -> str | None:
    return (((response.get("result") or {}).get("thread") or {}).get("id"))


def without_loaded_status(value: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(value)
    normalized.pop("thread_status_type", None)
    normalized.pop("listed_thread_status_type", None)
    return normalized


def summarize_command_crash_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = [
            ((line.get("source_transport") or {}).get("payload") or {})
            for line in journal_lines
        ]
        serialized_timeline = serialized_json(timeline_lines)
        serialized_journal = serialized_json(journal_payloads)
        command_events = [
            line for line in timeline_lines if str(line.get("type")).startswith("command")
        ]
        success_command_calls = [
            line
            for line in command_events
            if line.get("type") == "command_call"
            and ((line.get("body") or {}).get("call_id")) == SUCCESS_CALL_ID
        ]
        success_command_outputs = [
            line
            for line in command_events
            if line.get("type") == "command_output"
            and ((line.get("body") or {}).get("call_id")) == SUCCESS_CALL_ID
        ]
        failure_command_calls = [
            line
            for line in command_events
            if line.get("type") == "command_call"
            and ((line.get("body") or {}).get("call_id")) == FAIL_CALL_ID
        ]
        failure_command_outputs = [
            line
            for line in command_events
            if line.get("type") == "command_output"
            and ((line.get("body") or {}).get("call_id")) == FAIL_CALL_ID
        ]
        packages.append(
            {
                "package": str(package),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "command_event_types": [line.get("type") for line in command_events],
                "command_call_ids": [
                    ((line.get("body") or {}).get("call_id")) for line in command_events
                ],
                "timeline_has_command_call": any(
                    line.get("type") == "command_call" for line in timeline_lines
                ),
                "timeline_has_command_output": any(
                    line.get("type") == "command_output" for line in timeline_lines
                ),
                "timeline_has_success_command_call": bool(success_command_calls),
                "timeline_has_success_command_output": bool(success_command_outputs),
                "timeline_has_failure_command_call": bool(failure_command_calls),
                "timeline_has_failure_command_output": bool(failure_command_outputs),
                "timeline_contains_success_call_id": SUCCESS_CALL_ID in serialized_timeline,
                "timeline_contains_success_stdout": "CMD_OK_STDOUT" in serialized_timeline,
                "timeline_contains_success_stderr": "CMD_OK_STDERR" in serialized_timeline,
                "timeline_contains_failure_call_id": FAIL_CALL_ID in serialized_timeline,
                "timeline_contains_failure_stdout": "CMD_FAIL_STDOUT" in serialized_timeline,
                "timeline_contains_failure_stderr": "CMD_FAIL_STDERR" in serialized_timeline,
                "timeline_contains_final_text": FINAL_TEXT in serialized_timeline,
                "timeline_contains_task_complete": "task_complete" in serialized_timeline,
                "journal_source_response_types": [
                    payload.get("type") for payload in journal_payloads
                ],
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
                "journal_contains_success_call_id": SUCCESS_CALL_ID in serialized_journal,
                "journal_contains_success_stdout": "CMD_OK_STDOUT" in serialized_journal,
                "journal_contains_success_stderr": "CMD_OK_STDERR" in serialized_journal,
                "journal_contains_failure_call_id": FAIL_CALL_ID in serialized_journal,
                "journal_contains_failure_stdout": "CMD_FAIL_STDOUT" in serialized_journal,
                "journal_contains_failure_stderr": "CMD_FAIL_STDERR" in serialized_journal,
                "journal_contains_final_text": FINAL_TEXT in serialized_journal,
                "journal_contains_task_complete": "task_complete" in serialized_journal,
            }
        )
    return {"package_count": len(packages), "packages": packages}


def any_package(summary: dict[str, Any], key: str) -> bool:
    return any(bool(package.get(key)) for package in summary.get("packages") or [])


def signatures_contain_function_call(signatures: list[dict[str, Any]], call_id: str) -> bool:
    return any(
        signature.get("payload_type") == "function_call"
        and signature.get("call_id") == call_id
        for signature in signatures
    )


def signatures_contain_function_call_output(
    signatures: list[dict[str, Any]],
    call_id: str,
    stdout_key: str,
    stderr_key: str,
) -> bool:
    return any(
        signature.get("payload_type") == "function_call_output"
        and signature.get("call_id") == call_id
        and signature.get(stdout_key)
        and signature.get(stderr_key)
        for signature in signatures
    )


def run_chat_backend_command_output_crash(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    failpoint_needle: str,
) -> dict[str, Any]:
    with SequenceResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=True,
            failpoint_needle=failpoint_needle,
        )
        first_stderr = ""
        turn_start_response: dict[str, Any] | None = None
        turn_start_error: str | None = None
        thread_id: str | None = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            try:
                turn_start_response = send_turn_start(
                    first_client,
                    3,
                    thread_id,
                    "client-user-command-output-crash",
                    USER_TEXT,
                )
            except Exception as exc:  # process may abort before the turn response returns
                turn_start_error = repr(exc)
            crash_exit_code = wait_for_process_exit(first_client, timeout_seconds=60)
        finally:
            first_stderr = close_or_collect(first_client)

        pre_repair = observe_package(chat_root, thread_id, "plain")
        package_path = chat_package_for(pre_repair)
        pre_repair_signatures = chat_journal_signatures(package_path)
        pre_repair_timeline = summarize_command_crash_timeline(chat_root)
        pre_repair_summary = summarize_chat_packages(chat_root)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_response = send_thread_read(second_client, 102, thread_id)
            list_response = send_thread_list(second_client, 103)
            search_response = send_thread_search(second_client, 104)
            post_repair = observe_package(chat_root, thread_id, "plain")
            post_repair_signatures = chat_journal_signatures(package_path)
            post_repair_timeline = summarize_command_crash_timeline(chat_root)
            post_repair_summary = summarize_chat_packages(chat_root)
        finally:
            second_stderr = close_or_collect(second_client)

    return {
        "thread_id": thread_id,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_start_error": turn_start_error,
        "crash_exit_code": crash_exit_code,
        "crash_was_signal_abort": isinstance(crash_exit_code, int) and crash_exit_code < 0,
        "first_stderr_tail": first_stderr[-6000:],
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
        "thread_read_serialized": serialized_json(read_response),
        "pre_repair": pre_repair,
        "post_repair": post_repair,
        "pre_repair_summary": pre_repair_summary,
        "post_repair_summary": post_repair_summary,
        "pre_repair_timeline_summary": pre_repair_timeline,
        "post_repair_timeline_summary": post_repair_timeline,
        "pre_repair_source_signatures": pre_repair_signatures,
        "post_repair_source_signatures": post_repair_signatures,
        "mock_server_summary": mock_server.summary(),
        "second_stderr_tail": second_stderr[-6000:],
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
                "client-user-command-output-fresh-original",
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
        help="command output boundary to abort after",
    )
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=None,
    )
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
    original_result = run_normal_command_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
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
    chat_workspace = run_root / "chat-backend" / "workspace"
    chat_home = run_root / "chat-backend" / "codex-home"
    chat_root = run_root / "chat-backend" / "chat-store"
    for path in [chat_workspace, chat_home, chat_root]:
        path.mkdir(parents=True, exist_ok=True)
    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]
    chat_result = run_chat_backend_command_output_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
        target["needle"],
    )

    original_storage = summarize_original_storage(pathlib.Path(original_result["codex_home"]))
    original_signatures = original_rollout_signatures(pathlib.Path(original_result["codex_home"]))
    chat_pre_count = valid_line_count(chat_result["pre_repair"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_repair"], "timeline")
    chat_prefix_signatures = chat_result["post_repair_source_signatures"]
    original_prefix = original_signatures[: len(chat_prefix_signatures)]
    post_timeline = chat_result["post_repair_timeline_summary"]
    visible_after_repair = chat_result["thread_read_serialized"]
    original_thread_id = thread_id_from_start_response(
        original_result["thread_start_response"]
    )
    original_normalized_read = normalize_thread_response(
        original_result["thread_read_response"],
        original_thread_id,
    )
    fresh_original_normalized_read = original_fresh_result["normalized_thread_read"]
    fresh_original_normalized_list = original_fresh_result["normalized_thread_list"]
    fresh_original_normalized_search = original_fresh_result["normalized_thread_search"]
    retains_success_command_call = any_package(
        post_timeline,
        "timeline_has_success_command_call",
    ) and signatures_contain_function_call(chat_prefix_signatures, SUCCESS_CALL_ID)
    retains_success_command_output = any_package(
        post_timeline,
        "timeline_has_success_command_output",
    ) and signatures_contain_function_call_output(
        chat_prefix_signatures,
        SUCCESS_CALL_ID,
        "contains_success_stdout",
        "contains_success_stderr",
    )
    retains_failure_command_call = any_package(
        post_timeline,
        "timeline_has_failure_command_call",
    ) and signatures_contain_function_call(chat_prefix_signatures, FAIL_CALL_ID)
    retains_failure_command_output = (
        any_package(post_timeline, "timeline_has_failure_command_output")
        and signatures_contain_function_call_output(
            chat_prefix_signatures,
            FAIL_CALL_ID,
            "contains_failure_stdout",
            "contains_failure_stderr",
        )
    )
    failure_retention_matches_target = (
        retains_failure_command_call and retains_failure_command_output
        if target["retains_failure_output"]
        else (
            not any_package(post_timeline, "timeline_contains_failure_call_id")
            and not any_package(post_timeline, "timeline_contains_failure_stdout")
            and not any_package(post_timeline, "timeline_contains_failure_stderr")
        )
    )
    fresh_read_failure_visibility_matches_target = (
        True
        if target["retains_failure_output"]
        else (
            "CMD_FAIL_STDOUT" not in visible_after_repair
            and "CMD_FAIL_STDERR" not in visible_after_repair
        )
    )
    final_answer_retention_matches_target = (
        any_package(post_timeline, "timeline_contains_final_text")
        and any_package(post_timeline, "journal_contains_final_text")
        if target["retains_final_answer"]
        else (
            not any_package(post_timeline, "timeline_contains_final_text")
            and not any_package(post_timeline, "journal_contains_final_text")
        )
    )
    task_complete_retention_matches_target = (
        any_package(post_timeline, "timeline_contains_task_complete")
        and any_package(post_timeline, "journal_contains_task_complete")
        if target["retains_task_complete"]
        else (
            not any_package(post_timeline, "timeline_contains_task_complete")
            and not any_package(post_timeline, "journal_contains_task_complete")
        )
    )
    fresh_read_final_visibility_matches_target = (
        FINAL_TEXT in visible_after_repair
        if target["retains_final_answer"]
        else FINAL_TEXT not in visible_after_repair
    )
    complete_prefix_matches_original = len(chat_prefix_signatures) == len(original_signatures)
    prefix_shape_matches_target = (
        0 < len(chat_prefix_signatures) < len(original_signatures)
        if target["prefix_kind"] == "strict"
        else complete_prefix_matches_original
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": target["scope"],
        "matrix_slice": ["T01", "T02-adjacent", "T03-adjacent", "H04", "H05"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": target["needle"],
            "target": args.target,
            "boundary": target["boundary"],
        },
        "binary_checks": binary_checks,
        "chat_backend_process_aborted_at_failpoint": chat_result["crash_was_signal_abort"],
        "chat_backend_pre_repair_projection_stale": projection_was_stale_before_repair(
            chat_result["pre_repair"],
        ),
        "chat_backend_post_repair_projections_ok": all_projections_repaired(
            chat_result["post_repair"],
        ),
        "chat_backend_canonical_prefix_survived_crash": (
            chat_pre_count > 0
            and valid_line_count(chat_result["pre_repair"], "journal") == chat_pre_count
        ),
        "chat_backend_timeline_not_extended_by_repair": chat_pre_count == chat_post_count,
        "chat_backend_no_invalid_canonical_lines": (
            invalid_line_count(chat_result["pre_repair"], "timeline") == 0
            and invalid_line_count(chat_result["pre_repair"], "journal") == 0
            and invalid_line_count(chat_result["post_repair"], "timeline") == 0
            and invalid_line_count(chat_result["post_repair"], "journal") == 0
        ),
        "chat_backend_prefix_matches_original_prefix": (
            bool(chat_prefix_signatures) and chat_prefix_signatures == original_prefix
        ),
        "original_complete_line_count": len(original_signatures),
        "chat_backend_prefix_line_count": len(chat_prefix_signatures),
        "chat_backend_prefix_is_strict_prefix": (
            0 < len(chat_prefix_signatures) < len(original_signatures)
        ),
        "chat_backend_complete_prefix_matches_original_length": complete_prefix_matches_original,
        "chat_backend_prefix_shape_matches_target": prefix_shape_matches_target,
        "chat_backend_retains_success_command_call": retains_success_command_call,
        "chat_backend_retains_success_command_output": retains_success_command_output,
        "chat_backend_retains_failure_command_call": retains_failure_command_call,
        "chat_backend_retains_failure_command_output": retains_failure_command_output,
        "chat_backend_failure_retention_matches_target": failure_retention_matches_target,
        "chat_backend_final_answer_retention_matches_target": (
            final_answer_retention_matches_target
        ),
        "chat_backend_task_complete_retention_matches_target": (
            task_complete_retention_matches_target
        ),
        "chat_backend_does_not_fabricate_later_failure_command": (
            not any_package(post_timeline, "timeline_contains_failure_call_id")
            and not any_package(post_timeline, "timeline_contains_failure_stdout")
            and not any_package(post_timeline, "timeline_contains_failure_stderr")
        ),
        "chat_backend_does_not_fabricate_final_answer": (
            not any_package(post_timeline, "timeline_contains_final_text")
        ),
        "fresh_read_does_not_show_later_failure_or_final_answer": (
            "CMD_FAIL_STDOUT" not in visible_after_repair
            and "CMD_FAIL_STDERR" not in visible_after_repair
            and FINAL_TEXT not in visible_after_repair
        ),
        "fresh_read_failure_visibility_matches_target": (
            fresh_read_failure_visibility_matches_target
        ),
        "fresh_read_final_visibility_matches_target": fresh_read_final_visibility_matches_target,
        "normalized_thread_read_matches_fresh_original_for_complete_target": (
            chat_result["normalized_thread_read"] == fresh_original_normalized_read
            if target["prefix_kind"] == "complete"
            else None
        ),
        "normalized_thread_list_matches_fresh_original_for_complete_target": (
            chat_result["normalized_thread_list"] == fresh_original_normalized_list
            if target["prefix_kind"] == "complete"
            else None
        ),
        "normalized_thread_search_matches_fresh_original_for_complete_target": (
            chat_result["normalized_thread_search"] == fresh_original_normalized_search
            if target["prefix_kind"] == "complete"
            else None
        ),
        "normalized_thread_read_matches_live_original_except_loaded_status_for_complete_target": (
            without_loaded_status(chat_result["normalized_thread_read"])
            == without_loaded_status(original_normalized_read)
            if target["prefix_kind"] == "complete"
            else None
        ),
        "loaded_status_lifecycle_comparison": {
            "live_original_thread_read": original_normalized_read.get("thread_status_type"),
            "fresh_original_thread_read": fresh_original_normalized_read.get(
                "thread_status_type"
            ),
            "chat_backend_thread_read": chat_result["normalized_thread_read"].get(
                "thread_status_type"
            ),
            "interpretation": (
                "Live original status remains idle because that oracle reads "
                "inside the still-loaded app-server process. Fresh original and "
                "fresh .chat reads both reopen persisted storage and should "
                "surface notLoaded. Fresh-vs-fresh equality is the parity check "
                "for this durable read/list/search slice."
            ),
        },
        "original_source_semantics_used": {
            "recorder_pending_items_drain": "rollout/src/recorder.rs:1545-1550 and 1683-1714",
            "flush_barrier": "thread-store/src/local/live_writer.rs:114-129",
            "interpretation": (
                "Original Codex cannot replay an in-memory command suffix after "
                "process death. This smoke checks the .chat backend keeps the "
                f"durable {target['retained_output_label']} prefix, repairs "
                "projections from it, and does not invent "
                f"{target['unwritten_suffix_label']}."
            ),
        },
        "original_storage_summary": original_storage,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures_after_repair": chat_prefix_signatures,
        "original_normalized_live_command_items": original_result[
            "normalized_live_command_items"
        ],
        "original_normalized_thread_read": original_normalized_read,
        "fresh_original_normalized_thread_read": fresh_original_normalized_read,
        "fresh_original_normalized_thread_list": fresh_original_normalized_list,
        "fresh_original_normalized_thread_search": fresh_original_normalized_search,
        "chat_backend_normalized_thread_read": chat_result["normalized_thread_read"],
        "chat_backend_normalized_thread_list": chat_result["normalized_thread_list"],
        "chat_backend_normalized_thread_search": chat_result["normalized_thread_search"],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "fresh_original_mock_server_summary": original_fresh_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "chat_backend_pre_repair_timeline_summary": chat_result[
            "pre_repair_timeline_summary"
        ],
        "chat_backend_post_repair_timeline_summary": post_timeline,
        "not_yet_proven": target["not_yet_proven"],
        "original": original_result,
        "fresh_original": original_fresh_result,
        "chat_backend": chat_result,
    }
    summary["passed"] = all(
        [
            summary["chat_backend_process_aborted_at_failpoint"],
            summary["chat_backend_pre_repair_projection_stale"],
            summary["chat_backend_post_repair_projections_ok"],
            summary["chat_backend_canonical_prefix_survived_crash"],
            summary["chat_backend_timeline_not_extended_by_repair"],
            summary["chat_backend_no_invalid_canonical_lines"],
            summary["chat_backend_prefix_matches_original_prefix"],
            summary["chat_backend_prefix_shape_matches_target"],
            summary["chat_backend_retains_success_command_call"],
            summary["chat_backend_retains_success_command_output"],
            summary["chat_backend_failure_retention_matches_target"],
            summary["chat_backend_final_answer_retention_matches_target"],
            summary["chat_backend_task_complete_retention_matches_target"],
            summary["fresh_read_failure_visibility_matches_target"],
            summary["fresh_read_final_visibility_matches_target"],
            (
                summary[
                    "normalized_thread_read_matches_fresh_original_for_complete_target"
                ]
                and summary[
                    "normalized_thread_list_matches_fresh_original_for_complete_target"
                ]
                and summary[
                    "normalized_thread_search_matches_fresh_original_for_complete_target"
                ]
                if target["prefix_kind"] == "complete"
                else True
            ),
        ]
    )
    summary["claim"] = (
        "This proves a narrow command-output durable-write projection boundary: "
        "the adapted .chat backend aborts after "
        f"{target['retained_output_label']} "
        "is canonical but before projection rebuild, repairs projections on "
        "fresh read, retains the command_call/command_output prefix expected "
        f"for {args.target}, and does not fabricate {target['unwritten_suffix_label']}. "
        "For complete-target read/list/search, it compares fresh original "
        "against fresh .chat instead of mixing live and reopened lifecycle "
        "states. "
        "It is not full "
        "command crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/command-execution-normal-response.json", original_result)
    write_json(
        output_dir / "original/command-execution-fresh-response.json",
        original_fresh_result,
    )
    write_json(
        output_dir / "chat-backend/command-output-crash-response.json",
        chat_result,
    )

    report = f"""# App-Server Command Output Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow command-execution crash boundary. The adapted
backend aborts {target['boundary']}.

The adapted backend uses `{FAILPOINT_ENV}={FAILPOINT_NAME}` with
`{FAILPOINT_NEEDLE_ENV}={target['needle']}`.

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- canonical `.chat` prefix survived crash: `{summary['chat_backend_canonical_prefix_survived_crash']}`
- canonical line count stayed fixed during repair: `{summary['chat_backend_timeline_not_extended_by_repair']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- prefix matches original normal-run prefix: `{summary['chat_backend_prefix_matches_original_prefix']}`
- prefix is strict, not the full completed command scenario: `{summary['chat_backend_prefix_is_strict_prefix']}` (`{len(chat_prefix_signatures)}` of `{len(original_signatures)}`)
- prefix shape matches target `{target['prefix_kind']}`: `{summary['chat_backend_prefix_shape_matches_target']}`
- success command call retained: `{summary['chat_backend_retains_success_command_call']}`
- success command output retained: `{summary['chat_backend_retains_success_command_output']}`
- failing command call retained: `{summary['chat_backend_retains_failure_command_call']}`
- failing command output retained: `{summary['chat_backend_retains_failure_command_output']}`
- failure retention matches target: `{summary['chat_backend_failure_retention_matches_target']}`
- fresh read failure visibility matches target: `{summary['fresh_read_failure_visibility_matches_target']}`
- final assistant retention matches target: `{summary['chat_backend_final_answer_retention_matches_target']}`
- task_complete retention matches target: `{summary['chat_backend_task_complete_retention_matches_target']}`
- fresh read final-answer visibility matches target: `{summary['fresh_read_final_visibility_matches_target']}`
- normalized thread/read matches fresh original for complete target: `{summary['normalized_thread_read_matches_fresh_original_for_complete_target']}`
- normalized thread/list matches fresh original for complete target: `{summary['normalized_thread_list_matches_fresh_original_for_complete_target']}`
- normalized thread/search matches fresh original for complete target: `{summary['normalized_thread_search_matches_fresh_original_for_complete_target']}`
- normalized thread/read matches live original except loaded status for complete target: `{summary['normalized_thread_read_matches_live_original_except_loaded_status_for_complete_target']}`

Loaded status difference is recorded, not hidden:

```json
{json.dumps(summary['loaded_status_lifecycle_comparison'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-execution-normal-response.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-execution-fresh-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/command-output-crash-response.json
```

## Not Yet Proven

This smoke does not prove {", ".join(target['not_yet_proven'])}.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
