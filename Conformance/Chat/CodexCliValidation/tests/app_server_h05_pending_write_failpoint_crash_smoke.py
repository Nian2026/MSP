#!/usr/bin/env python3
"""Run H05 append-batch process-abort smoke for the `.chat` backend.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The adapted `.chat` backend runs with an validation failpoint
that aborts after a matched canonical item has been written to journal/timeline
and before the next canonical item in the same append batch is written.

This proves only a narrow H05 boundary: a process abort during an append batch
leaves a durable canonical prefix, does not fabricate the unwritten suffix on a
fresh read, and repairs stale projections from that prefix. It is not a final
crash recovery or original-backend parity claim.
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
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
    projection_was_stale_before_repair,
    run_original_oracle,
    wait_for_process_exit,
)
from app_server_stale_projection_repair_smoke import (  # noqa: E402
    observe_package,
)


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
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
    "Conformance/Chat/CodexCliValidation/tests/app_server_h04_projection_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_durable_turn_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_projection_repair_smoke.py",
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


def rollout_payload_signature(value: dict[str, Any]) -> dict[str, Any]:
    payload = value.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    return {
        "type": value.get("type"),
        "payload_type": payload.get("type"),
        "role": payload.get("role"),
    }


def original_rollout_signatures(codex_home: pathlib.Path) -> list[dict[str, Any]]:
    rollout_paths = sorted(codex_home.rglob("*.jsonl"))
    if not rollout_paths:
        return []
    lines = read_json_lines(rollout_paths[0])
    return [rollout_payload_signature(line) for line in lines]


def chat_journal_signatures(package_path: pathlib.Path) -> list[dict[str, Any]]:
    lines = read_json_lines(package_path / "journal.ndjson")
    signatures = []
    for line in lines:
        source_transport = line.get("source_transport") or {}
        payload = source_transport.get("payload") or {}
        signatures.append(rollout_payload_signature(payload))
    return signatures


def valid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("valid_line_count") or 0)


def invalid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("invalid_line_count") or 0)


def run_chat_backend_pending_write_crash(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=True,
        )
        first_stderr = ""
        thread_id: str | None = None
        turn_start_response: dict[str, Any] | None = None
        turn_start_error: str | None = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            try:
                turn_start_response = send_turn_start(
                    first_client,
                    3,
                    thread_id,
                    "client-user-message-h05-chat",
                    FIRST_USER_TEXT,
                )
            except Exception as exc:  # process may abort before the full response is read
                turn_start_error = repr(exc)
            crash_exit_code = wait_for_process_exit(first_client, timeout_seconds=60)
        finally:
            first_stderr = close_or_collect(first_client)

        pre_repair = observe_package(chat_root, thread_id, "plain")
        package_path = pathlib.Path(pre_repair["package"])
        pre_repair_signatures = chat_journal_signatures(package_path)
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
            "pre_repair": pre_repair,
            "post_repair": post_repair,
            "pre_repair_summary": pre_repair_summary,
            "post_repair_summary": post_repair_summary,
            "pre_repair_source_signatures": pre_repair_signatures,
            "post_repair_source_signatures": post_repair_signatures,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "second_stderr_tail": second_stderr[-6000:],
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-h05-pending-write-failpoint-crash-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    chat_result = run_chat_backend_pending_write_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
    )

    original_storage = summarize_original_storage(original_home)
    original_signatures = original_rollout_signatures(original_home)
    chat_pre_count = valid_line_count(chat_result["pre_repair"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_repair"], "timeline")
    chat_prefix_signatures = chat_result["post_repair_source_signatures"]
    original_prefix = original_signatures[: len(chat_prefix_signatures)]
    normalized_read = chat_result["normalized_thread_read"]
    normalized_search = chat_result["normalized_thread_search"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-h05-pending-write-failpoint-crash-smoke",
        "matrix_slice": ["H05", "H04-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": FAILPOINT_NEEDLE,
            "boundary": "after one synced canonical journal/timeline item and before the next item in the same append batch",
        },
        "binary_checks": binary_checks,
        "chat_backend_process_aborted_at_failpoint": chat_result["crash_was_signal_abort"],
        "chat_backend_pre_repair_projection_stale": projection_was_stale_before_repair(
            chat_result["pre_repair"]
        ),
        "chat_backend_post_repair_projections_ok": all_projections_repaired(
            chat_result["post_repair"]
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
        "chat_backend_read_did_not_fabricate_user_or_assistant_suffix": (
            not normalized_read.get("contains_first_user_text")
            and not normalized_read.get("contains_assistant_text")
        ),
        "chat_backend_read_marks_interrupted_partial_turn": (
            normalized_read.get("turn_statuses") == ["interrupted"]
            and normalized_read.get("item_count_by_turn") == [0]
        ),
        "chat_backend_search_did_not_fabricate_missing_user_message": (
            normalized_search.get("result_count") == 0
        ),
        "original_source_semantics_used": {
            "recorder_pending_items_drain": "rollout/src/recorder.rs:1545-1550 and 1695-1714",
            "flush_barrier": "thread-store/src/local/live_writer.rs:114-129",
            "interpretation": (
                "Original Codex drains only the successfully written prefix; after process death "
                "there is no in-memory pending suffix to retry. This smoke checks the .chat "
                "backend preserves that prefix/suffix boundary instead of fabricating the suffix."
            ),
        },
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures_after_repair": chat_prefix_signatures,
        "original_normalized_thread_read": original_result["normalized_thread_read"],
        "chat_backend_normalized_thread_read_after_repair": normalized_read,
        "chat_backend_normalized_thread_list_after_repair": chat_result[
            "normalized_thread_list"
        ],
        "chat_backend_normalized_thread_search_after_repair": normalized_search,
        "not_yet_proven": [
            "in-memory pending retry after a recoverable I/O error without process death",
            "H06 crash during archive/delete",
            "process-kill boundaries for command execution, rollback, compaction, and cold transitions",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
        "original_storage_summary": original_storage,
        "original": original_result,
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
            summary["chat_backend_prefix_is_strict_prefix"],
            summary["chat_backend_read_did_not_fabricate_user_or_assistant_suffix"],
            summary["chat_backend_read_marks_interrupted_partial_turn"],
            summary["chat_backend_search_did_not_fabricate_missing_user_message"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow H05 process-abort append-batch slice: the adapted "
        ".chat backend aborts after one matched canonical item is synced and "
        "before the next canonical item in the same append batch. A fresh "
        "app-server repairs projections from the durable prefix, does not append "
        "or fabricate the missing suffix, and exposes the partial turn as "
        "interrupted. It is not full crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/h05-original-response.json", original_result)
    write_json(output_dir / "chat-backend/h05-chat-backend-response.json", chat_result)

    report = f"""# App-Server H05 Pending-Write Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers the H05 boundary where the process aborts during one
