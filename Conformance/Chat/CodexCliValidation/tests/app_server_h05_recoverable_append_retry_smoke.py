#!/usr/bin/env python3
"""Run H05 recoverable append-retry parity smoke for the `.chat` backend.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The adapted `.chat` backend runs with an validation failpoint
that returns one recoverable append error after a canonical prefix has already
been written to `journal.ndjson` and `timeline.ndjson`.

Unlike the H05 process-abort smoke, this process must stay alive. The backend
must recover the durable prefix from `journal.ndjson`, retry only the unwritten
suffix, finish the turn, rebuild projections, and match the original backend
oracle for normal app-server read/list/search behavior.
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
    ASSISTANT_TEXT,
    CHAT_BACKEND_CODEX_RS,
    FIRST_USER_TEXT,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_search,
    send_thread_start,
    send_turn_start,
    summarize_mock_requests,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    summarize_chat_packages,
    summarize_original_storage,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
    run_original_oracle,
)
from app_server_h05_pending_write_failpoint_crash_smoke import (  # noqa: E402
    chat_journal_signatures,
    original_rollout_signatures,
)
from app_server_stale_projection_repair_smoke import (  # noqa: E402
    observe_package,
)


RECOVERABLE_FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT"
RECOVERABLE_MARKER_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT_MARKER"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-item-before-next-pending-item"
FAILPOINT_NEEDLE = "permissions instructions"

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_pending_write_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h04_projection_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_durable_turn_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_projection_repair_smoke.py",
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


def run_chat_backend_recoverable_retry(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    marker_path: pathlib.Path,
) -> dict[str, Any]:
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            recoverable_marker=marker_path,
        )
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-h05-recoverable-chat",
                FIRST_USER_TEXT,
            )
            first_process_exit_code_before_close = first_client.process.poll()
        finally:
            first_stderr = close_or_collect(first_client)

        marker_consumed = not marker_path.exists()
        pre_fresh_summary = summarize_chat_packages(chat_root)
        pre_fresh_observation = observe_package(chat_root, thread_id, "plain")
        package_path = pathlib.Path(pre_fresh_observation["package"])
        pre_fresh_signatures = chat_journal_signatures(package_path)

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
            "marker_consumed": marker_consumed,
            "marker_path": str(marker_path),
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "first_stderr_tail": first_stderr[-6000:],
            "second_stderr_tail": second_stderr[-6000:],
            "second_process_exit_code_before_close": second_process_exit_code_before_close,
        }


def line_count(summary: dict[str, Any]) -> int:
    packages = summary.get("packages") or []
    if not packages:
        return 0
    return int(packages[0].get("journal_line_count") or 0)


def valid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("valid_line_count") or 0)


def invalid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("invalid_line_count") or 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-h05-recoverable-append-retry-smoke-"
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
    marker_path = run_root / "chat-backend" / "recoverable-failpoint.marker"
    for path in [original_workspace, original_home, chat_workspace, chat_home, chat_root]:
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
    chat_result = run_chat_backend_recoverable_retry(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
        marker_path,
    )

    original_storage = summarize_original_storage(original_home)
    original_signatures = original_rollout_signatures(original_home)
    chat_signatures = chat_result["post_fresh_source_signatures"]
    chat_pre_count = valid_line_count(chat_result["pre_fresh_observation"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_fresh_observation"], "timeline")
    original_line_count = len(original_signatures)
    chat_line_count = len(chat_signatures)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-h05-recoverable-append-retry-smoke",
        "matrix_slice": ["H05", "R01-adjacent", "C02-adjacent"],
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
                "return one recoverable append error after a canonical prefix "
                "and before the next pending item in the same append batch"
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
            chat_result["pre_fresh_observation"]
        ),
        "chat_backend_projections_ok_after_fresh_read": all_projections_repaired(
            chat_result["post_fresh_observation"]
        ),
        "chat_backend_no_invalid_canonical_lines": (
            invalid_line_count(chat_result["pre_fresh_observation"], "timeline") == 0
            and invalid_line_count(chat_result["pre_fresh_observation"], "journal") == 0
            and invalid_line_count(chat_result["post_fresh_observation"], "timeline") == 0
            and invalid_line_count(chat_result["post_fresh_observation"], "journal") == 0
        ),
        "chat_backend_timeline_stable_across_fresh_read": chat_pre_count == chat_post_count,
        "chat_backend_line_count_matches_original": chat_line_count == original_line_count,
        "chat_backend_source_signatures_match_original": chat_signatures == original_signatures,
        "normalized_thread_read_matches_original": (
            chat_result["normalized_thread_read"]
            == original_result["normalized_thread_read"]
        ),
        "normalized_thread_list_matches_original": (
            chat_result["normalized_thread_list"]
            == original_result["normalized_thread_list"]
        ),
        "normalized_thread_search_matches_original": (
            chat_result["normalized_thread_search"]
            == original_result["normalized_thread_search"]
        ),
        "mock_model_request_summary_matches_original": (
            chat_result["mock_server_summary"] == original_result["mock_server_summary"]
        ),
        "original_line_count": original_line_count,
        "chat_backend_line_count": chat_line_count,
        "chat_backend_timeline_line_count_before_fresh_read": chat_pre_count,
        "chat_backend_timeline_line_count_after_fresh_read": chat_post_count,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures": chat_signatures,
        "original_normalized_thread_read": original_result["normalized_thread_read"],
        "chat_backend_normalized_thread_read": chat_result["normalized_thread_read"],
        "original_normalized_thread_list": original_result["normalized_thread_list"],
        "chat_backend_normalized_thread_list": chat_result["normalized_thread_list"],
        "original_normalized_thread_search": original_result["normalized_thread_search"],
        "chat_backend_normalized_thread_search": chat_result["normalized_thread_search"],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_storage_summary": original_storage,
        "chat_backend_storage_summary": chat_result["post_fresh_summary"],
        "not_yet_proven": [
            "CLI recoverable pending-write retry parity through ordinary CLI surfaces",
            "true transient filesystem I/O errors outside this validation failpoint",
            "process-kill boundaries for command execution, rollback, compaction, and cold transitions",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
        "original": original_result,
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
            summary["normalized_thread_read_matches_original"],
            summary["normalized_thread_list_matches_original"],
            summary["normalized_thread_search_matches_original"],
            summary["mock_model_request_summary_matches_original"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow app-server H05 recoverable append-retry slice: "
        "the adapted .chat backend survives a one-shot recoverable append error "
        "inside a real app-server turn, drains the durable prefix from "
        "journal.ndjson, writes only the unwritten suffix, rebuilds projections, "
        "and matches the original backend for normalized read/list/search and "
        "mock model request behavior. It is not final crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/h05-recoverable-original-response.json", original_result)
    write_json(
        output_dir / "chat-backend/h05-recoverable-chat-backend-response.json",
        chat_result,
    )

    report = f"""# App-Server H05 Recoverable Append Retry Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers the H05 boundary where an append batch returns a recoverable
