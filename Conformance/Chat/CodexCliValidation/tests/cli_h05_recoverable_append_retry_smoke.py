#!/usr/bin/env python3
"""Run CLI H05 recoverable append-retry parity smoke.

This source-backed validation drives the user-facing `codex exec --json` path. The
adapted `.chat` backend runs the first exec turn with a one-shot recoverable
append failpoint after a durable canonical prefix has already reached
`journal.ndjson` and `timeline.ndjson`. The CLI process must still complete the
turn, avoid duplicating the durable prefix, and preserve resume behavior.

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
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
)
from app_server_h05_pending_write_failpoint_crash_smoke import (  # noqa: E402
    chat_journal_signatures,
    original_rollout_signatures,
)
from app_server_stale_projection_repair_smoke import (  # noqa: E402
    observe_package,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    normalize_exec_events,
    parse_jsonl,
    response_request_bodies,
    thread_ids_from_events,
)


FIRST_USER_TEXT = "CLI H05 recoverable retry first turn."
SECOND_USER_TEXT = "CLI H05 recoverable retry resume turn."
FIRST_ASSISTANT_TEXT = "CLI H05 recoverable retry first answer from mock model."
SECOND_ASSISTANT_TEXT = "CLI H05 recoverable retry resumed answer from mock model."

RECOVERABLE_FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT"
RECOVERABLE_MARKER_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT_MARKER"
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
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_recoverable_append_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_pending_write_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_projection_repair_smoke.py",
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
            second_body,
            FIRST_ASSISTANT_TEXT,
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
    extra_env: dict[str, str] | None = None,
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
    if extra_env:
        env.update(extra_env)

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
        "total_timeline_lines": sum(
            package.get("timeline_line_count", 0) for package in packages
        ),
        "total_journal_lines": sum(
            package.get("journal_line_count", 0) for package in packages
        ),
    }


def single_chat_package_path(chat_root: pathlib.Path, thread_id: str | None) -> pathlib.Path:
    if thread_id:
        return chat_root / f"{thread_id}.chat"
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        raise RuntimeError("no .chat package found")
    return packages[0]


def source_signatures_for_chat(chat_root: pathlib.Path, thread_id: str | None) -> list[dict[str, Any]]:
    return chat_journal_signatures(single_chat_package_path(chat_root, thread_id))


def valid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("valid_line_count") or 0)


def invalid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("invalid_line_count") or 0)


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    first_exec_extra_env: dict[str, str] | None = None,
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
            extra_env=first_exec_extra_env,
        )
        first_thread_ids = first_exec["thread_ids"]
        thread_id = first_thread_ids[0] if first_thread_ids else None

        first_storage: dict[str, Any]
        first_signatures: list[dict[str, Any]]
        first_observation: dict[str, Any] | None = None
        if tree_name == "chat-backend":
            first_storage = summarize_chat_line_counts(chat_root)
            first_signatures = source_signatures_for_chat(chat_root, thread_id)
            first_observation = observe_package(chat_root, thread_id, "plain")
        else:
            first_storage = summarize_rollout_line_counts(codex_home)
            first_signatures = original_rollout_signatures(codex_home)

        resume_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            SECOND_USER_TEXT,
            resume_last=True,
        )

        final_storage: dict[str, Any]
        final_signatures: list[dict[str, Any]]
        final_observation: dict[str, Any] | None = None
        if tree_name == "chat-backend":
            final_storage = summarize_chat_line_counts(chat_root)
            final_signatures = source_signatures_for_chat(chat_root, thread_id)
            final_observation = observe_package(chat_root, thread_id, "plain")
        else:
            final_storage = summarize_rollout_line_counts(codex_home)
            final_signatures = original_rollout_signatures(codex_home)

        resume_thread_ids = resume_exec["thread_ids"]
        return {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "thread_id": thread_id,
            "first_exec": first_exec,
            "resume_exec": resume_exec,
            "same_thread_id_on_resume": (
                len(first_thread_ids) == 1
                and len(resume_thread_ids) == 1
                and first_thread_ids[0] == resume_thread_ids[0]
            ),
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "storage_after_first_exec": first_storage,
            "storage_after_resume": final_storage,
            "source_signatures_after_first_exec": first_signatures,
            "source_signatures_after_resume": final_signatures,
            "observation_after_first_exec": first_observation,
            "observation_after_resume": final_observation,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-h05-recoverable-append-retry-smoke-"
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
    chat_store_root = run_root / "chat-backend" / "chat-store"
    marker_path = run_root / "chat-backend" / "recoverable-failpoint.marker"
    marker_path.parent.mkdir(parents=True, exist_ok=True)
    marker_path.write_text("fire-once\n")
    failpoint_env = {
        RECOVERABLE_FAILPOINT_ENV: FAILPOINT_NAME,
        RECOVERABLE_MARKER_ENV: str(marker_path),
        FAILPOINT_NEEDLE_ENV: FAILPOINT_NEEDLE,
    }

    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
        first_exec_extra_env=failpoint_env,
    )

    original_first_events = original_result["first_exec"]["normalized_events"]
    chat_first_events = chat_result["first_exec"]["normalized_events"]
    original_resume_events = original_result["resume_exec"]["normalized_events"]
    chat_resume_events = chat_result["resume_exec"]["normalized_events"]

    original_first_lines = original_result["storage_after_first_exec"][
        "total_rollout_lines"
    ]
    chat_first_journal_lines = chat_result["storage_after_first_exec"][
        "total_journal_lines"
    ]
    chat_first_timeline_lines = chat_result["storage_after_first_exec"][
        "total_timeline_lines"
    ]
    original_final_lines = original_result["storage_after_resume"]["total_rollout_lines"]
    chat_final_journal_lines = chat_result["storage_after_resume"][
        "total_journal_lines"
    ]
    chat_final_timeline_lines = chat_result["storage_after_resume"][
        "total_timeline_lines"
    ]

    first_observation = chat_result["observation_after_first_exec"] or {}
    final_observation = chat_result["observation_after_resume"] or {}

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-h05-recoverable-append-retry-smoke",
        "matrix_slice": ["H05", "C02", "C03", "R01"],
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
                "return one recoverable append error after a canonical prefix "
                "and before the next pending item in the first CLI exec turn"
            ),
        },
        "binary_checks": binary_checks,
        "chat_backend_marker_consumed_once": not marker_path.exists(),
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
        "first_exec_line_counts_match_original": (
            original_first_lines == chat_first_journal_lines == chat_first_timeline_lines
            and original_first_lines > 0
        ),
        "resume_line_counts_match_original": (
            original_final_lines == chat_final_journal_lines == chat_final_timeline_lines
            and original_final_lines > original_first_lines
        ),
        "first_exec_source_signatures_match_original": (
            chat_result["source_signatures_after_first_exec"]
            == original_result["source_signatures_after_first_exec"]
        ),
        "resume_source_signatures_match_original": (
            chat_result["source_signatures_after_resume"]
            == original_result["source_signatures_after_resume"]
        ),
        "chat_backend_projections_ok_after_first_exec": all_projections_repaired(
            first_observation
        ),
        "chat_backend_projections_ok_after_resume": all_projections_repaired(
            final_observation
        ),
        "chat_backend_no_invalid_canonical_lines": (
            invalid_line_count(first_observation, "timeline") == 0
            and invalid_line_count(first_observation, "journal") == 0
            and invalid_line_count(final_observation, "timeline") == 0
            and invalid_line_count(final_observation, "journal") == 0
        ),
        "first_exec_original_line_count": original_first_lines,
        "first_exec_chat_journal_line_count": chat_first_journal_lines,
        "first_exec_chat_timeline_line_count": chat_first_timeline_lines,
        "resume_original_line_count": original_final_lines,
        "resume_chat_journal_line_count": chat_final_journal_lines,
        "resume_chat_timeline_line_count": chat_final_timeline_lines,
        "chat_backend_first_valid_timeline_lines": valid_line_count(
            first_observation,
            "timeline",
        ),
        "chat_backend_resume_valid_timeline_lines": valid_line_count(
            final_observation,
            "timeline",
        ),
        "original_source_signatures_after_first_exec": original_result[
            "source_signatures_after_first_exec"
        ],
        "chat_backend_source_signatures_after_first_exec": chat_result[
            "source_signatures_after_first_exec"
        ],
        "original_source_signatures_after_resume": original_result[
            "source_signatures_after_resume"
        ],
        "chat_backend_source_signatures_after_resume": chat_result[
            "source_signatures_after_resume"
        ],
        "original_first_normalized_events": original_first_events,
        "chat_backend_first_normalized_events": chat_first_events,
        "original_resume_normalized_events": original_resume_events,
        "chat_backend_resume_normalized_events": chat_resume_events,
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original": original_result,
        "chat_backend": chat_result,
        "not_yet_proven": [
            "arbitrary transient filesystem I/O errors outside this validation failpoint",
            "CLI process-kill crash recovery during command execution, rollback, compaction, and cold transitions",
            "CLI live stdout/stderr streaming delta parity beyond aggregate command output",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
    }
    summary["passed"] = all(
        [
            summary["chat_backend_marker_consumed_once"],
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
            summary["first_exec_line_counts_match_original"],
            summary["resume_line_counts_match_original"],
            summary["first_exec_source_signatures_match_original"],
            summary["resume_source_signatures_match_original"],
            summary["chat_backend_projections_ok_after_first_exec"],
            summary["chat_backend_projections_ok_after_resume"],
            summary["chat_backend_no_invalid_canonical_lines"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow CLI H05 recoverable append-retry slice: the "
        "adapted .chat backend survives a one-shot recoverable append error "
        "during the first user-facing `codex exec --json` turn, drains the "
        "durable prefix without duplication, matches original normalized CLI "
        "JSONL output, preserves resume context through `resume --last`, keeps "
        "journal/timeline line counts equal to the original rollout, and "
        "matches source signatures after both first exec and resume. It is not "
        "final CLI parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)

    report = f"""# CLI H05 Recoverable Append Retry Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers the user-facing CLI H05 boundary where the adapted `.chat`
