#!/usr/bin/env python3
"""Run request_permissions later-batch task-complete failpoint crash smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend completes the existing two-turn request_permissions
scenario as the oracle. The adapted `.chat` backend uses a validation failpoint
that aborts after the second turn's final assistant answer and `task_complete`
source event are synced to canonical `journal.ndjson` and `timeline.ndjson`,
but before standard projections are rebuilt.

This proves only a narrow later-batch approval crash boundary. It is not a
final T06, H05, crash-recovery, or user-indistinguishability claim.
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

import app_server_request_permissions_later_batch_failpoint_crash_smoke as later_crash  # noqa: E402
from app_server_cold_package_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    utc_now_iso,
    write_json,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    projection_was_stale_before_repair,
)
from app_server_request_permissions_approval_output_failpoint_smoke import (  # noqa: E402
    invalid_line_count,
    original_rollout_signatures,
    package_contains_approval_output,
    valid_line_count,
)
from app_server_request_permissions_later_batch_recoverable_retry_smoke import (  # noqa: E402
    fresh_read_list_search,
    package_contains_first_final,
    package_contains_second_final,
    package_contains_session_command_output,
    signature_contains_call,
    signature_count_for_call_output,
)
from app_server_request_permissions_smoke import (  # noqa: E402
    CALL_ID,
    COMMAND_CALL_ID,
    COMMAND_OUTPUT_TEXT,
    FIRST_FINAL_TEXT,
    SECOND_FINAL_TEXT,
    command_items_from_thread_read,
    run_tree as run_normal_request_permissions_tree,
    summarize_original_rollouts,
)


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = f'"last_agent_message":"{SECOND_FINAL_TEXT}"'

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_later_batch_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_later_batch_recoverable_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_output_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def thread_id_from_start_response(response: dict[str, Any]) -> str | None:
    return (((response.get("result") or {}).get("thread") or {}).get("id"))


def source_signature_count(
    signatures: list[dict[str, Any]],
    item_type: str,
    payload_type: str,
) -> int:
    return sum(
        1
        for signature in signatures
        if signature.get("type") == item_type
        and signature.get("payload_type") == payload_type
    )


def package_text_contains(summary: dict[str, Any], text: str) -> bool:
    for package in summary.get("packages") or []:
        package_path = pathlib.Path(package["package"])
        for path in [package_path / "timeline.ndjson", package_path / "journal.ndjson"]:
            if path.exists() and text in path.read_text():
                return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-request-permissions-later-batch-task-complete-"
            "failpoint-crash-smoke-"
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
    original_thread_id = thread_id_from_start_response(
        original_result["thread_start_response"]
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
    for path in [chat_workspace, chat_home, chat_root]:
        path.mkdir(parents=True, exist_ok=True)
    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]

    old_needle = later_crash.FAILPOINT_NEEDLE
    later_crash.FAILPOINT_NEEDLE = FAILPOINT_NEEDLE
    try:
        chat_result = later_crash.run_chat_backend_later_batch_crash(
            CHAT_BACKEND_CODEX_RS / "target/debug/codex",
            chat_workspace,
            chat_home,
            chat_root,
            chat_config,
        )
    finally:
        later_crash.FAILPOINT_NEEDLE = old_needle

    chat_fresh_result = fresh_read_list_search(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_config,
        chat_result["thread_id"],
    )

    original_rollout_summary = summarize_original_rollouts(original_home)
    original_signatures = original_rollout_signatures(original_home)
    chat_signatures = chat_result["post_repair_source_signatures"]
    post_timeline = chat_result["post_repair_timeline_summary"]
    chat_pre_count = valid_line_count(chat_result["pre_repair"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_repair"], "timeline")
    workspace_effect = chat_result["workspace_effect"]
    final_read_command_items = command_items_from_thread_read(
        chat_result["thread_read_response"],
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": (
            "app-server-request-permissions-later-batch-task-complete-"
            "failpoint-crash-smoke"
        ),
        "matrix_slice": ["T06", "T01-adjacent", "H05", "H04-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": FAILPOINT_NEEDLE,
            "boundary": (
                "after the second request_permissions follow-up final answer "
                "and task_complete source payload are canonical, before "
                "projection rebuild"
            ),
        },
        "binary_checks": binary_checks,
        "chat_backend_process_aborted_at_failpoint": chat_result[
            "crash_was_signal_abort"
        ],
        "chat_backend_pre_repair_projection_stale": projection_was_stale_before_repair(
            chat_result["pre_repair"],
        ),
        "chat_backend_post_repair_projections_ok": all_projections_repaired(
            chat_result["post_repair"],
        ),
        "chat_backend_canonical_full_history_survived_crash": (
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
        "chat_backend_retains_second_task_complete_payload": package_text_contains(
            post_timeline,
            FAILPOINT_NEEDLE,
        ),
        "chat_backend_retains_two_task_complete_events": (
            source_signature_count(chat_signatures, "event_msg", "task_complete") == 2
        ),
        "chat_backend_command_output_not_duplicated": (
            signature_count_for_call_output(chat_signatures, COMMAND_CALL_ID) == 1
        ),
        "chat_backend_approval_output_not_duplicated": (
            signature_count_for_call_output(chat_signatures, CALL_ID) == 1
        ),
        "fresh_normalized_thread_read_visible_matches_original": (
            chat_fresh_result["normalized_thread_read_visible"]
            == original_fresh_result["normalized_thread_read_visible"]
        ),
        "fresh_normalized_thread_read_command_items_match_original": (
            chat_fresh_result["normalized_thread_read_command_items"]
            == original_fresh_result["normalized_thread_read_command_items"]
        ),
        "fresh_normalized_thread_list_matches_original": (
            chat_fresh_result["normalized_thread_list"]
            == original_fresh_result["normalized_thread_list"]
        ),
        "fresh_normalized_thread_search_matches_original": (
            chat_fresh_result["normalized_thread_search"]
            == original_fresh_result["normalized_thread_search"]
        ),
        "fresh_read_retains_completed_two_turns": (
            chat_fresh_result["normalized_thread_read_visible"].get("turn_statuses")
            == ["completed", "completed"]
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
        "chat_backend_timeline_line_count_before_repair": chat_pre_count,
        "chat_backend_timeline_line_count_after_repair": chat_post_count,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures_after_repair": chat_signatures,
        "original_rollout_summary": original_rollout_summary,
        "original_storage_summary": original_result["original_storage_summary"],
        "chat_backend_storage_summary": chat_result["post_repair_summary"],
        "original_fresh_normalized_thread_read_visible": original_fresh_result[
            "normalized_thread_read_visible"
        ],
        "chat_backend_fresh_normalized_thread_read_visible": chat_fresh_result[
            "normalized_thread_read_visible"
        ],
        "original_fresh_normalized_thread_read_command_items": original_fresh_result[
            "normalized_thread_read_command_items"
        ],
        "chat_backend_fresh_normalized_thread_read_command_items": chat_fresh_result[
            "normalized_thread_read_command_items"
        ],
        "chat_backend_repair_read_command_items": final_read_command_items,
        "original_fresh_normalized_thread_list": original_fresh_result[
            "normalized_thread_list"
        ],
        "chat_backend_fresh_normalized_thread_list": chat_fresh_result[
            "normalized_thread_list"
        ],
        "original_fresh_normalized_thread_search": original_fresh_result[
            "normalized_thread_search"
        ],
        "chat_backend_fresh_normalized_thread_search": chat_fresh_result[
            "normalized_thread_search"
        ],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "chat_backend_post_repair_timeline_summary": post_timeline,
        "not_yet_proven": [
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
        "chat_backend_fresh": chat_fresh_result,
    }
    summary["passed"] = all(
        [
            summary["chat_backend_process_aborted_at_failpoint"],
            summary["chat_backend_pre_repair_projection_stale"],
            summary["chat_backend_post_repair_projections_ok"],
            summary["chat_backend_canonical_full_history_survived_crash"],
            summary["chat_backend_timeline_not_extended_by_repair"],
            summary["chat_backend_no_invalid_canonical_lines"],
            summary["chat_backend_line_count_matches_original"],
            summary["chat_backend_source_signatures_match_original"],
            summary["chat_backend_retains_approval_output"],
            summary["chat_backend_retains_first_final_answer"],
            summary["chat_backend_retains_session_command_call"],
            summary["chat_backend_retains_session_command_output"],
            summary["chat_backend_retains_second_final_answer"],
            summary["chat_backend_retains_second_task_complete_payload"],
            summary["chat_backend_retains_two_task_complete_events"],
            summary["chat_backend_command_output_not_duplicated"],
            summary["chat_backend_approval_output_not_duplicated"],
            summary["fresh_normalized_thread_read_visible_matches_original"],
            summary["fresh_normalized_thread_read_command_items_match_original"],
            summary["fresh_normalized_thread_list_matches_original"],
            summary["fresh_normalized_thread_search_matches_original"],
            summary["fresh_read_retains_completed_two_turns"],
            summary["mock_server_summary_matches_original"],
            summary["workspace_effect_matches_original"],
            summary["chat_backend_workspace_side_effect_exists"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow app-server request_permissions later-batch "
        "task-complete process-abort slice: after the standalone approval "
        "output, first final answer, later session-grant command output, "
        "second final answer, and second task_complete payload are canonical, "
        "the adapted .chat backend aborts before projection rebuild, repairs "
        "projections on fresh read, keeps canonical line counts and source "
        "signatures equal to the completed original run, avoids duplicate "
        "approval/command outputs, and matches fresh original read/list/search "
        "for this slice. It is not final approval crash recovery parity."
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
        output_dir / "chat-backend/request-permissions-later-batch-task-complete-crash-response.json",
        chat_result,
    )
    write_json(
        output_dir / "chat-backend/request-permissions-later-batch-task-complete-fresh-response.json",
        chat_fresh_result,
    )

    report = f"""# App-Server Request Permissions Later-Batch Task-Complete Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow later-batch T06/H05 boundary. The adapted backend
