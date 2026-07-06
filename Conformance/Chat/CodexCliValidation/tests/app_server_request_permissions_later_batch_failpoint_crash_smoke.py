#!/usr/bin/env python3
"""Run request_permissions later-batch failpoint crash smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend completes the existing two-turn request_permissions
scenario as the oracle. The adapted `.chat` backend first persists the
request_permissions approval output, completes the first turn, then starts the
session-grant command turn and aborts after the later shell command
`function_call_output` is synced to canonical `journal.ndjson` and
`timeline.ndjson`, but before standard projections are rebuilt.

This proves only a narrow later-batch approval crash boundary. It is not a
final T06, H05, crash-recovery, or user-indistinguishability claim.
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
    normalize_thread_search_response,
    send_thread_search,
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
    send_turn_start,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
    close_or_collect,
    projection_was_stale_before_repair,
    wait_for_process_exit,
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
    REQUEST_REASON,
    SECOND_FINAL_TEXT,
    SECOND_USER_TEXT,
    USER_TEXT,
    RequestPermissionsResponsesServer,
    first_requested_write_path,
    normalize_thread_read_visible,
    run_tree as run_normal_request_permissions_tree,
    summarize_chat_timeline,
    summarize_original_rollouts,
    write_request_permissions_config,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "Exit code: 0"

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_approval_output_failpoint_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_approval_output_recoverable_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_pending_write_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_output_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
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


def chat_package_for(observation: dict[str, Any]) -> pathlib.Path:
    package = observation.get("package")
    if not package:
        raise RuntimeError("expected observed .chat package path")
    return pathlib.Path(package)


def package_contains_first_final(summary: dict[str, Any]) -> bool:
    return any(
        FIRST_FINAL_TEXT in json.dumps(package, ensure_ascii=False)
        for package in summary.get("packages") or []
    ) or any(
        FIRST_FINAL_TEXT in path.read_text()
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


def package_omits_second_final(summary: dict[str, Any]) -> bool:
    return not any(
        SECOND_FINAL_TEXT in path.read_text()
        for package in summary.get("packages") or []
        for path in [
            pathlib.Path(package["package"]) / "timeline.ndjson",
            pathlib.Path(package["package"]) / "journal.ndjson",
        ]
        if path.exists()
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


def run_chat_backend_later_batch_crash(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with RequestPermissionsResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=True,
        )
        first_stderr = ""
        second_turn_start_response: dict[str, Any] | None = None
        second_turn_start_error: str | None = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_id, turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-request-permissions-later-batch-crash",
                USER_TEXT,
            )
            permission_request = first_client.receive_until_method(
                "item/permissions/requestApproval",
                timeout_seconds=30,
            )
            granted_write_path = first_requested_write_path(permission_request)
            first_client.send(
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
            first_turn_completed_notification = first_client.receive_until_method(
                "turn/completed",
                timeout_seconds=90,
            )
            try:
                _, second_turn_start_response = send_turn_start(
                    first_client,
                    4,
                    thread_id,
                    "client-user-request-permissions-session-command-crash",
                    SECOND_USER_TEXT,
                )
            except Exception as exc:
                second_turn_start_error = repr(exc)
            crash_exit_code = wait_for_process_exit(first_client, timeout_seconds=60)
        finally:
            first_stderr = close_or_collect(first_client)

        pre_repair = observe_package(chat_root, thread_id, "plain")
        package_path = chat_package_for(pre_repair)
        pre_repair_signatures = chat_journal_signatures(package_path)
        pre_repair_summary = summarize_chat_packages(chat_root)
        pre_repair_timeline = summarize_chat_timeline(chat_root)

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
            post_repair_timeline = summarize_chat_timeline(chat_root)
        finally:
            second_stderr = close_or_collect(second_client)

    return {
        "thread_id": thread_id,
        "turn_id": turn_id,
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "permission_request": permission_request,
        "first_turn_completed_notification": first_turn_completed_notification,
        "second_turn_start_response": second_turn_start_response,
        "second_turn_start_error": second_turn_start_error,
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
        "normalized_thread_read_visible": normalize_thread_read_visible(read_response),
        "thread_read_serialized": json.dumps(read_response, ensure_ascii=False),
        "pre_repair": pre_repair,
        "post_repair": post_repair,
        "pre_repair_summary": pre_repair_summary,
        "post_repair_summary": post_repair_summary,
        "pre_repair_timeline_summary": pre_repair_timeline,
        "post_repair_timeline_summary": post_repair_timeline,
        "pre_repair_source_signatures": pre_repair_signatures,
        "post_repair_source_signatures": post_repair_signatures,
        "mock_server_summary": mock_server.summary(),
        "workspace_effect": {
            "session_grant_file_exists": (workspace / "session-grant.txt").exists(),
            "session_grant_file_text": (workspace / "session-grant.txt").read_text()
            if (workspace / "session-grant.txt").exists()
            else None,
        },
        "second_stderr_tail": second_stderr[-6000:],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-request-permissions-later-batch-failpoint-crash-smoke-"
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
    chat_workspace = run_root / "chat-backend" / "workspace"
    chat_home = run_root / "chat-backend" / "codex-home"
    chat_root = run_root / "chat-backend" / "chat-store"
    for path in [chat_workspace, chat_home, chat_root]:
        path.mkdir(parents=True, exist_ok=True)
    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]
    chat_result = run_chat_backend_later_batch_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
    )

    original_storage = original_result["original_storage_summary"]
    original_rollout_summary = summarize_original_rollouts(
        pathlib.Path(original_result["codex_home"]),
    )
    original_signatures = original_rollout_signatures(pathlib.Path(original_result["codex_home"]))
    chat_pre_count = valid_line_count(chat_result["pre_repair"], "timeline")
    chat_post_count = valid_line_count(chat_result["post_repair"], "timeline")
    chat_prefix_signatures = chat_result["post_repair_source_signatures"]
    original_prefix = original_signatures[: len(chat_prefix_signatures)]
    post_timeline = chat_result["post_repair_timeline_summary"]
    visible = chat_result["normalized_thread_read_visible"]
    read_serialized = chat_result["thread_read_serialized"]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-request-permissions-later-batch-failpoint-crash-smoke",
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
                "after request_permissions approval has completed and a later "
                "session-grant shell command function_call_output is synced to "
                "journal/timeline, before projection rebuild"
            ),
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
        "chat_backend_retains_approval_output": package_contains_approval_output(
            post_timeline,
        ),
        "chat_backend_retains_first_final_answer": package_contains_first_final(
            post_timeline,
        ),
        "chat_backend_retains_session_command_call": signature_contains_call(
            chat_prefix_signatures,
            COMMAND_CALL_ID,
        ),
        "chat_backend_retains_session_command_output": package_contains_session_command_output(
            post_timeline,
        ),
        "chat_backend_command_output_not_duplicated": (
            signature_count_for_call_output(chat_prefix_signatures, COMMAND_CALL_ID) == 1
        ),
        "chat_backend_approval_output_not_duplicated": (
            signature_count_for_call_output(chat_prefix_signatures, CALL_ID) == 1
        ),
        "chat_backend_does_not_fabricate_second_final_answer": package_omits_second_final(
            post_timeline,
        ),
        "chat_backend_visible_state_preserves_completed_first_turn_only": (
            visible["contains_first_final_text"]
            and not visible["contains_second_final_text"]
            and not visible["contains_command_output"]
            and visible["turn_statuses"] == ["completed", "interrupted"]
        ),
        "chat_backend_read_marks_second_turn_interrupted": (
            "interrupted" in visible["turn_statuses"]
        ),
        "chat_backend_workspace_side_effect_exists": (
            chat_result["workspace_effect"]["session_grant_file_exists"]
            and COMMAND_OUTPUT_TEXT
            in (chat_result["workspace_effect"]["session_grant_file_text"] or "")
        ),
        "chat_backend_read_does_not_show_second_final_answer": (
            SECOND_FINAL_TEXT not in read_serialized
        ),
        "original_source_semantics_used": {
            "recorder_pending_items_drain": "rollout/src/recorder.rs:1545-1550 and 1683-1714",
            "flush_barrier": "thread-store/src/local/live_writer.rs:114-129",
            "interpretation": (
                "Original Codex drains only the written prefix. This smoke "
                "checks the .chat backend preserves a request_permissions "
                "approval prefix plus a later command-output batch, repairs "
                "projections from that durable prefix, and does not fabricate "
                "the following assistant answer."
            ),
        },
        "original_storage_summary": original_storage,
        "original_rollout_summary": original_rollout_summary,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures_after_repair": chat_prefix_signatures,
        "original_normalized_final_thread_read_visible": original_result[
            "normalized_final_thread_read_visible"
        ],
        "chat_backend_normalized_thread_read": chat_result["normalized_thread_read"],
        "chat_backend_normalized_thread_read_visible": visible,
        "chat_backend_normalized_thread_list": chat_result["normalized_thread_list"],
        "chat_backend_normalized_thread_search": chat_result["normalized_thread_search"],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "chat_backend_post_repair_timeline_summary": post_timeline,
        "not_yet_proven": [
            "process abort after request_permissions second final answer or task completion",
            "recoverable retry at this later command-output approval-follow-up boundary",
            "broader approval crash variants across network, file-change, freeform apply_patch, and additional-permissions flows",
            "arbitrary real filesystem I/O failures outside validation failpoints",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
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
            summary["chat_backend_retains_approval_output"],
            summary["chat_backend_retains_first_final_answer"],
            summary["chat_backend_retains_session_command_call"],
            summary["chat_backend_retains_session_command_output"],
            summary["chat_backend_command_output_not_duplicated"],
            summary["chat_backend_approval_output_not_duplicated"],
            summary["chat_backend_does_not_fabricate_second_final_answer"],
            summary["chat_backend_visible_state_preserves_completed_first_turn_only"],
            summary["chat_backend_read_marks_second_turn_interrupted"],
            summary["chat_backend_workspace_side_effect_exists"],
            summary["chat_backend_read_does_not_show_second_final_answer"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow request_permissions later-batch crash slice: "
        "after approval output and the first final answer are already durable, "
        "the adapted .chat backend aborts after the later session-grant command "
        "function_call_output becomes canonical and before projection rebuild, "
        "repairs projections on fresh read, retains the approval and command "
        "output prefix in canonical storage, keeps ordinary read UI at the "
        "completed first-turn/interrupted second-turn boundary, and does not "
        "fabricate the following assistant answer. "
        "It is not final approval crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/request-permissions-normal-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/request-permissions-later-batch-crash-response.json",
        chat_result,
    )

    report = f"""# App-Server Request Permissions Later-Batch Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow later-batch T06/H05 boundary. The adapted backend
