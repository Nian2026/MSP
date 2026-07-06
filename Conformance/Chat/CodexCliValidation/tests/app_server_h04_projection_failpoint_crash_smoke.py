#!/usr/bin/env python3
"""Run H04 process-abort projection-boundary parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path.
The original backend completes a normal durable turn as the oracle. The adapted
`.chat` backend runs with an validation failpoint that aborts the
process after canonical journal/timeline writes for `task_complete` and before
standard projection rebuild. A fresh app-server process then reads the same
thread and must repair stale projections from canonical data without changing
normal read/list/search behavior.

This is H04-adjacent evidence, not a final crash recovery claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
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
    summarize_chat_packages,
    summarize_original_storage,
)
from app_server_stale_projection_repair_smoke import (  # noqa: E402
    PROJECTION_FILES,
    observe_package,
    projection_repaired,
)


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "task_complete"

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
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


def close_or_collect(client: JsonRpcClient) -> str:
    if client.process.poll() is None:
        return client.close()
    assert client.process.stderr is not None
    return client.process.stderr.read()


def wait_for_process_exit(client: JsonRpcClient, timeout_seconds: float = 60) -> int | None:
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
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-h04-original",
                FIRST_USER_TEXT,
            )
        finally:
            first_stderr = close_or_collect(first_client)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_response = send_thread_read(second_client, 102, thread_id)
            list_response = send_thread_list(second_client, 103)
            search_response = send_thread_search(second_client, 104)
        finally:
            second_stderr = close_or_collect(second_client)
        storage = summarize_original_storage(codex_home)
        return {
            "thread_id": thread_id,
            "initialize_response": initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": turn_start_response,
            "second_initialize_response": second_initialize_response,
            "thread_read_response": read_response,
            "thread_list_response": list_response,
            "thread_search_response": search_response,
            "normalized_thread_read": normalize_thread_response(read_response, thread_id),
            "normalized_thread_list": normalize_thread_list_response(list_response, thread_id),
            "normalized_thread_search": normalize_thread_search_response(search_response, thread_id),
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "storage_summary": storage,
            "first_stderr_tail": first_stderr[-6000:],
            "second_stderr_tail": second_stderr[-6000:],
            "first_process_exit_code": first_client.process.returncode,
            "second_process_exit_code": second_client.process.returncode,
        }


def run_chat_backend_crash_and_repair(
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
        turn_completed: dict[str, Any] | None = None
        turn_start_error: str | None = None
        turn_completed_error: str | None = None
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            try:
                turn_start_response = send_turn_start(
                    first_client,
                    3,
                    thread_id,
                    "client-user-message-h04-chat",
                    FIRST_USER_TEXT,
                )
            except Exception as exc:  # process may abort before the response is read
                turn_start_error = repr(exc)
            crash_exit_code = wait_for_process_exit(first_client, timeout_seconds=60)
        finally:
            first_stderr = close_or_collect(first_client)

        pre_repair = observe_package(chat_root, thread_id, "plain")
        pre_repair_summary = summarize_chat_packages(chat_root)

        second_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_response = send_thread_read(second_client, 102, thread_id)
            list_response = send_thread_list(second_client, 103)
            search_response = send_thread_search(second_client, 104)
            post_repair = observe_package(chat_root, thread_id, "plain")
            post_repair_summary = summarize_chat_packages(chat_root)
        finally:
            second_stderr = close_or_collect(second_client)

        return {
            "thread_id": thread_id,
            "initialize_response": initialize_response,
            "turn_start_response": turn_start_response,
            "turn_start_error": turn_start_error,
            "turn_completed": turn_completed,
            "turn_completed_error": turn_completed_error,
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
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "second_stderr_tail": second_stderr[-6000:],
        }


def projection_source_count(observation: dict[str, Any], kind: str) -> int:
    return int((observation.get("projections") or {}).get(kind, {}).get("source_event_ids_count") or 0)


def projection_was_stale_before_repair(observation: dict[str, Any]) -> bool:
    timeline_valid = int((observation.get("timeline") or {}).get("valid_line_count") or 0)
    if timeline_valid == 0:
        return False
    return any(
        projection_source_count(observation, kind) < timeline_valid
        for kind in PROJECTION_FILES
    )


def all_projections_repaired(observation: dict[str, Any]) -> bool:
    return all(
        projection_repaired(observation, "stale-projection", kind)
        for kind in PROJECTION_FILES
    )


def line_counts(storage: dict[str, Any], kind: str) -> list[int]:
    if kind == "original":
        return [rollout.get("line_count") for rollout in storage.get("rollouts") or []]
    return [
        package.get("journal_line_count")
        for package in storage.get("packages") or []
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-h04-projection-failpoint-crash-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    chat_result = run_chat_backend_crash_and_repair(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        chat_workspace,
        chat_home,
        chat_root,
        chat_config,
    )

    original_lines = line_counts(original_result["storage_summary"], "original")
    chat_lines = line_counts(chat_result["post_repair_summary"], "chat")

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-h04-projection-failpoint-crash-smoke",
        "matrix_slice": ["H04", "L08-adjacent", "R01-adjacent"],
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
        "original_thread_read_equal_after_repair": (
            original_result["normalized_thread_read"]
            == chat_result["normalized_thread_read"]
        ),
        "original_thread_list_equal_after_repair": (
            original_result["normalized_thread_list"]
            == chat_result["normalized_thread_list"]
        ),
        "original_thread_search_equal_after_repair": (
            original_result["normalized_thread_search"]
            == chat_result["normalized_thread_search"]
        ),
        "chat_backend_process_aborted_at_failpoint": chat_result["crash_was_signal_abort"],
        "chat_backend_pre_repair_projection_stale": projection_was_stale_before_repair(
            chat_result["pre_repair"]
        ),
        "chat_backend_post_repair_projections_ok": all_projections_repaired(
            chat_result["post_repair"]
        ),
        "chat_backend_canonical_survived_crash": (
            (chat_result["pre_repair"].get("timeline") or {}).get("valid_line_count", 0) > 0
            and (chat_result["pre_repair"].get("journal") or {}).get("valid_line_count", 0) > 0
        ),
        "durable_line_counts_equal": original_lines == chat_lines and bool(original_lines),
        "original_line_counts": original_lines,
        "chat_backend_journal_line_counts": chat_lines,
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_normalized_thread_read": original_result["normalized_thread_read"],
        "chat_backend_normalized_thread_read_after_repair": chat_result[
            "normalized_thread_read"
        ],
        "original_normalized_thread_list": original_result["normalized_thread_list"],
        "chat_backend_normalized_thread_list_after_repair": chat_result[
            "normalized_thread_list"
        ],
        "original_normalized_thread_search": original_result["normalized_thread_search"],
        "chat_backend_normalized_thread_search_after_repair": chat_result[
            "normalized_thread_search"
        ],
        "not_yet_proven": [
            "H05 crash during pending write",
            "H06 crash during archive/delete",
            "process-kill boundaries for command execution, rollback, compaction, and cold transitions",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
        "original": original_result,
        "chat_backend": chat_result,
    }
    summary["passed"] = all(
        [
            summary["original_thread_read_equal_after_repair"],
            summary["original_thread_list_equal_after_repair"],
            summary["original_thread_search_equal_after_repair"],
            summary["chat_backend_process_aborted_at_failpoint"],
            summary["chat_backend_pre_repair_projection_stale"],
            summary["chat_backend_post_repair_projections_ok"],
            summary["chat_backend_canonical_survived_crash"],
            summary["durable_line_counts_equal"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow H04 process-abort projection-boundary slice: the "
        "adapted .chat backend aborts after canonical journal/timeline writes "
        "for task_complete and before projection rebuild, then a fresh app-server "
        "repairs stale projections from canonical data and matches the original "
        "backend's normalized read/list/search behavior. It is not full crash "
        "recovery parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/h04-original-response.json", original_result)
    write_json(output_dir / "chat-backend/h04-chat-backend-response.json", chat_result)

    report = f"""# App-Server H04 Projection Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers the H04 boundary where canonical `.chat` data is durable but
