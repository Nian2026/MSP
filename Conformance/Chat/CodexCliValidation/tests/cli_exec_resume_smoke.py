#!/usr/bin/env python3
"""Run a real `codex exec` + `codex exec resume --last` parity smoke.

This source-backed validation uses the user-facing Codex CLI path instead of
driving the app-server JSON-RPC API directly. It runs the same completed turn
and resume turn against the unmodified original backend and the adapted
`.chat` backend, using a local mock Responses API.

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

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    MockResponsesServer,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)


FIRST_USER_TEXT = "CLI parity first durable turn."
SECOND_USER_TEXT = "CLI parity resume turn."
FIRST_ASSISTANT_TEXT = "CLI parity first answer from mock model."
SECOND_ASSISTANT_TEXT = "CLI parity resumed answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/src/cli.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/utils/cli/src/shared_options.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_durable_turn_smoke.py",
]


class SequenceMockResponsesServer(MockResponsesServer):
    def __init__(self, answers: list[str]) -> None:
        super().__init__(answers[-1])
        self.answers = answers

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        answer = self.answers[min(counter - 1, len(self.answers) - 1)]
        return sse_response(
            f"resp-cli-exec-resume-smoke-{counter}",
            f"msg-cli-exec-resume-smoke-{counter}",
            answer,
        )


def parse_jsonl(stdout: str) -> list[dict[str, Any]]:
    events = []
    for line in stdout.splitlines():
        if not line.strip():
            continue
        events.append(json.loads(line))
    return events


def normalize_exec_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized = []
    for event in events:
        event_type = event.get("type")
        if event_type == "thread.started":
            normalized.append({"type": event_type, "thread_id_present": bool(event.get("thread_id"))})
            continue
        if event_type == "item.completed":
            item = event.get("item") or {}
            normalized.append(
                {
                    "type": event_type,
                    "item_type": item.get("type"),
                    "message": item.get("message"),
                    "text": item.get("text"),
                }
            )
            continue
        if event_type == "turn.completed":
            usage = event.get("usage") or {}
            normalized.append(
                {
                    "type": event_type,
                    "usage": {
                        "input_tokens": usage.get("input_tokens"),
                        "cached_input_tokens": usage.get("cached_input_tokens"),
                        "output_tokens": usage.get("output_tokens"),
                        "reasoning_output_tokens": usage.get("reasoning_output_tokens"),
                    },
                }
            )
            continue
        normalized.append({"type": event_type})
    return normalized


def thread_ids_from_events(events: list[dict[str, Any]]) -> list[str]:
    return [
        event["thread_id"]
        for event in events
        if event.get("type") == "thread.started" and event.get("thread_id")
    ]


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_response_model": first_body.get("model"),
        "second_response_model": second_body.get("model"),
        "first_body_contains_first_user_text": body_contains(first_body, FIRST_USER_TEXT),
        "first_body_contains_second_user_text": body_contains(first_body, SECOND_USER_TEXT),
        "second_body_contains_first_user_text": body_contains(second_body, FIRST_USER_TEXT),
        "second_body_contains_first_assistant_text": body_contains(
            second_body, FIRST_ASSISTANT_TEXT
        ),
        "second_body_contains_second_user_text": body_contains(second_body, SECOND_USER_TEXT),
    }


def run_cli_command(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    prompt: str,
    *,
    resume_last: bool,
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
        ]
    )
    if resume_last:
        command.extend(["resume", "--last", prompt])
    else:
        command.append(prompt)

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
        timeout=90,
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
        "normalized_events": normalize_exec_events(events),
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
    projections = sorted(
        item.relative_to(package).as_posix()
        for item in (package / "projections").glob("*.ndjson")
    )
    return {
        "package_exists": True,
        "package": str(package),
        "timeline_event_types": [line.get("type") for line in timeline],
        "journal_entry_count": len(journal),
        "projection_files": projections,
        "has_chat_read_projection": "projections/chat-read.ndjson" in projections,
        "has_model_context_projection": "projections/model-context.ndjson" in projections,
        "has_audit_projection": "projections/audit.ndjson" in projections,
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

    with SequenceMockResponsesServer(
        [FIRST_ASSISTANT_TEXT, SECOND_ASSISTANT_TEXT]
    ) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FIRST_USER_TEXT,
            resume_last=False,
        )
        resume_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            SECOND_USER_TEXT,
            resume_last=True,
        )

        result: dict[str, Any] = {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "first_exec": first_exec,
            "resume_exec": resume_exec,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
        }
        first_thread_ids = first_exec["thread_ids"]
        resume_thread_ids = resume_exec["thread_ids"]
        result["same_thread_id_on_resume"] = (
            len(first_thread_ids) == 1
            and len(resume_thread_ids) == 1
            and first_thread_ids[0] == resume_thread_ids[0]
        )
        if tree_name == "chat-backend":
            result["chat_storage"] = summarize_chat_line_counts(chat_root)
            result["chat_package_files"] = inspect_chat_package_files(chat_root)
        else:
            result["original_storage"] = summarize_rollout_line_counts(codex_home)
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-exec-resume-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_first_events = original_result["first_exec"]["normalized_events"]
    chat_first_events = chat_result["first_exec"]["normalized_events"]
    original_resume_events = original_result["resume_exec"]["normalized_events"]
    chat_resume_events = chat_result["resume_exec"]["normalized_events"]
    original_lines = original_result["original_storage"]["total_rollout_lines"]
    chat_journal_lines = chat_result["chat_storage"]["total_journal_lines"]
    chat_package = chat_result["chat_package_files"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-exec-resume-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_first_exec_exit_ok": original_result["first_exec"]["exit_code"] == 0,
        "chat_backend_first_exec_exit_ok": chat_result["first_exec"]["exit_code"] == 0,
        "original_resume_exec_exit_ok": original_result["resume_exec"]["exit_code"] == 0,
        "chat_backend_resume_exec_exit_ok": chat_result["resume_exec"]["exit_code"] == 0,
        "first_exec_normalized_events_equal": original_first_events == chat_first_events,
        "resume_exec_normalized_events_equal": original_resume_events == chat_resume_events,
        "original_same_thread_id_on_resume": original_result["same_thread_id_on_resume"],
        "chat_backend_same_thread_id_on_resume": chat_result["same_thread_id_on_resume"],
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
            == 2
        ),
        "mock_resume_context_equal": (
            original_result["mock_server_summary"]
            == chat_result["mock_server_summary"]
        ),
        "resume_request_contains_prior_context": (
            original_result["mock_server_summary"]["second_body_contains_first_user_text"]
            and original_result["mock_server_summary"][
                "second_body_contains_first_assistant_text"
            ]
            and original_result["mock_server_summary"]["second_body_contains_second_user_text"]
            and chat_result["mock_server_summary"]["second_body_contains_first_user_text"]
            and chat_result["mock_server_summary"][
                "second_body_contains_first_assistant_text"
            ]
            and chat_result["mock_server_summary"]["second_body_contains_second_user_text"]
        ),
        "original_rollout_lines_equal_chat_journal_lines": (
            original_lines == chat_journal_lines and original_lines > 0
        ),
        "chat_package_materialized": (
            chat_result["chat_storage"]["package_count"] == 1
            and chat_package.get("package_exists") is True
            and chat_package.get("has_chat_read_projection") is True
            and chat_package.get("has_model_context_projection") is True
            and chat_package.get("has_audit_projection") is True
        ),
        "chat_timeline_has_core_events": (
            "runtime_context_snapshot" in set(chat_package.get("timeline_event_types") or [])
            and "message" in set(chat_package.get("timeline_event_types") or [])
        ),
        "original": {
            "first_exec": {
                "command": original_result["first_exec"]["command"],
                "exit_code": original_result["first_exec"]["exit_code"],
                "normalized_events": original_first_events,
                "thread_ids": original_result["first_exec"]["thread_ids"],
                "stderr_tail": original_result["first_exec"]["stderr_tail"],
            },
            "resume_exec": {
                "command": original_result["resume_exec"]["command"],
                "exit_code": original_result["resume_exec"]["exit_code"],
                "normalized_events": original_resume_events,
                "thread_ids": original_result["resume_exec"]["thread_ids"],
                "stderr_tail": original_result["resume_exec"]["stderr_tail"],
            },
            "mock_server_summary": original_result["mock_server_summary"],
            "storage": original_result["original_storage"],
        },
        "chat_backend": {
            "first_exec": {
                "command": chat_result["first_exec"]["command"],
                "exit_code": chat_result["first_exec"]["exit_code"],
                "normalized_events": chat_first_events,
                "thread_ids": chat_result["first_exec"]["thread_ids"],
                "stderr_tail": chat_result["first_exec"]["stderr_tail"],
            },
            "resume_exec": {
                "command": chat_result["resume_exec"]["command"],
                "exit_code": chat_result["resume_exec"]["exit_code"],
                "normalized_events": chat_resume_events,
                "thread_ids": chat_result["resume_exec"]["thread_ids"],
                "stderr_tail": chat_result["resume_exec"]["stderr_tail"],
            },
            "mock_server_summary": chat_result["mock_server_summary"],
            "storage": chat_result["chat_storage"],
            "chat_package_files": chat_package,
        },
    }

    passed = all(
        [
            summary["original_first_exec_exit_ok"],
            summary["chat_backend_first_exec_exit_ok"],
            summary["original_resume_exec_exit_ok"],
            summary["chat_backend_resume_exec_exit_ok"],
            summary["first_exec_normalized_events_equal"],
            summary["resume_exec_normalized_events_equal"],
            summary["original_same_thread_id_on_resume"],
            summary["chat_backend_same_thread_id_on_resume"],
            summary["mock_response_request_counts_equal"],
            summary["mock_resume_context_equal"],
            summary["resume_request_contains_prior_context"],
            summary["original_rollout_lines_equal_chat_journal_lines"],
            summary["chat_package_materialized"],
            summary["chat_timeline_has_core_events"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow CLI C02/C03/R01 slice: `codex exec` and "
        "`codex exec resume --last` produce matching normalized user-visible "
        "JSONL events, resume with prior context, preserve original durable "
        "line counts in the .chat journal, and materialize standard .chat "
        "package files. It is not full CLI parity."
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