first persists the standalone `request_permissions` approval output and first
assistant answer, then aborts after the following session-grant shell command
`function_call_output` is synced to `journal.ndjson` and `timeline.ndjson`, but
before projection rebuild for that canonical write.

The adapted backend uses:

```text
{FAILPOINT_ENV}={FAILPOINT_NAME}
{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}
```

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- canonical `.chat` prefix survived crash: `{summary['chat_backend_canonical_prefix_survived_crash']}`
- canonical line count stayed fixed during repair: `{summary['chat_backend_timeline_not_extended_by_repair']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- prefix matches original normal-run prefix: `{summary['chat_backend_prefix_matches_original_prefix']}`
- prefix is strict, not the full completed two-turn scenario: `{summary['chat_backend_prefix_is_strict_prefix']}` (`{len(chat_prefix_signatures)}` of `{len(original_signatures)}`)
- approval output retained: `{summary['chat_backend_retains_approval_output']}`
- first final assistant answer retained: `{summary['chat_backend_retains_first_final_answer']}`
- later session command call retained: `{summary['chat_backend_retains_session_command_call']}`
- later session command output retained: `{summary['chat_backend_retains_session_command_output']}`
- command output not duplicated: `{summary['chat_backend_command_output_not_duplicated']}`
- approval output not duplicated: `{summary['chat_backend_approval_output_not_duplicated']}`
- second final assistant answer not fabricated: `{summary['chat_backend_does_not_fabricate_second_final_answer']}`
- fresh read shows completed first turn and interrupted second turn without fabricating command output UI: `{summary['chat_backend_visible_state_preserves_completed_first_turn_only']}`
- fresh read marks an interrupted turn: `{summary['chat_backend_read_marks_second_turn_interrupted']}`
- workspace side effect exists as expected: `{summary['chat_backend_workspace_side_effect_exists']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-normal-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-later-batch-crash-response.json
```

## Not Yet Proven

This smoke does not prove process abort after the second final answer or task
completion, recoverable retry at this later boundary, broader approval crash
variants, arbitrary real filesystem I/O failures outside validation failpoints,
final crash recovery parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