derived projections are stale because the process aborts before projection
rebuild.

The adapted backend uses the validation failpoint
`{FAILPOINT_ENV}={FAILPOINT_NAME}` with `{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}`.
The original backend runs normally and acts as the user-visible oracle.

## Result

- `.chat` backend process aborted at failpoint: `{summary['chat_backend_process_aborted_at_failpoint']}`
- canonical `.chat` journal/timeline survived crash: `{summary['chat_backend_canonical_survived_crash']}`
- projections were stale before repair: `{summary['chat_backend_pre_repair_projection_stale']}`
- projections repaired after fresh read: `{summary['chat_backend_post_repair_projections_ok']}`
- normalized `thread/read` matches original after repair: `{summary['original_thread_read_equal_after_repair']}`
- normalized `thread/list` matches original after repair: `{summary['original_thread_list_equal_after_repair']}`
- normalized `thread/search` matches original after repair: `{summary['original_thread_search_equal_after_repair']}`
- durable line counts equal: `{summary['durable_line_counts_equal']}` (`{original_lines}` vs `{chat_lines}`)

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/h04-original-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/h04-chat-backend-response.json
```

## Not Yet Proven

This smoke does not prove H05 pending-write crash recovery, H06 lifecycle crash
recovery, process-kill boundaries for command execution/rollback/compaction/cold
transitions, final crash recovery parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
