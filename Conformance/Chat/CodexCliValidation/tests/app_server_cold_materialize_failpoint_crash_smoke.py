#!/usr/bin/env python3
"""Run cold materialize-before-append failpoint crash-recovery smoke.

This source-backed validation covers a narrow cold-history transition boundary for
the adapted `.chat` backend. The `.chat` package starts in the internal cold
representation (`.chat.cold/`), then `thread/resume` aborts after the cold
package is materialized back to plain `.chat/` but before the resumed writer can
append anything. A fresh app-server process must expose the same read/list/search
and follow-up-turn behavior as the original backend oracle.

This is cold-transition process-abort evidence, not full background compression
or final crash-recovery parity.
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
    ASSISTANT_TEXT,
    CHAT_BACKEND_CODEX_RS,
    FIRST_USER_TEXT,
    ORIGINAL_CODEX_RS,
    SECOND_USER_TEXT,
    JsonRpcClient,
    MockResponsesServer,
    chat_active_journal_line_count,
    cold_only_not_materialized,
    ensure_binary,
    materialized_plain_only,
    move_plain_to_cold,
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    original_line_count,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_resume,
    send_thread_search,
    send_thread_start,
    send_turn_start,
    summarize_chat_representations,
    summarize_mock_requests,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NAME = "after-cold-materialize-before-append"

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/compression.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/helpers.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_projection_repair_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h06_lifecycle_failpoint_crash_smoke.py",
]


def start_client(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    *,
    failpoint: bool = False,
) -> JsonRpcClient:
    previous = os.environ.get(FAILPOINT_ENV)
    if failpoint:
        os.environ[FAILPOINT_ENV] = FAILPOINT_NAME
    else:
        os.environ.pop(FAILPOINT_ENV, None)
    try:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    finally:
        if previous is None:
            os.environ.pop(FAILPOINT_ENV, None)
        else:
            os.environ[FAILPOINT_ENV] = previous


def close_or_collect(client: JsonRpcClient) -> str:
    if client.process.poll() is None:
        return client.close()
    assert client.process.stderr is not None
    return client.process.stderr.read()


def wait_for_process_exit(client: JsonRpcClient, timeout_seconds: float = 30) -> int | None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        code = client.process.poll()
        if code is not None:
            return code
        time.sleep(0.1)
    return None


def run_original_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)

        first_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-cold-materialize-original-1",
                FIRST_USER_TEXT,
            )
            storage_after_first_turn = summarize_original_storage(codex_home)
        finally:
            first_stderr = close_or_collect(first_client)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            fresh_read_response = send_thread_read(second_client, 102, thread_id)
            fresh_list_response = send_thread_list(second_client, 103)
            fresh_search_response = send_thread_search(second_client, 104)
            resume_response = send_thread_resume(second_client, 105, thread_id)
            second_turn_start_response = send_turn_start(
                second_client,
                106,
                thread_id,
                "client-user-cold-materialize-original-2",
                SECOND_USER_TEXT,
            )
            final_read_response = send_thread_read(second_client, 107, thread_id)
            final_list_response = send_thread_list(second_client, 108)
            final_search_response = send_thread_search(second_client, 109)
            storage_after_second_turn = summarize_original_storage(codex_home)
        finally:
            second_stderr = close_or_collect(second_client)

        return {
            "thread_id": thread_id,
            "first_process": {
                "initialize_response": first_initialize_response,
                "thread_start_response": thread_start_response,
                "turn_start_response": first_turn_start_response,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "initialize_response": second_initialize_response,
                "fresh_read_response": fresh_read_response,
                "fresh_list_response": fresh_list_response,
                "fresh_search_response": fresh_search_response,
                "resume_response": resume_response,
                "second_turn_start_response": second_turn_start_response,
                "final_read_response": final_read_response,
                "final_list_response": final_list_response,
                "final_search_response": final_search_response,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "storage_after_first_turn": storage_after_first_turn,
            "storage_after_second_turn": storage_after_second_turn,
            "normalized_fresh_read": normalize_thread_response(
                fresh_read_response,
                thread_id,
            ),
            "normalized_fresh_list": normalize_thread_list_response(
                fresh_list_response,
                thread_id,
            ),
            "normalized_fresh_search": normalize_thread_search_response(
                fresh_search_response,
                thread_id,
            ),
            "normalized_resume": normalize_thread_response(resume_response, thread_id),
            "normalized_final_read": normalize_thread_response(
                final_read_response,
                thread_id,
            ),
            "normalized_final_list": normalize_thread_list_response(
                final_list_response,
                thread_id,
            ),
            "normalized_final_search": normalize_thread_search_response(
                final_search_response,
                thread_id,
            ),
        }


def run_chat_backend_crash_then_continue(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)

        first_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-cold-materialize-chat-1",
                FIRST_USER_TEXT,
            )
            storage_after_first_turn = summarize_chat_representations(chat_root)
        finally:
            first_stderr = close_or_collect(first_client)

        cold_move = move_plain_to_cold(chat_root, thread_id)
        storage_after_cold_move = summarize_chat_representations(chat_root)

        crash_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=True,
        )
        crash_stderr = ""
        resume_error: str | None = None
        resume_response: dict[str, Any] | None = None
        try:
            crash_initialize_response = send_initialize(crash_client, 100)
            try:
                resume_response = send_thread_resume(crash_client, 101, thread_id)
            except Exception as exc:
                resume_error = repr(exc)
            crash_exit_code = wait_for_process_exit(crash_client)
        finally:
            crash_stderr = close_or_collect(crash_client)

        storage_after_crash = summarize_chat_representations(chat_root)

        fresh_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        fresh_stderr = ""
        try:
            fresh_initialize_response = send_initialize(fresh_client, 201)
            fresh_read_response = send_thread_read(fresh_client, 202, thread_id)
            fresh_list_response = send_thread_list(fresh_client, 203)
            fresh_search_response = send_thread_search(fresh_client, 204)
            fresh_resume_response = send_thread_resume(fresh_client, 205, thread_id)
            second_turn_start_response = send_turn_start(
                fresh_client,
                206,
                thread_id,
                "client-user-cold-materialize-chat-2",
                SECOND_USER_TEXT,
            )
            final_read_response = send_thread_read(fresh_client, 207, thread_id)
            final_list_response = send_thread_list(fresh_client, 208)
            final_search_response = send_thread_search(fresh_client, 209)
            storage_after_second_turn = summarize_chat_representations(chat_root)
        finally:
            fresh_stderr = close_or_collect(fresh_client)

        return {
            "thread_id": thread_id,
            "first_process": {
                "initialize_response": first_initialize_response,
                "thread_start_response": thread_start_response,
                "turn_start_response": first_turn_start_response,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "cold_move": cold_move,
            "crash_process": {
                "initialize_response": crash_initialize_response,
                "resume_response": resume_response,
                "resume_error": resume_error,
                "crash_exit_code": crash_exit_code,
                "crash_was_signal_abort": isinstance(crash_exit_code, int)
                and crash_exit_code < 0,
                "stderr_tail": crash_stderr[-6000:],
            },
            "fresh_process": {
                "initialize_response": fresh_initialize_response,
                "fresh_read_response": fresh_read_response,
                "fresh_list_response": fresh_list_response,
                "fresh_search_response": fresh_search_response,
                "resume_response": fresh_resume_response,
                "second_turn_start_response": second_turn_start_response,
                "final_read_response": final_read_response,
                "final_list_response": final_list_response,
                "final_search_response": final_search_response,
                "stderr_tail": fresh_stderr[-6000:],
                "process_exit_code": fresh_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "storage_after_first_turn": storage_after_first_turn,
            "storage_after_cold_move": storage_after_cold_move,
            "storage_after_crash": storage_after_crash,
            "storage_after_second_turn": storage_after_second_turn,
            "normalized_fresh_read": normalize_thread_response(
                fresh_read_response,
                thread_id,
            ),
            "normalized_fresh_list": normalize_thread_list_response(
                fresh_list_response,
                thread_id,
            ),
            "normalized_fresh_search": normalize_thread_search_response(
                fresh_search_response,
                thread_id,
            ),
            "normalized_resume": normalize_thread_response(
                fresh_resume_response,
                thread_id,
            ),
            "normalized_final_read": normalize_thread_response(
                final_read_response,
                thread_id,
            ),
            "normalized_final_list": normalize_thread_list_response(
                final_list_response,
                thread_id,
            ),
            "normalized_final_search": normalize_thread_search_response(
                final_search_response,
                thread_id,
            ),
        }


def mock_second_turn_context_ok(summary: dict[str, Any]) -> bool:
    return all(
        [
            summary["response_request_count"] == 2,
            summary["second_response_input_contains_first_user_text"],
            summary["second_response_input_contains_first_assistant_text"],
            summary["second_response_input_contains_second_user_text"],
        ]
    )


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    report = f"""# App-Server Cold Materialize Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow cold-transition boundary:

```text
.chat.cold/ exists
thread/resume materializes it to .chat/
process aborts before resumed append can write new history
fresh app-server reads/resumes/continues the thread
```

It is not a final background-compression or crash-recovery parity claim.

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- cold package existed before crash: `{summary['chat_backend_cold_only_after_move']}`
- crash materialized the package back to plain `.chat/`: `{summary['chat_backend_materialized_plain_after_crash']}`
- first-turn line counts stayed equal after crash: `{summary['first_turn_line_counts_equal_after_crash']}`
- normalized fresh `thread/read` matches original: `{summary['fresh_thread_read_equal']}`
- normalized fresh `thread/list` matches original: `{summary['fresh_thread_list_equal']}`
- normalized fresh `thread/search` matches original: `{summary['fresh_thread_search_equal']}`
- normalized fresh `thread/resume` matches original: `{summary['fresh_resume_equal']}`
- normalized final `thread/read/list/search` after continuing matches original: `{summary['final_surfaces_equal_after_continue']}`
- second-turn model context preserved prior user/assistant history: `{summary['mock_second_turn_context_ok']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cold-materialize-original-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-materialize-chat-backend-response.json
```

## Not Yet Proven

This smoke does not prove arbitrary filesystem I/O failures, every cold
transition boundary, real background compression implementation details, rollback
or lifecycle process-kill parity, final crash recovery parity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-cold-materialize-failpoint-crash-smoke-"
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
    original_workspace = run_root / "original" / "workspace"
    original_home = run_root / "original" / "codex-home"
    chat_workspace = run_root / "chat-backend" / "workspace"
    chat_home = run_root / "chat-backend" / "codex-home"
    chat_root = run_root / "chat-backend" / "chat-store"
    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]

    original_result = run_original_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        original_workspace,
        original_home,
        [],
    )
    chat_result = run_chat_backend_crash_then_continue(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
    )

    original_first_lines = original_line_count(original_result["storage_after_first_turn"])
    original_final_lines = original_line_count(original_result["storage_after_second_turn"])
    chat_crash_lines = chat_active_journal_line_count(chat_result["storage_after_crash"])
    chat_final_lines = chat_active_journal_line_count(
        chat_result["storage_after_second_turn"]
    )

    fresh_comparisons = {
        "thread_read": original_result["normalized_fresh_read"]
        == chat_result["normalized_fresh_read"],
        "thread_list": original_result["normalized_fresh_list"]
        == chat_result["normalized_fresh_list"],
        "thread_search": original_result["normalized_fresh_search"]
        == chat_result["normalized_fresh_search"],
        "thread_resume": original_result["normalized_resume"]
        == chat_result["normalized_resume"],
    }
    final_comparisons = {
        "thread_read": original_result["normalized_final_read"]
        == chat_result["normalized_final_read"],
        "thread_list": original_result["normalized_final_list"]
        == chat_result["normalized_final_list"],
        "thread_search": original_result["normalized_final_search"]
        == chat_result["normalized_final_search"],
    }

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-materialize-failpoint-crash-smoke",
        "matrix_slice": ["H02", "H04-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
        },
        "binary_checks": binary_checks,
        "fresh_comparisons": fresh_comparisons,
        "final_comparisons": final_comparisons,
        "fresh_thread_read_equal": fresh_comparisons["thread_read"],
        "fresh_thread_list_equal": fresh_comparisons["thread_list"],
        "fresh_thread_search_equal": fresh_comparisons["thread_search"],
        "fresh_resume_equal": fresh_comparisons["thread_resume"],
        "final_surfaces_equal_after_continue": all(final_comparisons.values()),
        "chat_backend_process_aborted_at_failpoint": chat_result["crash_process"][
            "crash_was_signal_abort"
        ],
        "chat_backend_cold_move_succeeded": chat_result["cold_move"].get("moved")
        is True,
        "chat_backend_cold_only_after_move": cold_only_not_materialized(
            chat_result["storage_after_cold_move"]
        ),
        "chat_backend_materialized_plain_after_crash": materialized_plain_only(
            chat_result["storage_after_crash"]
        ),
        "chat_backend_stayed_plain_after_continue": materialized_plain_only(
            chat_result["storage_after_second_turn"]
        ),
        "first_turn_line_counts_equal_after_crash": original_first_lines is not None
        and original_first_lines == chat_crash_lines,
        "final_line_counts_equal_after_continue": original_final_lines is not None
        and original_final_lines == chat_final_lines,
        "original_first_turn_rollout_lines": original_first_lines,
        "chat_journal_lines_after_crash": chat_crash_lines,
        "original_final_rollout_lines": original_final_lines,
        "chat_final_journal_lines": chat_final_lines,
        "mock_response_request_counts_equal": original_mock["response_request_count"]
        == chat_mock["response_request_count"],
        "mock_second_turn_context_ok": mock_second_turn_context_ok(original_mock)
        and mock_second_turn_context_ok(chat_mock),
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "not_yet_proven": [
            "arbitrary filesystem I/O failures outside validation failpoints",
            "every cold transition boundary",
            "real background compression implementation details",
            "true process-kill rollback/lifecycle parity",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
        "claim": (
            "This proves a narrow H02/cold-transition process-abort slice: "
            "the adapted .chat backend materializes a .chat.cold package to "
            "plain .chat during thread/resume, aborts before appending new "
            "history, then a fresh app-server can read/list/search/resume and "
            "continue the thread with original-equivalent normalized surfaces."
        ),
        "original": original_result,
        "chat_backend": chat_result,
    }
    summary["passed"] = all(
        [
            summary["fresh_thread_read_equal"],
            summary["fresh_thread_list_equal"],
            summary["fresh_thread_search_equal"],
            summary["fresh_resume_equal"],
            summary["final_surfaces_equal_after_continue"],
            summary["chat_backend_process_aborted_at_failpoint"],
            summary["chat_backend_cold_move_succeeded"],
            summary["chat_backend_cold_only_after_move"],
            summary["chat_backend_materialized_plain_after_crash"],
            summary["chat_backend_stayed_plain_after_continue"],
            summary["first_turn_line_counts_equal_after_crash"],
            summary["final_line_counts_equal_after_continue"],
            summary["mock_response_request_counts_equal"],
            summary["mock_second_turn_context_ok"],
        ]
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/cold-materialize-original-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/cold-materialize-chat-backend-response.json",
        chat_result,
    )
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