canonical append batch: one matched canonical item has already been written and
synced to `journal.ndjson` and `timeline.ndjson`, and a following item from the
same append batch has not been written.

The adapted backend uses the validation failpoint
`{FAILPOINT_ENV}={FAILPOINT_NAME}` with `{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}`.

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- canonical `.chat` prefix survived crash: `{summary['chat_backend_canonical_prefix_survived_crash']}`
- canonical line count stayed fixed during repair: `{summary['chat_backend_timeline_not_extended_by_repair']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- no invalid canonical lines: `{summary['chat_backend_no_invalid_canonical_lines']}`
- prefix matches original normal-run prefix: `{summary['chat_backend_prefix_matches_original_prefix']}`
- prefix is strict, not the full completed turn: `{summary['chat_backend_prefix_is_strict_prefix']}` (`{len(chat_prefix_signatures)}` of `{len(original_signatures)}`)
- fresh read did not fabricate user/assistant suffix: `{summary['chat_backend_read_did_not_fabricate_user_or_assistant_suffix']}`
- fresh read marks the partial turn interrupted: `{summary['chat_backend_read_marks_interrupted_partial_turn']}`
- search did not fabricate the missing user message: `{summary['chat_backend_search_did_not_fabricate_missing_user_message']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/h05-original-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/h05-chat-backend-response.json
```

## Not Yet Proven

This smoke does not prove in-memory pending retry after recoverable I/O failure,
H06 lifecycle crash recovery, process-kill boundaries for command execution,
rollback, compaction, cold transitions, final crash recovery parity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
