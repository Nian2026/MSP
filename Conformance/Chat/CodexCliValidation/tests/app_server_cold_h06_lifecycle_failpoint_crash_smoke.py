#!/usr/bin/env python3
"""Run cold-package H06 lifecycle failpoint crash-recovery smoke.

This source-backed validation combines the cold `.chat.cold/` representation with
the H06 lifecycle failpoint. The original backend runs normal archive/unarchive
operations as the user-visible oracle. The adapted `.chat` backend starts the
same operation from a cold-only package, aborts after cold materialization and
manifest write but before metadata-index write, then a fresh app-server process
must expose the same normalized read/list/search state as the original oracle.

This is narrow cold-lifecycle process-abort evidence, not final lifecycle crash
parity.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_package_smoke import move_plain_to_cold  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    MockResponsesServer,
    ensure_binary,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_h06_lifecycle_failpoint_crash_smoke import (  # noqa: E402
    ARCHIVE_FAILPOINT,
    close_or_collect,
    compare_fresh_fields,
    complete_turn,
    fresh_lifecycle_observation,
    observe_chat_lifecycle,
    run_original_archive_oracle,
    run_original_unarchive_oracle,
    start_client,
    wait_for_process_exit,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    send_thread_archive,
    send_thread_unarchive,
)
from app_server_unsubscribe_lifecycle_smoke import send_initialize  # noqa: E402


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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/archive_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/unarchive_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h06_lifecycle_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_archive_lifecycle_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
]


def cold_only_state(state: dict[str, Any]) -> bool:
    return (
        state.get("package_exists") is False
        and state.get("cold_package_exists") is True
    )


def materialized_plain_state(state: dict[str, Any]) -> bool:
    return (
        state.get("package_exists") is True
        and state.get("cold_package_exists") is False
    )


def run_chat_cold_archive_crash(
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
        setup_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        setup_stderr = ""
        try:
            thread_id, setup = complete_turn(setup_client, workspace, 1)
        finally:
            setup_stderr = close_or_collect(setup_client)

        cold_move = move_plain_to_cold(chat_root, thread_id)
        before_crash = observe_chat_lifecycle(chat_root, thread_id)

        crash_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=ARCHIVE_FAILPOINT,
        )
        crash_stderr = ""
        archive_response: dict[str, Any] | None = None
        archive_error: str | None = None
        try:
            initialize_response = send_initialize(crash_client, 100)
            try:
                archive_response = send_thread_archive(crash_client, 101, thread_id)
            except Exception as exc:  # process aborts before response
                archive_error = repr(exc)
            crash_exit_code = wait_for_process_exit(crash_client, timeout_seconds=30)
        finally:
            crash_stderr = close_or_collect(crash_client)

        pre_repair = observe_chat_lifecycle(chat_root, thread_id)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
            include_retry_delete=False,
        )
        post_repair = observe_chat_lifecycle(chat_root, thread_id)
        return {
            "thread_id": thread_id,
            "setup": setup,
            "cold_move": cold_move,
            "before_crash": before_crash,
            "initialize_response": initialize_response,
            "archive_response": archive_response,
            "archive_error": archive_error,
            "crash_exit_code": crash_exit_code,
            "crash_was_signal_abort": isinstance(crash_exit_code, int)
            and crash_exit_code < 0,
            "pre_repair": pre_repair,
            "fresh": fresh,
            "post_repair": post_repair,
            "mock_server_summary": mock_server.summary(),
            "setup_stderr_tail": setup_stderr[-6000:],
            "crash_stderr_tail": crash_stderr[-6000:],
        }


def run_chat_cold_unarchive_crash(
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
        setup_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        setup_stderr = ""
        try:
            thread_id, setup = complete_turn(setup_client, workspace, 1)
            archive_response = send_thread_archive(setup_client, 10, thread_id)
            archive_notification = setup_client.receive_until_method(
                "thread/archived", timeout_seconds=30
            )
        finally:
            setup_stderr = close_or_collect(setup_client)

        archived_plain = observe_chat_lifecycle(chat_root, thread_id)
        cold_move = move_plain_to_cold(chat_root, thread_id)
        before_crash = observe_chat_lifecycle(chat_root, thread_id)

        crash_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=ARCHIVE_FAILPOINT,
        )
        crash_stderr = ""
        unarchive_response: dict[str, Any] | None = None
        unarchive_error: str | None = None
        try:
            initialize_response = send_initialize(crash_client, 100)
            try:
                unarchive_response = send_thread_unarchive(crash_client, 101, thread_id)
            except Exception as exc:  # process aborts before response
                unarchive_error = repr(exc)
            crash_exit_code = wait_for_process_exit(crash_client, timeout_seconds=30)
        finally:
            crash_stderr = close_or_collect(crash_client)

        pre_repair = observe_chat_lifecycle(chat_root, thread_id)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
            include_retry_delete=False,
        )
        post_repair = observe_chat_lifecycle(chat_root, thread_id)
        return {
            "thread_id": thread_id,
            "setup": setup,
            "archive_response": archive_response,
            "archive_notification": archive_notification,
            "archived_plain": archived_plain,
            "cold_move": cold_move,
            "before_crash": before_crash,
            "initialize_response": initialize_response,
            "unarchive_response": unarchive_response,
            "unarchive_error": unarchive_error,
            "crash_exit_code": crash_exit_code,
            "crash_was_signal_abort": isinstance(crash_exit_code, int)
            and crash_exit_code < 0,
            "pre_repair": pre_repair,
            "fresh": fresh,
            "post_repair": post_repair,
            "mock_server_summary": mock_server.summary(),
            "setup_stderr_tail": setup_stderr[-6000:],
            "crash_stderr_tail": crash_stderr[-6000:],
        }


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    report = f"""# App-Server Cold H06 Lifecycle Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers two cold-package lifecycle process-abort boundaries:

