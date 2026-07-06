#!/usr/bin/env python3
"""Run RB05 rollback-after-compaction projection-boundary crash smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend runs the rollback-after-compaction flow normally as
the oracle. The adapted `.chat` backend runs the same flow with an internal
validation failpoint that aborts the process after the rollback control event is
canonical in `journal.ndjson` / `timeline.ndjson`, but before standard
projections are rebuilt. A fresh app-server then reads, repairs, resumes, and
continues the thread.

This proves only a narrow app-server RB05 control-event process-abort boundary.
It is not a final rollback, compaction, crash-recovery, or
user-indistinguishability claim.
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

from app_server_cold_resume_smoke import send_thread_resume  # noqa: E402
from app_server_compaction_smoke import send_thread_compact_start  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
    projection_was_stale_before_repair,
    wait_for_process_exit,
)
from app_server_rollback_after_compaction_smoke import (  # noqa: E402
    FIRST_USER_TEXT,
    SECOND_USER_TEXT,
    FOLLOWUP_USER_TEXT,
    FIRST_ASSISTANT_TEXT,
    SECOND_ASSISTANT_TEXT,
    FOLLOWUP_ASSISTANT_TEXT,
    COMPACTION_SUMMARY_TEXT,
    RollbackAfterCompactionMockServer,
    chat_storage_detail,
    normalize_compaction_result,
    normalize_rollback_result,
    normalize_thread_list_response,
    normalize_thread_response,
    original_storage_detail,
    summarize_mock_requests,
    tree_storage_summary,
    write_rb05_mock_config,
)
from app_server_rollback_smoke import (  # noqa: E402
    count_rollback_markers,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_rollback,
    send_thread_start,
    send_turn_start,
    storage_line_counts,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "thread_rolled_back"

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_after_compaction_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h04_projection_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/core/src/session/rollout_reconstruction.rs",
]


def with_failpoint_env() -> dict[str, str | None]:
    old = {
        FAILPOINT_ENV: os.environ.get(FAILPOINT_ENV),
        FAILPOINT_NEEDLE_ENV: os.environ.get(FAILPOINT_NEEDLE_ENV),
    }
    os.environ[FAILPOINT_ENV] = FAILPOINT_NAME
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
    failpoint: bool = False,
) -> JsonRpcClient:
    if not failpoint:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    old = with_failpoint_env()
    try:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    finally:
        restore_env(old)


def line_counts(storage: dict[str, Any], tree_name: str) -> list[int]:
    return storage_line_counts(storage, tree_name)


def storage_detail_for(
    tree_name: str,
    storage: dict[str, Any],
) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return chat_storage_detail(storage)
    return original_storage_detail(storage)


def final_history_ok(normalized: dict[str, Any]) -> bool:
    return all(
        [
            normalized["turn_count"] == 3,
            normalized["contains_first_user_text"],
            normalized["contains_first_assistant_text"],
            normalized["contains_second_user_text"],
            normalized["contains_second_assistant_text"],
            normalized["contains_followup_user_text"],
            normalized["contains_followup_assistant_text"],
            normalized["contains_context_compaction_item"],
        ]
    )


def followup_context_ok(summary: dict[str, Any]) -> bool:
    return all(
        [
            summary["followup_response_contains_followup_user_text"],
            summary["followup_response_contains_compaction_summary"],
            not summary["followup_response_contains_first_user_text"],
            not summary["followup_response_contains_first_assistant_text"],
            not summary["followup_response_contains_second_user_text"],
            not summary["followup_response_contains_second_assistant_text"],
        ]
    )


def run_original_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with RollbackAfterCompactionMockServer() as mock_server:
        write_rb05_mock_config(codex_home, mock_server.url)
        first_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-rb05-failpoint-first",
                FIRST_USER_TEXT,
            )
            second_turn = send_turn_start(
                first_client,
                4,
                thread_id,
                "client-user-message-rb05-failpoint-second",
                SECOND_USER_TEXT,
            )
            before_compaction_read = send_thread_read(first_client, 5, thread_id)
            compaction = send_thread_compact_start(first_client, 6, thread_id)
            after_compaction_read = send_thread_read(first_client, 7, thread_id)
            rollback = send_thread_rollback(first_client, 8, thread_id, 1)
            after_rollback_read = send_thread_read(first_client, 9, thread_id)
        finally:
            first_stderr = close_or_collect(first_client)

        storage_after_rollback = summarize_original_storage(codex_home)
        storage_after_rollback_detail = storage_detail_for(
            "original",
            storage_after_rollback,
        )

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 10)
            read_after_reopen = send_thread_read(second_client, 11, thread_id)
            resume_after_rollback = send_thread_resume(second_client, 12, thread_id)
            read_after_resume = send_thread_read(second_client, 13, thread_id)
            followup_turn = send_turn_start(
                second_client,
                14,
                thread_id,
                "client-user-message-rb05-failpoint-followup",
                FOLLOWUP_USER_TEXT,
            )
            final_read = send_thread_read(second_client, 15, thread_id)
            final_list = send_thread_list(second_client, 16)
        finally:
            second_stderr = close_or_collect(second_client)

    final_storage = summarize_original_storage(codex_home)
    return {
        "thread_id": thread_id,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "first_turn": first_turn,
        "second_turn": second_turn,
        "before_compaction_read": before_compaction_read,
        "compaction": compaction,
        "after_compaction_read": after_compaction_read,
        "rollback": rollback,
        "after_rollback_read": after_rollback_read,
        "second_initialize_response": second_initialize_response,
        "read_after_reopen": read_after_reopen,
        "resume_after_rollback": resume_after_rollback,
        "read_after_resume": read_after_resume,
        "followup_turn": followup_turn,
        "final_read": final_read,
        "final_list": final_list,
        "first_stderr_tail": first_stderr[-6000:],
        "second_stderr_tail": second_stderr[-6000:],
        "first_process_exit_code": first_client.process.returncode,
        "second_process_exit_code": second_client.process.returncode,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "storage_after_rollback": storage_after_rollback,
        "final_storage": final_storage,
        "storage_after_rollback_detail": storage_after_rollback_detail,
        "final_storage_detail": storage_detail_for("original", final_storage),
        "storage_line_counts_after_rollback": line_counts(
            storage_after_rollback,
            "original",
        ),
        "final_storage_line_counts": line_counts(final_storage, "original"),
        "rollback_marker_count_after_rollback": count_rollback_markers(
            "original",
            codex_home,
            pathlib.Path(),
        ),
        "normalized_after_rollback": normalize_thread_response(after_rollback_read),
        "normalized_read_after_reopen": normalize_thread_response(read_after_reopen),
        "normalized_resume_after_rollback": normalize_thread_response(
            resume_after_rollback
        ),
        "normalized_read_after_resume": normalize_thread_response(read_after_resume),
        "normalized_final_read": normalize_thread_response(final_read),
        "normalized_final_list": normalize_thread_list_response(final_list, thread_id),
        "normalized_compaction": normalize_compaction_result(compaction),
        "normalized_rollback": normalize_rollback_result(rollback),
    }


def run_chat_backend_crash_and_repair(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with RollbackAfterCompactionMockServer() as mock_server:
        write_rb05_mock_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=True,
        )
        first_stderr = ""
        rollback_response: dict[str, Any] | None = None
        rollback_error: str | None = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-rb05-failpoint-first",
                FIRST_USER_TEXT,
            )
            second_turn = send_turn_start(
                first_client,
                4,
                thread_id,
                "client-user-message-rb05-failpoint-second",
                SECOND_USER_TEXT,
            )
            before_compaction_read = send_thread_read(first_client, 5, thread_id)
            compaction = send_thread_compact_start(first_client, 6, thread_id)
            after_compaction_read = send_thread_read(first_client, 7, thread_id)
            try:
                rollback_response = send_thread_rollback(first_client, 8, thread_id, 1)
            except Exception as exc:
                rollback_error = repr(exc)
            crash_exit_code = wait_for_process_exit(first_client, timeout_seconds=60)
        finally:
            first_stderr = close_or_collect(first_client)

        pre_repair = observe_package(chat_root, thread_id, "plain")
        storage_after_crash = summarize_chat_packages(chat_root)
        storage_after_crash_detail = storage_detail_for(
            "chat-backend",
            storage_after_crash,
        )

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 10)
            read_after_repair = send_thread_read(second_client, 11, thread_id)
            post_repair = observe_package(chat_root, thread_id, "plain")
            storage_after_repair = summarize_chat_packages(chat_root)
            resume_after_rollback = send_thread_resume(second_client, 12, thread_id)
            read_after_resume = send_thread_read(second_client, 13, thread_id)
            followup_turn = send_turn_start(
                second_client,
                14,
                thread_id,
                "client-user-message-rb05-failpoint-followup",
                FOLLOWUP_USER_TEXT,
            )
            final_read = send_thread_read(second_client, 15, thread_id)
            final_list = send_thread_list(second_client, 16)
        finally:
            second_stderr = close_or_collect(second_client)

    final_storage = summarize_chat_packages(chat_root)
    return {
        "thread_id": thread_id,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "first_turn": first_turn,
        "second_turn": second_turn,
        "before_compaction_read": before_compaction_read,
        "compaction": compaction,
        "after_compaction_read": after_compaction_read,
        "rollback_response": rollback_response,
        "rollback_error": rollback_error,
        "crash_exit_code": crash_exit_code,
        "crash_was_signal_abort": isinstance(crash_exit_code, int)
        and crash_exit_code < 0,
        "first_stderr_tail": first_stderr[-6000:],
        "second_initialize_response": second_initialize_response,
        "read_after_repair": read_after_repair,
        "resume_after_rollback": resume_after_rollback,
        "read_after_resume": read_after_resume,
        "followup_turn": followup_turn,
        "final_read": final_read,
        "final_list": final_list,
        "second_stderr_tail": second_stderr[-6000:],
        "pre_repair": pre_repair,
        "post_repair": post_repair,
        "storage_after_crash": storage_after_crash,
        "storage_after_repair": storage_after_repair,
        "final_storage": final_storage,
        "storage_after_crash_detail": storage_after_crash_detail,
        "final_storage_detail": storage_detail_for("chat-backend", final_storage),
        "storage_line_counts_after_crash": line_counts(
            storage_after_crash,
            "chat-backend",
        ),
        "storage_line_counts_after_repair": line_counts(
            storage_after_repair,
            "chat-backend",
        ),
        "final_storage_line_counts": line_counts(final_storage, "chat-backend"),
        "rollback_marker_count_after_crash": count_rollback_markers(
            "chat-backend",
            codex_home,
            chat_root,
        ),
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "normalized_after_compaction": normalize_thread_response(after_compaction_read),
        "normalized_read_after_repair": normalize_thread_response(read_after_repair),
        "normalized_resume_after_rollback": normalize_thread_response(
            resume_after_rollback
        ),
        "normalized_read_after_resume": normalize_thread_response(read_after_resume),
        "normalized_final_read": normalize_thread_response(final_read),
        "normalized_final_list": normalize_thread_list_response(final_list, thread_id),
        "normalized_compaction": normalize_compaction_result(compaction),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-rollback-after-compaction-failpoint-crash-smoke-"
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
    original_workspace = run_root / "original" / "workspace"
    original_home = run_root / "original" / "codex-home"
    chat_workspace = run_root / "chat-backend" / "workspace"
    chat_home = run_root / "chat-backend" / "codex-home"
    chat_root = run_root / "chat-backend" / "chat-store"
    for path in [
        original_workspace,
        original_home,
        chat_workspace,
        chat_home,
        chat_root,
    ]:
        path.mkdir(parents=True, exist_ok=True)

    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]

    original_result = run_original_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        original_workspace,
        original_home,
        [],
    )
    chat_result = run_chat_backend_crash_and_repair(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
    )

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    final_storage_line_counts_equal = (
        original_result["final_storage_line_counts"]
        == chat_result["final_storage_line_counts"]
        and bool(original_result["final_storage_line_counts"])
    )
    crash_prefix_line_counts_equal = (
        original_result["storage_line_counts_after_rollback"]
        == chat_result["storage_line_counts_after_crash"]
        and bool(original_result["storage_line_counts_after_rollback"])
    )
    comparisons = {
        "read_after_repair_matches_original_after_rollback": (
            original_result["normalized_read_after_reopen"]
            == chat_result["normalized_read_after_repair"]
        ),
        "resume_after_rollback_matches": (
            original_result["normalized_resume_after_rollback"]
            == chat_result["normalized_resume_after_rollback"]
        ),
        "read_after_resume_matches": (
            original_result["normalized_read_after_resume"]
            == chat_result["normalized_read_after_resume"]
        ),
        "final_read_matches": (
            original_result["normalized_final_read"]
            == chat_result["normalized_final_read"]
        ),
        "final_list_matches": (
            original_result["normalized_final_list"]
            == chat_result["normalized_final_list"]
        ),
    }
    storage_preserved_ok = all(
        [
            original_result["storage_after_rollback_detail"]["compacted_count"] >= 1,
            chat_result["storage_after_crash_detail"][
                "timeline_compaction_event_count"
            ]
            >= 1,
            chat_result["storage_after_crash_detail"][
                "timeline_rollback_event_count"
            ]
            == 1,
            chat_result["storage_after_crash_detail"][
                "journal_compaction_event_count"
            ]
            >= 1,
            chat_result["storage_after_crash_detail"][
                "journal_rollback_marker_count"
            ]
            == 1,
            original_result["storage_after_rollback_detail"][
                "contains_rollback_marker"
            ],
            chat_result["storage_after_crash_detail"]["contains_rollback_marker"],
            original_result["storage_after_rollback_detail"][
                "has_replacement_history"
            ],
            chat_result["storage_after_crash_detail"]["has_replacement_history"],
            original_result["storage_after_rollback_detail"][
                "contains_second_user_text"
            ],
            chat_result["storage_after_crash_detail"]["contains_second_user_text"],
            original_result["storage_after_rollback_detail"][
                "contains_compaction_summary"
            ],
            chat_result["storage_after_crash_detail"][
                "contains_compaction_summary"
            ],
        ]
    )
    mock_context_ok = all(
        [
            original_mock["response_request_count"]
            == chat_mock["response_request_count"],
            followup_context_ok(original_mock),
            followup_context_ok(chat_mock),
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-rollback-after-compaction-failpoint-crash-smoke",
        "matrix_slice": ["RB05", "H04-adjacent", "H05-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": FAILPOINT_NEEDLE,
        },
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_repair_resume_followup_fields_equal": all(
            comparisons.values()
        ),
        "chat_backend_process_aborted_at_rollback_failpoint": chat_result[
            "crash_was_signal_abort"
        ],
        "chat_backend_rollback_request_had_no_response": (
            chat_result["rollback_response"] is None
        ),
        "chat_backend_pre_repair_projection_stale": (
            projection_was_stale_before_repair(chat_result["pre_repair"])
        ),
        "chat_backend_post_repair_projections_ok": all_projections_repaired(
            chat_result["post_repair"]
        ),
        "chat_backend_canonical_survived_crash": (
            (chat_result["pre_repair"].get("timeline") or {}).get(
                "valid_line_count",
                0,
            )
            > 0
            and (chat_result["pre_repair"].get("journal") or {}).get(
                "valid_line_count",
                0,
            )
            > 0
        ),
        "crash_prefix_line_counts_equal": crash_prefix_line_counts_equal,
        "final_storage_line_counts_equal": final_storage_line_counts_equal,
        "storage_preserved_compaction_and_rollback_ok": storage_preserved_ok,
        "rollback_marker_counts_after_crash_equal": (
            original_result["rollback_marker_count_after_rollback"]
            == chat_result["rollback_marker_count_after_crash"]
            == 1
        ),
        "chat_backend_timeline_rollback_event_count_after_crash": (
            chat_result["storage_after_crash_detail"]["timeline_rollback_event_count"]
        ),
        "chat_backend_timeline_rollback_event_count_matches_marker_count_after_crash": (
            chat_result["storage_after_crash_detail"]["timeline_rollback_event_count"]
            == chat_result["rollback_marker_count_after_crash"]
        ),
        "mock_context_after_followup_ok": mock_context_ok,
        "original_final_history_ok": final_history_ok(
            original_result["normalized_final_read"]
        ),
        "chat_backend_final_history_ok": final_history_ok(
            chat_result["normalized_final_read"]
        ),
        "original_storage_line_counts_after_rollback": original_result[
            "storage_line_counts_after_rollback"
        ],
        "chat_backend_storage_line_counts_after_crash": chat_result[
            "storage_line_counts_after_crash"
        ],
        "original_final_storage_line_counts": original_result[
            "final_storage_line_counts"
        ],
        "chat_backend_final_storage_line_counts": chat_result[
            "final_storage_line_counts"
        ],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_normalized_read_after_reopen": original_result[
            "normalized_read_after_reopen"
        ],
        "chat_backend_normalized_read_after_repair": chat_result[
            "normalized_read_after_repair"
        ],
        "original_normalized_resume_after_rollback": original_result[
            "normalized_resume_after_rollback"
        ],
        "chat_backend_normalized_resume_after_rollback": chat_result[
            "normalized_resume_after_rollback"
        ],
        "original_normalized_final_read": original_result["normalized_final_read"],
        "chat_backend_normalized_final_read": chat_result["normalized_final_read"],
        "original_storage_after_rollback_detail": original_result[
            "storage_after_rollback_detail"
        ],
        "chat_backend_storage_after_crash_detail": chat_result[
            "storage_after_crash_detail"
        ],
        "not_yet_proven": [
            "automatic-compaction RB05 process-abort boundaries",
            "process death before or during rollback marker durability",
            "remote automatic compaction",
            "world state full/patch restore across this boundary",
            "arbitrary filesystem I/O failures outside validation failpoints",
            "final rollback/compaction crash-recovery parity",
            "final user-indistinguishability",
        ],
        "original": original_result,
        "chat_backend": chat_result,
    }
    summary["passed"] = all(
        [
            summary["all_normalized_repair_resume_followup_fields_equal"],
            summary["chat_backend_process_aborted_at_rollback_failpoint"],
            summary["chat_backend_rollback_request_had_no_response"],
            summary["chat_backend_pre_repair_projection_stale"],
            summary["chat_backend_post_repair_projections_ok"],
            summary["chat_backend_canonical_survived_crash"],
            summary["crash_prefix_line_counts_equal"],
            summary["final_storage_line_counts_equal"],
            summary["storage_preserved_compaction_and_rollback_ok"],
            summary["rollback_marker_counts_after_crash_equal"],
            summary[
                "chat_backend_timeline_rollback_event_count_matches_marker_count_after_crash"
            ],
            summary["mock_context_after_followup_ok"],
            summary["original_final_history_ok"],
            summary["chat_backend_final_history_ok"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow app-server RB05 control-event process-abort "
        "slice: after manual compaction, the adapted .chat backend aborts "
        "after the rollback marker is canonical and before projection rebuild; "
        "a fresh app-server repairs projections from canonical data, resumes, "
        "and completes a follow-up turn with original-equivalent normalized "
        "read/list surfaces, model-context markers, rollback marker count, and "
        "durable line counts. It is not final rollback, compaction, or crash "
        "recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/rb05-original-response.json", original_result)
    write_json(
        output_dir / "chat-backend/rb05-chat-backend-response.json",
        chat_result,
    )

    report = f"""# App-Server RB05 Rollback After Compaction Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers the app-server boundary where rollback-after-manual-compaction
