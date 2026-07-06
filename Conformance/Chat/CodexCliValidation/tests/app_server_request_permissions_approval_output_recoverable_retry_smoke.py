#!/usr/bin/env python3
"""Run request_permissions approval-output recoverable retry smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend completes a one-turn request_permissions approval
flow as the oracle. The adapted `.chat` backend runs the same flow with a
one-shot recoverable append failpoint after the approval `function_call_output`
has reached canonical `journal.ndjson` and `timeline.ndjson`, and before
standard projections are rebuilt from that canonical write.

The process must stay alive, recover the durable canonical write, complete the
turn, rebuild projections, and match the
original backend for the covered app-server surface. This is not a final T06,
H05, crash-recovery, or user-indistinguishability claim.
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
    FIRST_FINAL_TEXT,
    REQUEST_REASON,
    USER_TEXT,
    RequestPermissionsResponsesServer,
    first_requested_write_path,
    normalize_thread_read_visible,
    summarize_chat_timeline,
    write_request_permissions_config,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402


RECOVERABLE_FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT"
RECOVERABLE_MARKER_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT_MARKER"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "function_call_output"
SEARCH_TERM = "request_permissions approval smoke"

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_approval_output_failpoint_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_recoverable_append_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h04_projection_failpoint_crash_smoke.py",
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


def send_thread_search_request(
    client: JsonRpcClient,
    request_id: int,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/search",
            "params": {
                "limit": 10,
                "archived": False,
                "searchTerm": SEARCH_TERM,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def normalize_request_permissions_search_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    matched_result = next(
        (
            item
            for item in data
            if ((item.get("thread") or {}).get("id") == thread_id)
        ),
        None,
    )
    snippet = (matched_result or {}).get("snippet") or ""
    thread = (matched_result or {}).get("thread") or {}
    return {
        "has_error": "error" in response,
        "result_count": len(data),
        "contains_started_thread": matched_result is not None,
        "snippet_contains_search_term": SEARCH_TERM.lower() in snippet.lower(),
        "thread_preview": thread.get("preview"),
        "thread_status_type": _status_type(thread.get("status")),
        "thread_model_provider": thread.get("modelProvider"),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def _status_type(value: Any) -> Any:
    if isinstance(value, dict):
        return value.get("type")
    return value


def approval_output_signature_count(signatures: list[dict[str, Any]]) -> int:
    return sum(
        1
        for signature in signatures
        if signature.get("payload_type") == "function_call_output"
        and signature.get("call_id") == CALL_ID
    )


def package_contains_final_answer(chat_root: pathlib.Path) -> bool:
    for package in chat_root.glob("*.chat"):
        for name in ["timeline.ndjson", "journal.ndjson"]:
            path = package / name
            if path.exists() and FIRST_FINAL_TEXT in path.read_text():
                return True
    return False


def run_one_turn_request_permissions(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    chat_root: pathlib.Path | None = None,
    recoverable_marker: pathlib.Path | None = None,
) -> dict[str, Any]:
    with RequestPermissionsResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        first_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            recoverable_marker=recoverable_marker,
        )
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_id, turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-request-permissions-approval-output-recoverable",
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
            turn_completed_notification = first_client.receive_until_method(
                "turn/completed",
                timeout_seconds=90,
            )
            first_process_exit_code_before_close = first_client.process.poll()
        finally:
            first_stderr = close_or_collect(first_client)

        marker_consumed = recoverable_marker is not None and not recoverable_marker.exists()
        pre_fresh_summary = summarize_chat_packages(chat_root) if chat_root is not None else None
        pre_fresh_timeline = summarize_chat_timeline(chat_root) if chat_root is not None else None
        pre_fresh_observation: dict[str, Any] | None = None
        pre_fresh_signatures: list[dict[str, Any]] | None = None
        package_path: pathlib.Path | None = None
        if chat_root is not None:
            pre_fresh_observation = observe_package(chat_root, thread_id, "plain")
            package_path = pathlib.Path(pre_fresh_observation["package"])
            pre_fresh_signatures = chat_journal_signatures(package_path)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_response = send_thread_read(second_client, 102, thread_id)
            list_response = send_thread_list(second_client, 103)
            search_response = send_thread_search_request(second_client, 104)
            second_process_exit_code_before_close = second_client.process.poll()
        finally:
            second_stderr = close_or_collect(second_client)

        post_fresh_summary = summarize_chat_packages(chat_root) if chat_root is not None else None
        post_fresh_timeline = summarize_chat_timeline(chat_root) if chat_root is not None else None
        post_fresh_observation: dict[str, Any] | None = None
        post_fresh_signatures: list[dict[str, Any]] | None = None
        if chat_root is not None:
            post_fresh_observation = observe_package(chat_root, thread_id, "plain")
            assert package_path is not None
            post_fresh_signatures = chat_journal_signatures(package_path)

        return {
            "thread_id": thread_id,
            "turn_id": turn_id,
            "initialize_response": initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": turn_start_response,
            "permission_request": permission_request,
            "turn_completed_notification": turn_completed_notification,
            "thread_read_response": read_response,
            "thread_list_response": list_response,
            "thread_search_response": search_response,
            "second_initialize_response": second_initialize_response,
            "normalized_thread_read": normalize_thread_response(read_response, thread_id),
            "normalized_thread_read_visible": normalize_thread_read_visible(read_response),
            "normalized_thread_list": normalize_thread_list_response(list_response, thread_id),
            "normalized_thread_search": normalize_request_permissions_search_response(
                search_response,
                thread_id,
            ),
            "mock_server_summary": mock_server.summary(),
            "first_process_exit_code_before_close": first_process_exit_code_before_close,
            "second_process_exit_code_before_close": second_process_exit_code_before_close,
            "first_stderr_tail": first_stderr[-6000:],
            "second_stderr_tail": second_stderr[-6000:],
            "marker_consumed": marker_consumed,
            "pre_fresh_summary": pre_fresh_summary,
            "post_fresh_summary": post_fresh_summary,
            "pre_fresh_timeline_summary": pre_fresh_timeline,
            "post_fresh_timeline_summary": post_fresh_timeline,
            "pre_fresh_observation": pre_fresh_observation,
            "post_fresh_observation": post_fresh_observation,
            "pre_fresh_source_signatures": pre_fresh_signatures,
            "post_fresh_source_signatures": post_fresh_signatures,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-request-permissions-approval-output-recoverable-retry-smoke-"
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
    marker_path = run_root / "chat-backend" / "recoverable-approval-output.marker"
    for path in [original_workspace, original_home, chat_workspace, chat_home, chat_root]:
        path.mkdir(parents=True, exist_ok=True)

    chat_config = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]

    original_result = run_one_turn_request_permissions(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        original_workspace,
        original_home,
        [],
    )
    chat_result = run_one_turn_request_permissions(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_config,
        chat_root=chat_root,
        recoverable_marker=marker_path,
    )

    original_storage = summarize_original_storage(original_home)
    original_signatures = original_rollout_signatures(original_home)
    chat_signatures = chat_result["post_fresh_source_signatures"] or []
    chat_pre_observation = chat_result["pre_fresh_observation"] or {}
    chat_post_observation = chat_result["post_fresh_observation"] or {}
    chat_pre_count = valid_line_count(chat_pre_observation, "timeline")
    chat_post_count = valid_line_count(chat_post_observation, "timeline")

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-request-permissions-approval-output-recoverable-retry-smoke",
        "matrix_slice": ["T06", "H05", "R01-adjacent", "C02-adjacent"],
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
                "return one recoverable append error after approval "
                "function_call_output is canonical and before projection rebuild"
            ),
        },
        "binary_checks": binary_checks,
        "chat_backend_process_survived_recoverable_error": (
            chat_result["first_process_exit_code_before_close"] is None
        ),
        "chat_backend_marker_consumed_once": chat_result["marker_consumed"],
        "chat_backend_turn_completed_after_retry": (
            "error" not in (chat_result["turn_start_response"].get("response") or {})
            and chat_result["turn_completed_notification"].get("method") == "turn/completed"
        ),
        "chat_backend_projections_ok_before_fresh_read": all_projections_repaired(
            chat_pre_observation,
        ),
        "chat_backend_projections_ok_after_fresh_read": all_projections_repaired(
            chat_post_observation,
        ),
        "chat_backend_no_invalid_canonical_lines": (
            invalid_line_count(chat_pre_observation, "timeline") == 0
            and invalid_line_count(chat_pre_observation, "journal") == 0
            and invalid_line_count(chat_post_observation, "timeline") == 0
            and invalid_line_count(chat_post_observation, "journal") == 0
        ),
        "chat_backend_timeline_stable_across_fresh_read": chat_pre_count == chat_post_count,
        "chat_backend_line_count_matches_original": (
            len(chat_signatures) == len(original_signatures)
        ),
        "chat_backend_source_signatures_match_original": (
            chat_signatures == original_signatures
        ),
        "chat_backend_approval_output_not_duplicated": (
            approval_output_signature_count(chat_signatures) == 1
        ),
        "chat_backend_retains_approval_output": package_contains_approval_output(
            chat_result["post_fresh_timeline_summary"] or {},
        ),
        "chat_backend_retains_final_answer": package_contains_final_answer(chat_root),
        "normalized_thread_read_visible_matches_original": (
            chat_result["normalized_thread_read_visible"]
            == original_result["normalized_thread_read_visible"]
        ),
        "normalized_thread_list_matches_original": (
            chat_result["normalized_thread_list"]
            == original_result["normalized_thread_list"]
        ),
        "normalized_thread_search_matches_original": (
            chat_result["normalized_thread_search"]
            == original_result["normalized_thread_search"]
        ),
        "mock_server_summary_matches_original": (
            chat_result["mock_server_summary"] == original_result["mock_server_summary"]
        ),
        "original_line_count": len(original_signatures),
        "chat_backend_line_count": len(chat_signatures),
        "chat_backend_timeline_line_count_before_fresh_read": chat_pre_count,
        "chat_backend_timeline_line_count_after_fresh_read": chat_post_count,
        "original_source_signatures": original_signatures,
        "chat_backend_source_signatures": chat_signatures,
        "original_normalized_thread_read_visible": original_result[
            "normalized_thread_read_visible"
        ],
        "chat_backend_normalized_thread_read_visible": chat_result[
            "normalized_thread_read_visible"
        ],
        "original_normalized_thread_list": original_result["normalized_thread_list"],
        "chat_backend_normalized_thread_list": chat_result["normalized_thread_list"],
        "original_normalized_thread_search": original_result["normalized_thread_search"],
        "chat_backend_normalized_thread_search": chat_result["normalized_thread_search"],
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_storage_summary": original_storage,
        "chat_backend_storage_summary": chat_result["post_fresh_summary"],
        "not_yet_proven": [
            "CLI recoverable retry during request_permissions approval-output append",
            "process abort between request_permissions approval output and a later canonical append batch",
            "broader approval crash variants across network, file-change, freeform apply_patch, and additional-permissions flows",
            "arbitrary transient filesystem I/O failures outside this validation failpoint",
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
            summary["chat_backend_approval_output_not_duplicated"],
            summary["chat_backend_retains_approval_output"],
            summary["chat_backend_retains_final_answer"],
            summary["normalized_thread_read_visible_matches_original"],
            summary["normalized_thread_list_matches_original"],
            summary["normalized_thread_search_matches_original"],
            summary["mock_server_summary_matches_original"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow app-server request_permissions approval-output "
        "recoverable retry slice: the adapted .chat backend survives a one-shot "
        "recoverable append error after the approval function_call_output reaches "
        "canonical storage, drains the durable prefix without duplicating it, "
        "rebuilds projections, completes the turn, "
        "and matches the original backend for normalized read/list/search and "
        "mock request behavior. It is not final crash recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/request-permissions-approval-output-original-response.json",
        original_result,
    )
    write_json(
        output_dir
        / "chat-backend/request-permissions-approval-output-recoverable-response.json",
        chat_result,
    )

    report = f"""# App-Server Request Permissions Approval-Output Recoverable Retry Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers a narrow T06/H05 boundary inside standalone
