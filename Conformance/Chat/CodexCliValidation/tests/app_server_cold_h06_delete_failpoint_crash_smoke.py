#!/usr/bin/env python3
"""Run cold-only delete H06 failpoint crash-recovery smoke.

This source-backed validation covers the cold `.chat.cold/` delete process-abort
boundary. The original backend runs normal delete as the user-visible oracle.
The adapted `.chat` backend starts from a cold-only package, aborts after the
cold package has been removed and before the operation can return success, then
a fresh app-server process must expose the same normalized read/list/search and
retry-delete state as the original oracle.

This is narrow H06 evidence, not final lifecycle crash parity.
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
    close_or_collect,
    compare_fresh_fields,
    complete_turn,
    fresh_lifecycle_observation,
    observe_chat_lifecycle,
    run_original_delete_oracle,
    start_client,
    wait_for_process_exit,
)
from app_server_list_search_archive_smoke import send_thread_delete  # noqa: E402
from app_server_unsubscribe_lifecycle_smoke import send_initialize  # noqa: E402


COLD_DELETE_FAILPOINT = "after-delete-cold-package"

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/delete_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h06_lifecycle_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_h06_lifecycle_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
]


def cold_only_state(state: dict[str, Any]) -> bool:
    return (
        state.get("package_exists") is False
        and state.get("cold_package_exists") is True
    )


def deleted_state(state: dict[str, Any]) -> bool:
    return (
        state.get("package_exists") is False
        and state.get("cold_package_exists") is False
    )


def run_chat_cold_delete_crash(
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
            failpoint=COLD_DELETE_FAILPOINT,
        )
        crash_stderr = ""
        delete_response: dict[str, Any] | None = None
        delete_error: str | None = None
        try:
            initialize_response = send_initialize(crash_client, 100)
            try:
                delete_response = send_thread_delete(crash_client, 101, thread_id)
            except Exception as exc:  # process aborts before response
                delete_error = repr(exc)
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
            include_retry_delete=True,
        )
        post_repair = observe_chat_lifecycle(chat_root, thread_id)
        return {
            "thread_id": thread_id,
            "setup": setup,
            "cold_move": cold_move,
            "before_crash": before_crash,
            "initialize_response": initialize_response,
            "delete_response": delete_response,
            "delete_error": delete_error,
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
    report = f"""# App-Server Cold H06 Delete Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers one cold-only lifecycle process-abort boundary:

```text
delete: cold .chat.cold/ removed, abort before delete operation can return success
```

The original backend runs normal delete as the user-visible oracle. The `.chat`
backend starts from a cold-only package and is aborted with the
`after-delete-cold-package` validation failpoint.

## Result

- passed: `{summary['passed']}`
- fresh normalized fields match original: `{summary['delete']['all_fresh_normalized_fields_equal']}`
- process aborted at failpoint: `{summary['delete']['chat_backend_process_aborted_at_failpoint']}`
- started from cold-only package: `{summary['delete']['chat_backend_started_from_cold_only']}`
- cold package removed before fresh read/list/search: `{summary['delete']['chat_backend_cold_package_removed_before_fresh_repair']}`
- package still removed after fresh read/list/search: `{summary['delete']['chat_backend_package_removed_after_fresh_repair']}`

## Comparison Booleans

```json
{json.dumps(summary['delete']['comparisons'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/delete-oracle.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-delete-crash.json
```

## Not Yet Proven

This smoke does not prove every lifecycle filesystem boundary, descendant
archive/unarchive/delete ordering under process kill, background cold-history
compression lifecycle, CLI-level lifecycle crash parity, complete data fidelity,
complete crash recovery parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-cold-h06-delete-failpoint-crash-smoke-"
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
    original_delete = run_original_delete_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        run_root / "original-delete" / "workspace",
        run_root / "original-delete" / "codex-home",
    )

    chat_root = run_root / "chat-cold-delete" / "chat-store"
    chat_root.mkdir(parents=True, exist_ok=True)
    chat_delete = run_chat_cold_delete_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        run_root / "chat-cold-delete" / "workspace",
        run_root / "chat-cold-delete" / "codex-home",
        chat_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
        ],
    )

    delete_comparisons = compare_fresh_fields(
        original_delete,
        chat_delete,
        [
            "normalized_active_list",
            "normalized_archived_list",
            "normalized_active_search",
            "normalized_archived_search",
            "normalized_read_error",
            "normalized_retry_delete_error",
        ],
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-h06-delete-failpoint-crash-smoke",
        "matrix_slice": ["H06", "H03-adjacent", "L07-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoints": {
            "delete": COLD_DELETE_FAILPOINT,
        },
        "binary_checks": binary_checks,
        "delete": {
            "comparisons": delete_comparisons,
            "all_fresh_normalized_fields_equal": all(delete_comparisons.values()),
            "chat_backend_process_aborted_at_failpoint": chat_delete[
                "crash_was_signal_abort"
            ],
            "chat_backend_cold_move_succeeded": chat_delete["cold_move"].get("moved")
            is True,
            "chat_backend_started_from_cold_only": cold_only_state(
                chat_delete["before_crash"]
            ),
            "chat_backend_cold_package_removed_before_fresh_repair": deleted_state(
                chat_delete["pre_repair"]
            ),
            "chat_backend_package_removed_after_fresh_repair": deleted_state(
                chat_delete["post_repair"]
            ),
            "original": {
                key: original_delete["fresh"][key]
                for key in delete_comparisons.keys()
            },
            "chat_backend": {
                key: chat_delete["fresh"][key] for key in delete_comparisons.keys()
            },
        },
        "not_yet_proven": [
            "every lifecycle filesystem operation boundary",
            "archive/unarchive/delete descendant ordering under process kill",
            "background cold-history compression worker lifecycle crash",
            "CLI-level lifecycle crash user-indistinguishability",
            "complete crash recovery parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
        "original_delete": original_delete,
        "chat_delete": chat_delete,
    }
    summary["passed"] = all(
        [
            summary["delete"]["all_fresh_normalized_fields_equal"],
            summary["delete"]["chat_backend_process_aborted_at_failpoint"],
            summary["delete"]["chat_backend_cold_move_succeeded"],
            summary["delete"]["chat_backend_started_from_cold_only"],
            summary["delete"]["chat_backend_cold_package_removed_before_fresh_repair"],
            summary["delete"]["chat_backend_package_removed_after_fresh_repair"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow cold-only H06 delete process-abort slice: a "
        "cold-only .chat.cold package can be removed, the process can abort "
        "before delete returns success, and a fresh app-server read/list/search/"
        "retry-delete observation matches the original backend normalized "
        "oracle. It is not full lifecycle crash parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/delete-oracle.json", original_delete)
    write_json(output_dir / "chat-backend/cold-delete-crash.json", chat_delete)
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