backend receives one recoverable append error after a canonical prefix has
already reached `journal.ndjson` and `timeline.ndjson`, then must retry only the
unwritten suffix and complete ordinary `codex exec --json` behavior.

The adapted backend uses:

```text
{RECOVERABLE_FAILPOINT_ENV}={FAILPOINT_NAME}
{RECOVERABLE_MARKER_ENV}={marker_path}
{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}
```

## Result

- one-shot marker was consumed: `{summary['chat_backend_marker_consumed_once']}`
- first exec exits match: original `{summary['original_first_exec_exit_ok']}`, `.chat` `{summary['chat_backend_first_exec_exit_ok']}`
- resume exits match: original `{summary['original_resume_exec_exit_ok']}`, `.chat` `{summary['chat_backend_resume_exec_exit_ok']}`
- first exec normalized JSONL events match: `{summary['first_exec_normalized_events_equal']}`
- resume normalized JSONL events match: `{summary['resume_exec_normalized_events_equal']}`
- resume context matches original: `{summary['mock_resume_context_equal']}`
- prior context is present in resume request: `{summary['resume_request_contains_prior_context']}`
- first exec line counts match: `{summary['first_exec_line_counts_match_original']}` (`{original_first_lines}` == `{chat_first_journal_lines}` == `{chat_first_timeline_lines}`)
- resume line counts match: `{summary['resume_line_counts_match_original']}` (`{original_final_lines}` == `{chat_final_journal_lines}` == `{chat_final_timeline_lines}`)
- first exec source signatures match original: `{summary['first_exec_source_signatures_match_original']}`
- resume source signatures match original: `{summary['resume_source_signatures_match_original']}`
- projections valid after first exec: `{summary['chat_backend_projections_ok_after_first_exec']}`
- projections valid after resume: `{summary['chat_backend_projections_ok_after_resume']}`
- no invalid canonical lines: `{summary['chat_backend_no_invalid_canonical_lines']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original-result.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend-result.json
```

## Not Yet Proven

This smoke does not prove arbitrary transient filesystem I/O failures outside
this validation failpoint, CLI process-kill crash recovery during command
execution/rollback/compaction/cold transitions, CLI live stdout/stderr streaming
delta parity beyond aggregate command output, final crash recovery parity, or
final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