```text
archive: cold .chat.cold/ materialized to plain .chat/, manifest archived, abort before metadata index write
unarchive: cold archived .chat.cold/ materialized to plain .chat/, manifest active, abort before metadata index write
```

The original backend runs normal archive/unarchive operations as the
user-visible oracle. The `.chat` backend starts from a cold-only package and is
aborted with the existing `after-lifecycle-manifest-before-index` failpoint.

## Result

- passed: `{summary['passed']}`
- archive fresh normalized fields match original: `{summary['archive']['all_fresh_normalized_fields_equal']}`
- archive process aborted at failpoint: `{summary['archive']['chat_backend_process_aborted_at_failpoint']}`
- archive started from cold-only package: `{summary['archive']['chat_backend_started_from_cold_only']}`
- archive materialized before abort: `{summary['archive']['chat_backend_materialized_before_abort']}`
- archive pre-repair state was manifest archived + index active: `{summary['archive']['chat_backend_pre_repair_manifest_archived_index_active']}`
- archive index repaired after fresh read: `{summary['archive']['chat_backend_index_repaired_after_fresh_read']}`
- unarchive fresh normalized fields match original: `{summary['unarchive']['all_fresh_normalized_fields_equal']}`
- unarchive process aborted at failpoint: `{summary['unarchive']['chat_backend_process_aborted_at_failpoint']}`
- unarchive started from archived plain package before cold move: `{summary['unarchive']['chat_backend_archived_before_cold_move']}`
- unarchive started from cold-only package: `{summary['unarchive']['chat_backend_started_from_cold_only']}`
- unarchive materialized before abort: `{summary['unarchive']['chat_backend_materialized_before_abort']}`
- unarchive pre-repair state was manifest active + index archived: `{summary['unarchive']['chat_backend_pre_repair_manifest_active_index_archived']}`
- unarchive index repaired after fresh read: `{summary['unarchive']['chat_backend_index_repaired_after_fresh_read']}`

## Comparison Booleans

