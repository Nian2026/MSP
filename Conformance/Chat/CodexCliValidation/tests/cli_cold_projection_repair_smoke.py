#!/usr/bin/env python3
"""Run a real CLI cold-package + projection-repair parity smoke.

This source-backed validation uses the user-facing `codex exec --json` path. It
creates a completed `.chat` backend turn, moves the package to the internal
cold representation, corrupts/removes/stales the materialized projections, and
then resumes with `codex exec --json resume --last`.

The original backend is run with the same prompts and mock Responses API as the
behavioral oracle. Disk layout is allowed to differ; user-visible CLI output and
resume context must remain equivalent.

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

from app_server_cold_package_smoke import (  # noqa: E402
    cold_package_path,
    move_plain_to_cold,
    plain_package_path,
    summarize_chat_representations,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_stale_projection_repair_smoke import (  # noqa: E402
    PROJECTION_FILES,
    mutate_projection,
    observe_package,
    projection_repaired,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    normalize_exec_events,
    parse_jsonl,
    response_request_bodies,
    thread_ids_from_events,
)


FIRST_USER_TEXT = "CLI cold projection first durable turn."
SECOND_USER_TEXT = "CLI cold projection resume turn."
FIRST_ASSISTANT_TEXT = "CLI cold projection first answer from mock model."
SECOND_ASSISTANT_TEXT = "CLI cold projection resumed answer from mock model."
SCENARIOS = (
    "missing-projection",
    "corrupt-projection",
    "stale-projection",
)

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_projection_repair_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
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


def active_chat_journal_lines(chat_root: pathlib.Path, thread_id: str | None) -> int:
    for package in [plain_package_path(chat_root, thread_id), cold_package_path(chat_root, thread_id)]:
        journal = package / "journal.ndjson"
        if journal.exists():
            return len([line for line in journal.read_text().splitlines() if line.strip()])
    return 0


def projections_repaired(observation: dict[str, Any], scenario: str) -> bool:
    return all(
        projection_repaired(observation, scenario, projection_kind)
        for projection_kind in PROJECTION_FILES
    )


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    scenario: str,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / scenario / "workspace"
    codex_home = run_root / tree_name / scenario / "codex-home"
    chat_root = run_root / tree_name / scenario / "chat-store"
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

        first_thread_ids = first_exec["thread_ids"]
        thread_id = first_thread_ids[0] if first_thread_ids else None
        cold_move: dict[str, Any] | None = None
        mutation: dict[str, Any] | None = None
        storage_after_first_turn: dict[str, Any] | None = None
        storage_after_mutation: dict[str, Any] | None = None
        plain_exists_after_mutation: bool | None = None
        cold_exists_after_mutation: bool | None = None
        if tree_name == "chat-backend":
            storage_after_first_turn = summarize_chat_representations(chat_root)
            cold_move = move_plain_to_cold(chat_root, thread_id)
            mutation = mutate_projection(chat_root, thread_id, scenario, "cold")
            storage_after_mutation = observe_package(chat_root, thread_id, "cold")
            plain_exists_after_mutation = plain_package_path(chat_root, thread_id).exists()
            cold_exists_after_mutation = cold_package_path(chat_root, thread_id).exists()

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
            "scenario": scenario,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "thread_id": thread_id,
            "first_exec": first_exec,
            "resume_exec": resume_exec,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
        }
        resume_thread_ids = resume_exec["thread_ids"]
        result["same_thread_id_on_resume"] = (
            len(first_thread_ids) == 1
            and len(resume_thread_ids) == 1
            and first_thread_ids[0] == resume_thread_ids[0]
        )
        if tree_name == "chat-backend":
            storage_after_resume = summarize_chat_representations(chat_root)
            plain_after_resume = observe_package(chat_root, thread_id, "plain")
            cold_after_resume = observe_package(chat_root, thread_id, "cold")
            result.update(
                {
                    "storage_after_first_turn": storage_after_first_turn,
                    "cold_move": cold_move,
                    "mutation": mutation,
                    "storage_after_mutation": storage_after_mutation,
                    "storage_after_resume": storage_after_resume,
                    "plain_after_resume": plain_after_resume,
                    "cold_after_resume": cold_after_resume,
                    "cold_move_succeeded": (cold_move or {}).get("moved") is True,
                    "plain_exists_after_mutation": plain_exists_after_mutation,
                    "cold_exists_after_mutation": cold_exists_after_mutation,
                    "cold_only_after_mutation": (
                        storage_after_mutation is not None
                        and storage_after_mutation["package_exists"] is True
                        and plain_exists_after_mutation is False
                        and cold_exists_after_mutation is True
                    ),
                    "resume_materialized_plain": (
                        plain_after_resume["package_exists"] is True
                        and cold_after_resume["package_exists"] is False
                    ),
                    "projections_repaired_after_resume": projections_repaired(
                        plain_after_resume, scenario
                    ),
                    "active_journal_lines": active_chat_journal_lines(chat_root, thread_id),
                }
            )
        else:
            result["original_storage"] = summarize_rollout_line_counts(codex_home)
        return result


def summarize_scenario(
    scenario: str,
    original_result: dict[str, Any],
    chat_result: dict[str, Any],
) -> dict[str, Any]:
    original_first_events = original_result["first_exec"]["normalized_events"]
    chat_first_events = chat_result["first_exec"]["normalized_events"]
    original_resume_events = original_result["resume_exec"]["normalized_events"]
    chat_resume_events = chat_result["resume_exec"]["normalized_events"]
    original_lines = original_result["original_storage"]["total_rollout_lines"]
    chat_journal_lines = chat_result["active_journal_lines"]
    mock_context_equal = (
        original_result["mock_server_summary"] == chat_result["mock_server_summary"]
    )
    resume_request_contains_prior_context = (
        original_result["mock_server_summary"]["second_body_contains_first_user_text"]
        and original_result["mock_server_summary"][
            "second_body_contains_first_assistant_text"
        ]
        and original_result["mock_server_summary"]["second_body_contains_second_user_text"]
        and chat_result["mock_server_summary"]["second_body_contains_first_user_text"]
        and chat_result["mock_server_summary"]["second_body_contains_first_assistant_text"]
        and chat_result["mock_server_summary"]["second_body_contains_second_user_text"]
    )
    passed = all(
        [
            original_result["first_exec"]["exit_code"] == 0,
            chat_result["first_exec"]["exit_code"] == 0,
            original_result["resume_exec"]["exit_code"] == 0,
            chat_result["resume_exec"]["exit_code"] == 0,
            original_first_events == chat_first_events,
            original_resume_events == chat_resume_events,
            original_result["same_thread_id_on_resume"],
            chat_result["same_thread_id_on_resume"],
            mock_context_equal,
            resume_request_contains_prior_context,
            original_lines == chat_journal_lines and original_lines > 0,
            chat_result["cold_move_succeeded"],
            chat_result["cold_only_after_mutation"],
            chat_result["resume_materialized_plain"],
            chat_result["projections_repaired_after_resume"],
        ]
    )
    return {
        "scenario": scenario,
        "passed": passed,
        "original_first_exec_exit_ok": original_result["first_exec"]["exit_code"] == 0,
        "chat_backend_first_exec_exit_ok": chat_result["first_exec"]["exit_code"] == 0,
        "original_resume_exec_exit_ok": original_result["resume_exec"]["exit_code"] == 0,
        "chat_backend_resume_exec_exit_ok": chat_result["resume_exec"]["exit_code"] == 0,
        "first_exec_normalized_events_equal": original_first_events == chat_first_events,
        "resume_exec_normalized_events_equal": original_resume_events == chat_resume_events,
        "original_same_thread_id_on_resume": original_result["same_thread_id_on_resume"],
        "chat_backend_same_thread_id_on_resume": chat_result["same_thread_id_on_resume"],
        "mock_resume_context_equal": mock_context_equal,
        "resume_request_contains_prior_context": resume_request_contains_prior_context,
        "original_rollout_lines_equal_chat_journal_lines": (
            original_lines == chat_journal_lines and original_lines > 0
        ),
        "original_rollout_lines": original_lines,
        "chat_journal_lines": chat_journal_lines,
        "chat_backend_cold_move_succeeded": chat_result["cold_move_succeeded"],
        "chat_backend_cold_only_after_mutation": chat_result["cold_only_after_mutation"],
        "chat_backend_resume_materialized_plain": chat_result["resume_materialized_plain"],
        "chat_backend_projections_repaired_after_resume": chat_result[
            "projections_repaired_after_resume"
        ],
        "projection_kinds": list(PROJECTION_FILES),
        "chat_plain_after_resume": chat_result["plain_after_resume"],
        "chat_cold_after_resume": chat_result["cold_after_resume"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-cold-projection-repair-smoke-"
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
    scenario_summaries = []
    scenario_results = {}
    for scenario in SCENARIOS:
        chat_store_root = run_root / "chat-backend" / scenario / "chat-store"
        original_result = run_tree(
            "original",
            ORIGINAL_CODEX_RS,
            run_root,
            [],
            scenario,
        )
        chat_result = run_tree(
            "chat-backend",
            CHAT_BACKEND_CODEX_RS,
            run_root,
            [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
            scenario,
        )
        scenario_results[scenario] = {
            "original": original_result,
            "chat_backend": chat_result,
        }
        scenario_summaries.append(
            summarize_scenario(scenario, original_result, chat_result)
        )
        scenario_dir = output_dir / scenario
        write_json(scenario_dir / "original-result.json", original_result)
        write_json(scenario_dir / "chat-backend-result.json", chat_result)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-cold-projection-repair-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "scenario_summaries": scenario_summaries,
        "all_checks_passed": all(item["passed"] for item in scenario_summaries),
        "claim": (
            "This proves a narrow CLI H01/H02/R01 projection-repair slice: "
            "`codex exec --json` creates a durable turn, the .chat package can "
            "be moved to the cold representation with missing/corrupt/stale "
            "projection caches, and `codex exec --json resume --last` "
            "materializes/rebuilds projections while preserving normalized "
            "user-visible CLI output, resume context, and durable line counts. "
            "It is not full CLI parity."
        ),
        "not_yet_proven": [
            "true process-kill projection/index write boundary",
            "crash during pending write",
            "true process-kill archive/delete boundary",
            "complete CLI feature parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    write_json(output_dir / "summary.json", summary)

    if not summary["all_checks_passed"]:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