control data is canonical but derived projections are stale because the adapted
backend aborts before projection rebuild.

The adapted backend uses `{FAILPOINT_ENV}={FAILPOINT_NAME}` with
`{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}`. The original backend runs the same
flow normally and acts as the oracle.

## Result

- `.chat` backend aborted at rollback failpoint: `{summary['chat_backend_process_aborted_at_rollback_failpoint']}`
- `.chat` rollback request returned no response because of abort: `{summary['chat_backend_rollback_request_had_no_response']}`
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- normalized repair/resume/follow-up fields equal: `{summary['all_normalized_repair_resume_followup_fields_equal']}`
- crash-prefix line counts equal: `{summary['crash_prefix_line_counts_equal']}` (`{summary['original_storage_line_counts_after_rollback']}` vs `{summary['chat_backend_storage_line_counts_after_crash']}`)
- final line counts equal: `{summary['final_storage_line_counts_equal']}` (`{summary['original_final_storage_line_counts']}` vs `{summary['chat_backend_final_storage_line_counts']}`)
- compaction checkpoint/source transport and rollback marker preserved: `{summary['storage_preserved_compaction_and_rollback_ok']}`
- `.chat` timeline rollback event count after crash: `{summary['chat_backend_timeline_rollback_event_count_after_crash']}`
- `.chat` timeline rollback count matches marker count after crash: `{summary['chat_backend_timeline_rollback_event_count_matches_marker_count_after_crash']}`
- follow-up model context uses compaction baseline: `{summary['mock_context_after_followup_ok']}`

## Comparison Booleans

```json
{json.dumps(comparisons, indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## Storage Detail

```json
{json.dumps({'original_after_rollback': original_result['storage_after_rollback_detail'], 'chat_backend_after_crash': chat_result['storage_after_crash_detail']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/rb05-original-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/rb05-chat-backend-response.json
```

## Not Yet Proven

This smoke does not prove automatic-compaction RB05 process-abort boundaries,
process death before or during rollback marker durability, remote automatic
compaction, world-state full/patch restore across this boundary, arbitrary
filesystem I/O failures outside validation failpoints, final rollback/compaction
crash-recovery parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