error after a canonical prefix has already reached `journal.ndjson` and
`timeline.ndjson`, but the process remains alive and must retry the unwritten
suffix.

The adapted backend uses:

```text
{RECOVERABLE_FAILPOINT_ENV}={FAILPOINT_NAME}
{RECOVERABLE_MARKER_ENV}={marker_path}
{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}
```

## Result

- `.chat` backend process survived the recoverable error: `{summary['chat_backend_process_survived_recoverable_error']}`
- one-shot marker was consumed: `{summary['chat_backend_marker_consumed_once']}`
- turn completed after retry: `{summary['chat_backend_turn_completed_after_retry']}`
- projections valid before fresh read: `{summary['chat_backend_projections_ok_before_fresh_read']}`
- projections valid after fresh read: `{summary['chat_backend_projections_ok_after_fresh_read']}`
- no invalid canonical lines: `{summary['chat_backend_no_invalid_canonical_lines']}`
- timeline count stable across fresh read: `{summary['chat_backend_timeline_stable_across_fresh_read']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- journal line count matches original: `{summary['chat_backend_line_count_matches_original']}` (`{chat_line_count}` == `{original_line_count}`)
- source signatures match original: `{summary['chat_backend_source_signatures_match_original']}`
- normalized thread/read matches original: `{summary['normalized_thread_read_matches_original']}`
- normalized thread/list matches original: `{summary['normalized_thread_list_matches_original']}`
- normalized thread/search matches original: `{summary['normalized_thread_search_matches_original']}`
- mock model request summary matches original: `{summary['mock_model_request_summary_matches_original']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/h05-recoverable-original-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/h05-recoverable-chat-backend-response.json
```

## Not Yet Proven

This smoke does not prove CLI-level recoverable retry parity, arbitrary
transient filesystem I/O failures outside this validation failpoint, process-kill
boundaries for command execution, rollback, compaction, cold transitions, final
crash recovery parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