`request_permissions` approval handling. The adapted backend returns one
recoverable append error after the approval `function_call_output` is synced to
`journal.ndjson` and `timeline.ndjson`, and before standard projections are
rebuilt from that canonical write.

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
- journal line count matches original: `{summary['chat_backend_line_count_matches_original']}` (`{len(chat_signatures)}` == `{len(original_signatures)}`)
- source signatures match original: `{summary['chat_backend_source_signatures_match_original']}`
- approval output was not duplicated: `{summary['chat_backend_approval_output_not_duplicated']}`
- approval output retained: `{summary['chat_backend_retains_approval_output']}`
- final answer retained after retry: `{summary['chat_backend_retains_final_answer']}`
- normalized thread/read visible state matches original: `{summary['normalized_thread_read_visible_matches_original']}`
- normalized thread/list matches original: `{summary['normalized_thread_list_matches_original']}`
- normalized thread/search matches original: `{summary['normalized_thread_search_matches_original']}`
- mock model request summary matches original: `{summary['mock_server_summary_matches_original']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-approval-output-original-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-approval-output-recoverable-response.json
```

## Not Yet Proven

This smoke does not prove CLI-level recoverable retry parity for the same
approval-output boundary, broader approval crash variants, arbitrary transient
filesystem I/O failures outside this validation failpoint, final crash recovery
parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