first persists the standalone `request_permissions` approval output and first
assistant answer, then completes the following session-grant command turn and
aborts after the second turn `task_complete` source payload is synced to
`journal.ndjson` and `timeline.ndjson`, but before projection rebuild.

The adapted backend uses:

```text
{FAILPOINT_ENV}={FAILPOINT_NAME}
{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}
```

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- canonical `.chat` full history survived crash: `{summary['chat_backend_canonical_full_history_survived_crash']}`
- canonical line count stayed fixed during repair: `{summary['chat_backend_timeline_not_extended_by_repair']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- line count matches completed original: `{summary['chat_backend_line_count_matches_original']}` (`{len(chat_signatures)}` == `{len(original_signatures)}`)
- source signatures match completed original: `{summary['chat_backend_source_signatures_match_original']}`
- approval output retained/not duplicated: `{summary['chat_backend_retains_approval_output']}` / `{summary['chat_backend_approval_output_not_duplicated']}`
- first final answer retained: `{summary['chat_backend_retains_first_final_answer']}`
- session command call/output retained: `{summary['chat_backend_retains_session_command_call']}` / `{summary['chat_backend_retains_session_command_output']}`
- session command output not duplicated: `{summary['chat_backend_command_output_not_duplicated']}`
- second final answer retained: `{summary['chat_backend_retains_second_final_answer']}`
- second task_complete payload retained: `{summary['chat_backend_retains_second_task_complete_payload']}`
- two task_complete source events retained: `{summary['chat_backend_retains_two_task_complete_events']}`
- fresh read visible state matches original: `{summary['fresh_normalized_thread_read_visible_matches_original']}`
- fresh command item projection matches original: `{summary['fresh_normalized_thread_read_command_items_match_original']}`
- fresh thread/list matches original: `{summary['fresh_normalized_thread_list_matches_original']}`
- fresh thread/search matches original: `{summary['fresh_normalized_thread_search_matches_original']}`
- fresh read retains two completed turns: `{summary['fresh_read_retains_completed_two_turns']}`
- mock model request summary matches original: `{summary['mock_server_summary_matches_original']}`
- workspace side effect matches original: `{summary['workspace_effect_matches_original']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-normal-response.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-fresh-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-later-batch-task-complete-crash-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-later-batch-task-complete-fresh-response.json
```

## Not Yet Proven

This smoke does not prove broader approval crash variants, arbitrary real
filesystem I/O failures outside validation failpoints, background compression
crash recovery, true process-kill rollback/lifecycle parity, final crash
recovery parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
