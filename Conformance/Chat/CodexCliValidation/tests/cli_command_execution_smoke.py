#!/usr/bin/env python3
"""Run real `codex exec --json` command-execution parity smoke.

This source-backed validation uses the user-facing Codex CLI path instead of only
driving the app-server JSON-RPC API. It runs the same model-requested
`shell_command` success and failure sequence against the unmodified original
backend and the adapted `.chat` backend, using a local mock Responses API.

This is not a final parity claim.
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

from app_server_command_execution_smoke import (  # noqa: E402
    FAIL_CALL_ID,
    FAIL_COMMAND,
    FINAL_TEXT,
    SequenceResponsesServer,
    SUCCESS_CALL_ID,
    SUCCESS_COMMAND,
    summarize_command_timeline,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import parse_jsonl, thread_ids_from_events  # noqa: E402


USER_TEXT = "Run the CLI command execution .chat parity smoke."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_execution_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/src/exec_events.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/src/event_processor_with_jsonl_output.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/tests/event_processor_with_json_output.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def command_marker_summary(output: str) -> dict[str, bool]:
    return {
        "contains_ok_stdout": "CMD_OK_STDOUT" in output,
        "contains_ok_stderr": "CMD_OK_STDERR" in output,
        "contains_fail_stdout": "CMD_FAIL_STDOUT" in output,
        "contains_fail_stderr": "CMD_FAIL_STDERR" in output,
    }


def normalize_cli_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for event in events:
        event_type = event.get("type")
        if event_type == "thread.started":
            normalized.append(
                {"type": event_type, "thread_id_present": bool(event.get("thread_id"))}
            )
            continue
        if event_type in {"turn.started", "turn.completed"}:
            usage = event.get("usage") or {}
            normalized.append(
                {
                    "type": event_type,
                    "usage": {
                        "input_tokens": usage.get("input_tokens"),
                        "cached_input_tokens": usage.get("cached_input_tokens"),
                        "output_tokens": usage.get("output_tokens"),
                        "reasoning_output_tokens": usage.get("reasoning_output_tokens"),
                    }
                    if event_type == "turn.completed"
                    else None,
                }
            )
            continue
        if event_type in {"item.started", "item.updated", "item.completed"}:
            item = event.get("item") or {}
            item_type = item.get("type")
            if item_type == "command_execution":
                output = item.get("aggregated_output") or ""
                normalized.append(
                    {
                        "type": event_type,
                        "item_type": item_type,
                        "command": item.get("command"),
                        "status": item.get("status"),
                        "exit_code": item.get("exit_code"),
                        "output": output,
                        **command_marker_summary(output),
                    }
                )
                continue
            if item_type == "agent_message":
                normalized.append(
                    {
                        "type": event_type,
                        "item_type": item_type,
                        "text": item.get("text"),
                    }
                )
                continue
            normalized.append(
                {
                    "type": event_type,
                    "item_type": item_type,
                }
            )
            continue
        normalized.append({"type": event_type})
    return normalized


def command_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        event
        for event in normalize_cli_events(events)
        if event.get("item_type") == "command_execution"
    ]


def completed_command_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        event
        for event in command_events(events)
        if event.get("type") == "item.completed"
    ]


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    serialized_bodies = [json.dumps(body, ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "contains_success_function_output": any(
            SUCCESS_CALL_ID in body and "function_call_output" in body
            for body in serialized_bodies
        ),
        "contains_failure_function_output": any(
            FAIL_CALL_ID in body and "function_call_output" in body
            for body in serialized_bodies
        ),
        "contains_success_stdout": any("CMD_OK_STDOUT" in body for body in serialized_bodies),
        "contains_success_stderr": any("CMD_OK_STDERR" in body for body in serialized_bodies),
        "contains_failure_stdout": any(
            "CMD_FAIL_STDOUT" in body for body in serialized_bodies
        ),
        "contains_failure_stderr": any(
            "CMD_FAIL_STDERR" in body for body in serialized_bodies
        ),
    }


def run_cli_exec(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    command = [str(codex_bin)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(
        [
            "exec",
            "--skip-git-repo-check",
            "--json",
            "--color",
            "never",
            "--cd",
            str(workspace),
            USER_TEXT,
        ]
    )

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env.setdefault("RUST_LOG", "warn")

    started_at = time.time()
    completed = subprocess.run(
        command,
        cwd=str(workspace),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
        check=False,
    )
    events = parse_jsonl(completed.stdout) if completed.stdout else []
    return {
        "command": command,
        "exit_code": completed.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-6000:],
        "events": events,
        "normalized_events": normalize_cli_events(events),
        "command_events": command_events(events),
        "completed_command_events": completed_command_events(events),
        "thread_ids": thread_ids_from_events(events),
    }


def summarize_rollout_line_counts(codex_home: pathlib.Path) -> dict[str, Any]:
    summary = summarize_original_storage(codex_home)
    line_counts = [rollout["line_count"] for rollout in summary.get("rollouts", [])]
    return {
        "summary": summary,
        "rollout_file_count": len(summary.get("rollouts", [])),
        "rollout_line_counts": line_counts,
        "total_rollout_lines": sum(line_counts),
    }


def summarize_chat_line_counts(chat_root: pathlib.Path) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    packages = summary.get("packages", [])
    return {
        "summary": summary,
        "package_count": summary.get("package_count"),
        "timeline_line_counts": [package.get("timeline_line_count") for package in packages],
        "journal_line_counts": [package.get("journal_line_count") for package in packages],
        "total_timeline_lines": sum(package.get("timeline_line_count", 0) for package in packages),
        "total_journal_lines": sum(package.get("journal_line_count", 0) for package in packages),
    }


def inspect_chat_package_files(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {"package_exists": False}
    package = packages[0]
    timeline = read_json_lines(package / "timeline.ndjson")
    journal = read_json_lines(package / "journal.ndjson")
    projections_dir = package / "projections"
    projections = (
        sorted(item.relative_to(package).as_posix() for item in projections_dir.glob("*.ndjson"))
        if projections_dir.exists()
        else []
    )
    command_events = [
        line for line in timeline if str(line.get("type")).startswith("command")
    ]
    return {
        "package_exists": True,
        "package": str(package),
        "timeline_event_types": [line.get("type") for line in timeline],
        "journal_entry_count": len(journal),
        "projection_files": projections,
        "has_chat_read_projection": "projections/chat-read.ndjson" in projections,
        "has_model_context_projection": "projections/model-context.ndjson" in projections,
        "has_audit_projection": "projections/audit.ndjson" in projections,
        "command_event_types": [line.get("type") for line in command_events],
        "command_call_ids": [
            ((line.get("body") or {}).get("call_id")) for line in command_events
        ],
        "source_response_types": [
            ((line.get("body") or {}).get("source_response_type"))
            for line in command_events
        ],
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with SequenceResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        exec_result = run_cli_exec(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
        )

    result: dict[str, Any] = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "exec": exec_result,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
    }
    if tree_name == "chat-backend":
        result["chat_storage"] = summarize_chat_line_counts(chat_root)
        result["chat_package_files"] = inspect_chat_package_files(chat_root)
        result["command_timeline_summary"] = summarize_command_timeline(chat_root)
    else:
        result["original_storage"] = summarize_rollout_line_counts(codex_home)
    return result


def has_success_and_failure_commands(events: list[dict[str, Any]]) -> bool:
    completed = completed_command_events(events)
    exit_codes = [event.get("exit_code") for event in completed]
    return (
        0 in exit_codes
        and 7 in exit_codes
        and any(
            event["contains_ok_stdout"] and event["contains_ok_stderr"]
            for event in completed
        )
        and any(
            event["contains_fail_stdout"] and event["contains_fail_stderr"]
            for event in completed
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-command-execution-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_events = original_result["exec"]["normalized_events"]
    chat_events = chat_result["exec"]["normalized_events"]
    original_command_events = original_result["exec"]["command_events"]
    chat_command_events = chat_result["exec"]["command_events"]
    original_completed = original_result["exec"]["completed_command_events"]
    chat_completed = chat_result["exec"]["completed_command_events"]
    original_lines = original_result["original_storage"]["total_rollout_lines"]
    chat_journal_lines = chat_result["chat_storage"]["total_journal_lines"]
    chat_package = chat_result["chat_package_files"]
    command_timeline_summary = chat_result["command_timeline_summary"]
    command_event_types = [
        event_type
        for package in command_timeline_summary["packages"]
        for event_type in package["command_event_types"]
    ]
    command_call_ids = [
        call_id
        for package in command_timeline_summary["packages"]
        for call_id in package["call_ids"]
    ]
    source_response_types = [
        source_response_type
        for package in command_timeline_summary["packages"]
        for source_response_type in package["source_response_types"]
    ]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-command-execution-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_exec_exit_ok": original_result["exec"]["exit_code"] == 0,
        "chat_backend_exec_exit_ok": chat_result["exec"]["exit_code"] == 0,
        "normalized_cli_events_equal": original_events == chat_events,
        "normalized_command_events_equal": original_command_events == chat_command_events,
        "completed_command_events_equal": original_completed == chat_completed,
        "original_has_success_and_failure_commands": has_success_and_failure_commands(
            original_result["exec"]["events"]
        ),
        "chat_backend_has_success_and_failure_commands": has_success_and_failure_commands(
            chat_result["exec"]["events"]
        ),
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
            == 3
        ),
        "mock_function_call_outputs_equal": (
            original_result["mock_server_summary"]
            == chat_result["mock_server_summary"]
        ),
        "mock_outputs_round_trip": (
            original_result["mock_server_summary"]["contains_success_function_output"]
            and original_result["mock_server_summary"]["contains_failure_function_output"]
            and original_result["mock_server_summary"]["contains_success_stdout"]
            and original_result["mock_server_summary"]["contains_success_stderr"]
            and original_result["mock_server_summary"]["contains_failure_stdout"]
            and original_result["mock_server_summary"]["contains_failure_stderr"]
            and chat_result["mock_server_summary"]["contains_success_function_output"]
            and chat_result["mock_server_summary"]["contains_failure_function_output"]
            and chat_result["mock_server_summary"]["contains_success_stdout"]
            and chat_result["mock_server_summary"]["contains_success_stderr"]
            and chat_result["mock_server_summary"]["contains_failure_stdout"]
            and chat_result["mock_server_summary"]["contains_failure_stderr"]
        ),
        "original_rollout_lines_equal_chat_journal_lines": (
            original_lines == chat_journal_lines and original_lines > 0
        ),
        "chat_package_materialized": (
            chat_result["chat_storage"]["package_count"] == 1
            and chat_package.get("package_exists") is True
        ),
        "chat_package_has_standard_projections": (
            chat_package.get("has_chat_read_projection") is True
            and chat_package.get("has_model_context_projection") is True
            and chat_package.get("has_audit_projection") is True
        ),
        "chat_timeline_has_command_call": "command_call" in command_event_types,
        "chat_timeline_has_command_output": "command_output" in command_event_types,
        "chat_timeline_has_success_and_failure_call_ids": (
            SUCCESS_CALL_ID in command_call_ids and FAIL_CALL_ID in command_call_ids
        ),
        "chat_timeline_has_source_transport_mapping": (
            "function_call" in source_response_types
            and "function_call_output" in source_response_types
        ),
        "commands": {
            "success_call_id": SUCCESS_CALL_ID,
            "failure_call_id": FAIL_CALL_ID,
            "success_command": SUCCESS_COMMAND,
            "failure_command": FAIL_COMMAND,
        },
        "original": {
            "exec": {
                "command": original_result["exec"]["command"],
                "exit_code": original_result["exec"]["exit_code"],
                "normalized_events": original_events,
                "command_events": original_command_events,
                "completed_command_events": original_completed,
                "thread_ids": original_result["exec"]["thread_ids"],
                "stderr_tail": original_result["exec"]["stderr_tail"],
            },
            "mock_server_summary": original_result["mock_server_summary"],
            "storage": original_result["original_storage"],
        },
        "chat_backend": {
            "exec": {
                "command": chat_result["exec"]["command"],
                "exit_code": chat_result["exec"]["exit_code"],
                "normalized_events": chat_events,
                "command_events": chat_command_events,
                "completed_command_events": chat_completed,
                "thread_ids": chat_result["exec"]["thread_ids"],
                "stderr_tail": chat_result["exec"]["stderr_tail"],
            },
            "mock_server_summary": chat_result["mock_server_summary"],
            "storage": chat_result["chat_storage"],
            "chat_package_files": chat_package,
            "command_timeline_summary": command_timeline_summary,
        },
        "not_yet_proven": [
            "CLI stdout/stderr live streaming deltas, because codex exec JSONL exposes command start/completion and aggregated output rather than app-server outputDelta notifications",
            "approval/permission command flow",
            "artifact-producing commands",
            "crash recovery during command execution",
            "complete command data fidelity report",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_exec_exit_ok"],
            summary["chat_backend_exec_exit_ok"],
            summary["normalized_cli_events_equal"],
            summary["normalized_command_events_equal"],
            summary["completed_command_events_equal"],
            summary["original_has_success_and_failure_commands"],
            summary["chat_backend_has_success_and_failure_commands"],
            summary["mock_response_request_counts_equal"],
            summary["mock_function_call_outputs_equal"],
            summary["mock_outputs_round_trip"],
            summary["original_rollout_lines_equal_chat_journal_lines"],
            summary["chat_package_materialized"],
            summary["chat_package_has_standard_projections"],
            summary["chat_timeline_has_command_call"],
            summary["chat_timeline_has_command_output"],
            summary["chat_timeline_has_success_and_failure_call_ids"],
            summary["chat_timeline_has_source_transport_mapping"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI T01/T02 command-execution slice: "
        "`codex exec --json` produces matching normalized command start/completion "
        "events, preserves success and non-zero exit statuses, round-trips stdout "
        "and stderr through function_call_output context, keeps original rollout "
        "line counts equal to .chat journal line counts, and maps command facts to "
        "neutral .chat command_call/command_output timeline events. It is not full "
        "CLI command streaming, crash-recovery, approval, artifact, or final parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)

    if not passed:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
