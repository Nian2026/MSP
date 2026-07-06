#!/usr/bin/env python3
"""Run request_permissions approval-output failpoint crash smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend completes a normal request_permissions flow as the
oracle. The adapted `.chat` backend runs with an validation failpoint
that aborts after the approval `function_call_output` is synced to canonical
`journal.ndjson` and `timeline.ndjson`, and before standard projections are
rebuilt from that canonical write.

This proves only a narrow durable-write boundary inside the standalone
request_permissions approval response handling. It is not a final T06,
crash-recovery, or user-indistinguishability claim.
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
from app_server_request_permissions_smoke import (  # noqa: E402
    CALL_ID,
    REQUEST_REASON,
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
from app_server_cold_package_smoke import (  # noqa: E402
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    send_thread_search,
)


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "function_call_output"

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_pending_write_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_crash_pending_resume_smoke.py",
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


def rollout_payload_signature(value: dict[str, Any]) -> dict[str, Any]:
    payload = value.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    return {
        "type": value.get("type"),
        "payload_type": payload.get("type"),
        "role": payload.get("role"),
        "name": payload.get("name"),
        "call_id": payload.get("call_id"),
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


def chat_package_for(observation: dict[str, Any]) -> pathlib.Path:
    package = observation.get("package")
    if not package:
        raise RuntimeError("expected observed .chat package path")
    return pathlib.Path(package)


def run_chat_backend_approval_output_crash(
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
        turn_start_response: dict[str, Any] | None = None
        turn_start_error: str | None = None
        permission_request: dict[str, Any] | None = None
        crash_exit_code: int | None = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_id, turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-request-permissions-approval-output-crash",
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
            try:
                first_client.receive_until_method("turn/completed", timeout_seconds=20)
            except Exception as exc:
                turn_start_error = repr(exc)
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
        "turn_start_error": turn_start_error,
        "permission_request": permission_request,
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


def package_contains_approval_output(summary: dict[str, Any]) -> bool:
    return any(
        package.get("journal_has_function_call_output")
        and package.get("timeline_has_tool_output")
        and package.get("journal_contains_granted_write")
        and package.get("journal_contains_session_scope")
        for package in summary.get("packages") or []
    )


def package_omits_final_answer(summary: dict[str, Any]) -> bool:
    return not any(
        package.get("journal_contains_command_output")
        or package.get("timeline_has_command_call")
        or package.get("timeline_has_command_output")
        for package in summary.get("packages") or []
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-request-permissions-approval-output-failpoint-smoke-"
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
    chat_result = run_chat_backend_approval_output_crash(
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
    visible = chat_result["normalized_thread_read_visible"]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-request-permissions-approval-output-failpoint-smoke",
        "matrix_slice": ["T06", "H05", "H04-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoint": {
            "env": FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": FAILPOINT_NEEDLE,
            "boundary": (
                "after request_permissions approval function_call_output is synced "
                "to journal/timeline and before projection rebuild"
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
            chat_result["post_repair_timeline_summary"],
        ),
        "chat_backend_does_not_fabricate_later_command_or_output": package_omits_final_answer(
            chat_result["post_repair_timeline_summary"],
        ),
        "chat_backend_visible_state_has_no_final_assistant_or_command": (
            not visible["contains_first_final_text"]
            and not visible["contains_second_final_text"]
            and not visible["contains_command_output"]
        ),
        "chat_backend_canonical_retains_request_permissions_context": any(
            package.get("journal_has_request_permissions_call")
            and package.get("journal_has_function_call_output")
            and package.get("journal_contains_request_reason")
            for package in chat_result["post_repair_timeline_summary"].get("packages") or []
        ),
        "chat_backend_read_marks_interrupted_partial_turn": (
            chat_result["normalized_thread_read"].get("turn_statuses") == ["interrupted"]
        ),
        "original_source_semantics_used": {
            "recorder_pending_items_drain": "rollout/src/recorder.rs:1545-1550 and 1683-1714",
            "flush_barrier": "thread-store/src/local/live_writer.rs:114-129",
            "interpretation": (
                "Original Codex drains only the written prefix; after process death "
                "there is no in-memory pending suffix to retry. This smoke checks "
                "the .chat backend preserves the approved permission output while "
                "not fabricating the following final answer or later command turn."
            ),
        },
        "original_storage_summary": original_storage,
        "original_rollout_summary": original_rollout_summary,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures_after_repair": chat_prefix_signatures,
        "original_normalized_thread_read": original_result["normalized_thread_read_visible"],
        "chat_backend_normalized_thread_read": chat_result["normalized_thread_read"],
        "chat_backend_normalized_thread_read_visible": visible,
        "chat_backend_normalized_thread_list": chat_result["normalized_thread_list"],
        "chat_backend_normalized_thread_search": chat_result["normalized_thread_search"],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "not_yet_proven": [
            "recoverable I/O failure during request_permissions approval-output append",
            "process abort after request_permissions approval output but before a later canonical append batch",
            "process abort after final assistant answer but before task_complete for request_permissions",
            "broader approval crash variants across network, file-change, freeform apply_patch, and additional-permissions flows",
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
            summary["chat_backend_does_not_fabricate_later_command_or_output"],
            summary["chat_backend_visible_state_has_no_final_assistant_or_command"],
            summary["chat_backend_canonical_retains_request_permissions_context"],
            summary["chat_backend_read_marks_interrupted_partial_turn"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow request_permissions approval-output durable-write "
        "projection boundary: the adapted .chat backend aborts after the "
        "permission function_call_output is canonical but before projection "
        "rebuild, repairs projections on fresh read, retains the approval output, "
        "and does not fabricate later command data. It is not full approval crash "
        "parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/request-permissions-normal-response.json", original_result)
    write_json(
        output_dir / "chat-backend/request-permissions-approval-output-crash-response.json",
        chat_result,
    )

    report = f"""# App-Server Request Permissions Approval-Output Failpoint Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow T06/H05 boundary inside standalone
`request_permissions` approval handling. The adapted backend aborts after the
approval `function_call_output` is synced to `journal.ndjson` and
`timeline.ndjson`, but before projection rebuild for that canonical write.

The adapted backend uses `{FAILPOINT_ENV}={FAILPOINT_NAME}` with
`{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}`.

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- canonical `.chat` prefix survived crash: `{summary['chat_backend_canonical_prefix_survived_crash']}`
- canonical line count stayed fixed during repair: `{summary['chat_backend_timeline_not_extended_by_repair']}` (`{chat_pre_count}` -> `{chat_post_count}`)
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- prefix matches original normal-run prefix: `{summary['chat_backend_prefix_matches_original_prefix']}`
- prefix is strict, not the full completed request_permissions scenario: `{summary['chat_backend_prefix_is_strict_prefix']}` (`{len(chat_prefix_signatures)}` of `{len(original_signatures)}`)
- approval output retained: `{summary['chat_backend_retains_approval_output']}`
- request_permissions context retained in canonical journal/timeline: `{summary['chat_backend_canonical_retains_request_permissions_context']}`
- later final answer/command output not fabricated: `{summary['chat_backend_does_not_fabricate_later_command_or_output']}`
- fresh read marks the partial turn interrupted: `{summary['chat_backend_read_marks_interrupted_partial_turn']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-normal-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-approval-output-crash-response.json
```

## Not Yet Proven

This smoke does not prove recoverable I/O failure during the same approval-output
append, process abort between this approval output and a later canonical append
batch, process abort after final assistant answer but before task completion,
broader approval crash variants, final crash recovery parity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