```json
{json.dumps({'archive': summary['archive']['comparisons'], 'unarchive': summary['unarchive']['comparisons']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/archive-oracle.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-archive-crash.json
{output_dir.relative_to(VALIDATION_DIR)}/original/unarchive-oracle.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-unarchive-crash.json
```

## Not Yet Proven

This smoke does not prove cold-only delete process-kill transition, every
lifecycle filesystem boundary, descendant archive/unarchive/delete ordering
under process kill, background cold-history compression lifecycle, CLI-level
lifecycle crash parity, complete data fidelity, complete crash recovery parity,
or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-cold-h06-lifecycle-failpoint-crash-smoke-"
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
    original_archive = run_original_archive_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        run_root / "original-archive" / "workspace",
        run_root / "original-archive" / "codex-home",
    )
    original_unarchive = run_original_unarchive_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        run_root / "original-unarchive" / "workspace",
        run_root / "original-unarchive" / "codex-home",
    )

    archive_chat_root = run_root / "chat-cold-archive" / "chat-store"
    unarchive_chat_root = run_root / "chat-cold-unarchive" / "chat-store"
    archive_chat_root.mkdir(parents=True, exist_ok=True)
    unarchive_chat_root.mkdir(parents=True, exist_ok=True)
    chat_archive = run_chat_cold_archive_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        run_root / "chat-cold-archive" / "workspace",
        run_root / "chat-cold-archive" / "codex-home",
        archive_chat_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{archive_chat_root}" }}',
        ],
    )
    chat_unarchive = run_chat_cold_unarchive_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        run_root / "chat-cold-unarchive" / "workspace",
        run_root / "chat-cold-unarchive" / "codex-home",
        unarchive_chat_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{unarchive_chat_root}" }}',
        ],
    )

    archive_comparisons = compare_fresh_fields(
        original_archive,
        chat_archive,
        [
            "normalized_active_list",
            "normalized_archived_list",
            "normalized_active_search",
            "normalized_archived_search",
            "normalized_read_error",
        ],
    )
    unarchive_comparisons = compare_fresh_fields(
        original_unarchive,
        chat_unarchive,
        [
            "normalized_active_list",
            "normalized_archived_list",
            "normalized_active_search",
            "normalized_archived_search",
            "normalized_read_error",
            "normalized_read_thread",
        ],
    )

    archive_pre_repair_stale = (
        chat_archive["pre_repair"]["manifest_archived"] is True
        and chat_archive["pre_repair"]["index_archived_at"] is None
    )
    archive_index_repaired = (
        chat_archive["post_repair"]["manifest_archived"] is True
        and chat_archive["post_repair"]["index_archived_at"] is not None
    )
    unarchive_archived_before_cold_move = (
        chat_unarchive["archived_plain"]["manifest_archived"] is True
        and chat_unarchive["archived_plain"]["index_archived_at"] is not None
    )
    unarchive_pre_repair_stale = (
        chat_unarchive["pre_repair"]["manifest_archived"] is False
        and chat_unarchive["pre_repair"]["index_archived_at"] is not None
    )
    unarchive_index_repaired = (
        chat_unarchive["post_repair"]["manifest_archived"] is False
        and chat_unarchive["post_repair"]["index_archived_at"] is None
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-h06-lifecycle-failpoint-crash-smoke",
        "matrix_slice": ["H06", "H02-adjacent", "L05-adjacent", "L06-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoints": {
            "archive": ARCHIVE_FAILPOINT,
            "unarchive": ARCHIVE_FAILPOINT,
        },
        "binary_checks": binary_checks,
        "archive": {
            "comparisons": archive_comparisons,
            "all_fresh_normalized_fields_equal": all(archive_comparisons.values()),
            "chat_backend_process_aborted_at_failpoint": chat_archive[
                "crash_was_signal_abort"
            ],
            "chat_backend_cold_move_succeeded": chat_archive["cold_move"].get("moved")
            is True,
            "chat_backend_started_from_cold_only": cold_only_state(
                chat_archive["before_crash"]
            ),
            "chat_backend_materialized_before_abort": materialized_plain_state(
                chat_archive["pre_repair"]
            ),
            "chat_backend_pre_repair_manifest_archived_index_active": archive_pre_repair_stale,
            "chat_backend_index_repaired_after_fresh_read": archive_index_repaired,
            "original": {
                key: original_archive["fresh"][key]
                for key in archive_comparisons.keys()
            },
            "chat_backend": {
                key: chat_archive["fresh"][key] for key in archive_comparisons.keys()
            },
        },
        "unarchive": {
            "comparisons": unarchive_comparisons,
            "all_fresh_normalized_fields_equal": all(unarchive_comparisons.values()),
            "chat_backend_process_aborted_at_failpoint": chat_unarchive[
                "crash_was_signal_abort"
            ],
            "chat_backend_archived_before_cold_move": unarchive_archived_before_cold_move,
            "chat_backend_cold_move_succeeded": chat_unarchive["cold_move"].get("moved")
            is True,
            "chat_backend_started_from_cold_only": cold_only_state(
                chat_unarchive["before_crash"]
            ),
            "chat_backend_materialized_before_abort": materialized_plain_state(
                chat_unarchive["pre_repair"]
            ),
            "chat_backend_pre_repair_manifest_active_index_archived": unarchive_pre_repair_stale,
            "chat_backend_index_repaired_after_fresh_read": unarchive_index_repaired,
            "original": {
                key: original_unarchive["fresh"][key]
                for key in unarchive_comparisons.keys()
            },
            "chat_backend": {
                key: chat_unarchive["fresh"][key]
                for key in unarchive_comparisons.keys()
            },
        },
        "not_yet_proven": [
            "cold-only delete process-kill transition",
            "every lifecycle filesystem operation boundary",
            "archive/unarchive/delete descendant ordering under process kill",
            "background cold-history compression worker lifecycle crash",
            "CLI-level lifecycle crash user-indistinguishability",
            "complete crash recovery parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
        "original_archive": original_archive,
        "chat_archive": chat_archive,
        "original_unarchive": original_unarchive,
        "chat_unarchive": chat_unarchive,
    }
    summary["passed"] = all(
        [
            summary["archive"]["all_fresh_normalized_fields_equal"],
            summary["archive"]["chat_backend_process_aborted_at_failpoint"],
            summary["archive"]["chat_backend_cold_move_succeeded"],
            summary["archive"]["chat_backend_started_from_cold_only"],
            summary["archive"]["chat_backend_materialized_before_abort"],
            summary["archive"]["chat_backend_pre_repair_manifest_archived_index_active"],
            summary["archive"]["chat_backend_index_repaired_after_fresh_read"],
            summary["unarchive"]["all_fresh_normalized_fields_equal"],
            summary["unarchive"]["chat_backend_process_aborted_at_failpoint"],
            summary["unarchive"]["chat_backend_archived_before_cold_move"],
            summary["unarchive"]["chat_backend_cold_move_succeeded"],
            summary["unarchive"]["chat_backend_started_from_cold_only"],
            summary["unarchive"]["chat_backend_materialized_before_abort"],
            summary["unarchive"]["chat_backend_pre_repair_manifest_active_index_archived"],
            summary["unarchive"]["chat_backend_index_repaired_after_fresh_read"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow cold H06 lifecycle process-abort slice: a "
        "cold-only .chat.cold package can be materialized to plain .chat "
        "during archive/unarchive, abort after manifest mutation and before "
        "metadata-index update, and a fresh app-server read/list/search repair "
        "matches the original backend normalized oracle. It is not full cold "
        "lifecycle crash parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/archive-oracle.json", original_archive)
    write_json(output_dir / "chat-backend/cold-archive-crash.json", chat_archive)
    write_json(output_dir / "original/unarchive-oracle.json", original_unarchive)
    write_json(output_dir / "chat-backend/cold-unarchive-crash.json", chat_unarchive)
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
