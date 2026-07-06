#!/usr/bin/env python3
"""Run real CLI name/search lifecycle parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice that the
UUID-based lifecycle smoke does not cover:

    codex exec --json ...
    codex archive <session-name>
    codex unarchive <session-name>
    codex exec --json resume <session-name> ...

The name-based archive/unarchive path resolves the user-provided session name
through the app-server `thread/list` search path. The resume-by-name path also
exercises the public CLI name lookup surface before continuing the thread.

This compares the unmodified original backend with the adapted `.chat` backend.
It is not a final list/search picker or user-indistinguishability claim.
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

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    utc_now_iso,
    write_json,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
)
from cli_lifecycle_smoke import (  # noqa: E402
    normalize_lifecycle_stdout,
    run_cli_exec_command,
    run_lifecycle_command,
    summarize_chat_lifecycle,
    summarize_original_lifecycle,
)


SESSION_NAME = "CLI name search parity thread"
FOLLOWUP_USER_TEXT = "CLI name search parity resume by exact title."
FIRST_ASSISTANT_TEXT = "CLI name search first answer from mock model."
FOLLOWUP_ASSISTANT_TEXT = "CLI name search resumed answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_lifecycle_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_list_search_archive_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/exec/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/session_archive_commands.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/thread_metadata_sync.rs",
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
        "first_body_contains_session_name": body_contains(first_body, SESSION_NAME),
        "second_body_contains_session_name": body_contains(second_body, SESSION_NAME),
        "second_body_contains_first_assistant_text": body_contains(
            second_body, FIRST_ASSISTANT_TEXT
        ),
        "second_body_contains_followup_user_text": body_contains(
            second_body, FOLLOWUP_USER_TEXT
        ),
    }


def normalize_named_stdout(stdout: str, thread_id: str | None) -> str:
    return normalize_lifecycle_stdout(stdout, thread_id).replace(SESSION_NAME, "<session-name>")


def summarize_storage_after_name_lifecycle(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> dict[str, Any]:
    return (
        summarize_chat_lifecycle(chat_root)
        if tree_name == "chat-backend"
        else summarize_original_lifecycle(codex_home)
    )


def lifecycle_storage_ok(result: dict[str, Any], tree_name: str) -> dict[str, bool]:
    if tree_name == "chat-backend":
        first = result["storage_after_first"]
        archived = result["storage_after_archive_by_name"]
        unarchived = result["storage_after_unarchive_by_name"]
        after_resume = result["storage_after_resume_by_name"]
        return {
            "active_after_first": first["active_package_count"] == 1
            and first["archived_package_count"] == 0,
            "archived_after_name_archive": archived["active_package_count"] == 0
            and archived["archived_package_count"] == 1,
            "active_after_name_unarchive": unarchived["active_package_count"] == 1
            and unarchived["archived_package_count"] == 0,
            "active_after_name_resume": after_resume["active_package_count"] == 1
            and after_resume["archived_package_count"] == 0,
        }

    first = result["storage_after_first"]
    archived = result["storage_after_archive_by_name"]
    unarchived = result["storage_after_unarchive_by_name"]
    after_resume = result["storage_after_resume_by_name"]
    return {
        "active_after_first": first["active_rollout_count"] == 1
        and first["archived_rollout_count"] == 0,
        "archived_after_name_archive": archived["active_rollout_count"] == 0
        and archived["archived_rollout_count"] == 1,
        "active_after_name_unarchive": unarchived["active_rollout_count"] == 1
        and unarchived["archived_rollout_count"] == 0,
        "active_after_name_resume": after_resume["active_rollout_count"] == 1
        and after_resume["archived_rollout_count"] == 0,
    }


def durable_line_count_after_resume(result: dict[str, Any], tree_name: str) -> int:
    storage = result["storage_after_resume_by_name"]
    if tree_name == "chat-backend":
        return storage["total_journal_lines"]
    return storage["total_rollout_lines"]


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
        [FIRST_ASSISTANT_TEXT, FOLLOWUP_ASSISTANT_TEXT]
    ) as mock_server:
        from app_server_durable_turn_smoke import write_mock_config

        write_mock_config(codex_home, mock_server.url)
        first_exec = run_cli_exec_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            SESSION_NAME,
        )
        thread_ids = first_exec["thread_ids"]
        thread_id = thread_ids[0] if thread_ids else None
        if thread_id is None:
            raise RuntimeError(f"{tree_name}: first exec did not return a thread id")

        storage_after_first = summarize_storage_after_name_lifecycle(
            tree_name, codex_home, chat_root
        )
        archive_by_name = run_lifecycle_command(
            codex_bin, workspace, codex_home, config_overrides, "archive", SESSION_NAME
        )
        storage_after_archive_by_name = summarize_storage_after_name_lifecycle(
            tree_name, codex_home, chat_root
        )
        unarchive_by_name = run_lifecycle_command(
            codex_bin, workspace, codex_home, config_overrides, "unarchive", SESSION_NAME
        )
        storage_after_unarchive_by_name = summarize_storage_after_name_lifecycle(
            tree_name, codex_home, chat_root
        )
        resume_by_name = run_cli_exec_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_thread_id=SESSION_NAME,
        )
        storage_after_resume_by_name = summarize_storage_after_name_lifecycle(
            tree_name, codex_home, chat_root
        )

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "session_name": SESSION_NAME,
        "thread_id": thread_id,
        "first_exec": first_exec,
        "archive_by_name": archive_by_name,
        "unarchive_by_name": unarchive_by_name,
        "resume_by_name": resume_by_name,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "storage_after_first": storage_after_first,
        "storage_after_archive_by_name": storage_after_archive_by_name,
        "storage_after_unarchive_by_name": storage_after_unarchive_by_name,
        "storage_after_resume_by_name": storage_after_resume_by_name,
    }


def normalized_name_lifecycle(result: dict[str, Any]) -> dict[str, Any]:
    thread_id = result["thread_id"]
    return {
        "archive_by_name": {
            "exit_code": result["archive_by_name"]["exit_code"],
            "stdout": normalize_named_stdout(result["archive_by_name"]["stdout"], thread_id),
            "error_class": result["archive_by_name"]["error_class"],
        },
        "unarchive_by_name": {
            "exit_code": result["unarchive_by_name"]["exit_code"],
            "stdout": normalize_named_stdout(result["unarchive_by_name"]["stdout"], thread_id),
            "error_class": result["unarchive_by_name"]["error_class"],
        },
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Name Search Lifecycle Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final CLI parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Original first exec exit ok: `{summary['original_first_exec_exit_ok']}`",
        f"- `.chat` first exec exit ok: `{summary['chat_backend_first_exec_exit_ok']}`",
        f"- Name lifecycle outputs equal: `{summary['name_lifecycle_outputs_equal']}`",
        f"- Name lifecycle storage parity: `{summary['name_lifecycle_storage_checks_equal']}`",
        f"- Resume-by-name events equal: `{summary['resume_by_name_normalized_events_equal']}`",
        f"- Resume-by-name context preserved: `{summary['resume_by_name_contains_prior_context']}`",
        f"- Durable line counts equal: `{summary['original_rollout_lines_equal_chat_journal_lines_after_resume']}`",
        "",
        "## Scope",
        "",
        "The test creates a completed `codex exec --json` thread whose first user",
        "message becomes the session title, then resolves that session by name for",
        "`codex archive`, `codex unarchive`, and `codex exec --json resume <name>`.",
        "",
        "## Not Proven",
        "",
    ]
    lines.extend(f"- {item}" for item in summary["not_yet_proven"])
    (output_dir / "report.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-name-search-lifecycle-smoke-"
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_name_lifecycle = normalized_name_lifecycle(original_result)
    chat_name_lifecycle = normalized_name_lifecycle(chat_result)
    original_storage_ok = lifecycle_storage_ok(original_result, "original")
    chat_storage_ok = lifecycle_storage_ok(chat_result, "chat-backend")
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_first_events = original_result["first_exec"]["normalized_events"]
    chat_first_events = chat_result["first_exec"]["normalized_events"]
    original_resume_events = original_result["resume_by_name"]["normalized_events"]
    chat_resume_events = chat_result["resume_by_name"]["normalized_events"]
    original_lines_after_resume = durable_line_count_after_resume(original_result, "original")
    chat_lines_after_resume = durable_line_count_after_resume(chat_result, "chat-backend")

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-name-search-lifecycle-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "session_name": SESSION_NAME,
        "original_first_exec_exit_ok": original_result["first_exec"]["exit_code"] == 0,
        "chat_backend_first_exec_exit_ok": chat_result["first_exec"]["exit_code"] == 0,
        "first_exec_normalized_events_equal": original_first_events == chat_first_events,
        "name_lifecycle_outputs_equal": original_name_lifecycle == chat_name_lifecycle,
        "original_name_lifecycle": original_name_lifecycle,
        "chat_backend_name_lifecycle": chat_name_lifecycle,
        "name_lifecycle_storage_checks_equal": original_storage_ok == chat_storage_ok,
        "original_storage_checks": original_storage_ok,
        "chat_backend_storage_checks": chat_storage_ok,
        "original_resume_by_name_exit_ok": original_result["resume_by_name"]["exit_code"] == 0,
        "chat_backend_resume_by_name_exit_ok": chat_result["resume_by_name"]["exit_code"] == 0,
        "resume_by_name_normalized_events_equal": original_resume_events == chat_resume_events,
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 2
        ),
        "mock_resume_context_equal": original_mock == chat_mock,
        "resume_by_name_contains_prior_context": (
            original_mock["second_body_contains_session_name"]
            and original_mock["second_body_contains_first_assistant_text"]
            and original_mock["second_body_contains_followup_user_text"]
            and chat_mock["second_body_contains_session_name"]
            and chat_mock["second_body_contains_first_assistant_text"]
            and chat_mock["second_body_contains_followup_user_text"]
        ),
        "original_rollout_lines_equal_chat_journal_lines_after_resume": (
            original_lines_after_resume == chat_lines_after_resume
            and original_lines_after_resume > 0
        ),
        "original_rollout_lines_after_resume": original_lines_after_resume,
        "chat_journal_lines_after_resume": chat_lines_after_resume,
        "original": {
            "thread_id": original_result["thread_id"],
            "first_exec": {
                "command": original_result["first_exec"]["command"],
                "exit_code": original_result["first_exec"]["exit_code"],
                "normalized_events": original_first_events,
                "stderr_tail": original_result["first_exec"]["stderr_tail"],
            },
            "resume_by_name": {
                "command": original_result["resume_by_name"]["command"],
                "exit_code": original_result["resume_by_name"]["exit_code"],
                "normalized_events": original_resume_events,
                "stderr_tail": original_result["resume_by_name"]["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "storage": {
                "after_first": original_result["storage_after_first"],
                "after_archive_by_name": original_result["storage_after_archive_by_name"],
                "after_unarchive_by_name": original_result["storage_after_unarchive_by_name"],
                "after_resume_by_name": original_result["storage_after_resume_by_name"],
            },
        },
        "chat_backend": {
            "thread_id": chat_result["thread_id"],
            "first_exec": {
                "command": chat_result["first_exec"]["command"],
                "exit_code": chat_result["first_exec"]["exit_code"],
                "normalized_events": chat_first_events,
                "stderr_tail": chat_result["first_exec"]["stderr_tail"],
            },
            "resume_by_name": {
                "command": chat_result["resume_by_name"]["command"],
                "exit_code": chat_result["resume_by_name"]["exit_code"],
                "normalized_events": chat_resume_events,
                "stderr_tail": chat_result["resume_by_name"]["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "storage": {
                "after_first": chat_result["storage_after_first"],
                "after_archive_by_name": chat_result["storage_after_archive_by_name"],
                "after_unarchive_by_name": chat_result["storage_after_unarchive_by_name"],
                "after_resume_by_name": chat_result["storage_after_resume_by_name"],
            },
        },
    }

    passed = all(
        [
            summary["original_first_exec_exit_ok"],
            summary["chat_backend_first_exec_exit_ok"],
            summary["first_exec_normalized_events_equal"],
            summary["name_lifecycle_outputs_equal"],
            summary["name_lifecycle_storage_checks_equal"],
            summary["original_resume_by_name_exit_ok"],
            summary["chat_backend_resume_by_name_exit_ok"],
            summary["resume_by_name_normalized_events_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_resume_context_equal"],
            summary["resume_by_name_contains_prior_context"],
            summary["original_rollout_lines_equal_chat_journal_lines_after_resume"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI name/search lifecycle slice: "
        "`codex archive <session-name>`, `codex unarchive <session-name>`, "
        "and `codex exec --json resume <session-name>` have matching normalized "
        "behavior, storage lifecycle state, resume context, and durable line "
        "counts between original and .chat backends. It is not final picker, "
        "list/search, crash, or parity evidence."
    )
    summary["not_yet_proven"] = [
        "interactive TUI resume picker list/search parity",
        "CLI archive/delete descendant ordering",
        "delete-by-name parity with interactive confirmation",
        "true process-kill archive/delete boundary",
        "broader relation/list edge cases",
        "complete CLI feature parity",
        "complete data fidelity",
        "final user-indistinguishability under all normal Codex usage",
    ]

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    write_markdown_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
