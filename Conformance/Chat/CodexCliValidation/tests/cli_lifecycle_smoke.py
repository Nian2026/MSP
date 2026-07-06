#!/usr/bin/env python3
"""Run real CLI archive/unarchive/delete lifecycle parity smoke.

This source-backed validation uses user-facing Codex CLI commands instead of only
driving app-server JSON-RPC directly:

    codex exec --json ...
    codex archive <thread-id>
    codex unarchive <thread-id>
    codex exec --json resume <thread-id> ...
    codex delete --force <thread-id>
    codex exec --json resume <thread-id> ...

The original backend is the behavioral oracle. Disk layout may differ, but
normal CLI output, resume context, lifecycle storage state, and post-delete
failure class must remain equivalent.

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
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    normalize_exec_events,
    parse_jsonl,
    response_request_bodies,
    thread_ids_from_events,
)


FIRST_USER_TEXT = "CLI lifecycle first durable turn."
SECOND_USER_TEXT = "CLI lifecycle resume after unarchive."
DELETE_RESUME_TEXT = "CLI lifecycle resume after delete should fail."
FIRST_ASSISTANT_TEXT = "CLI lifecycle first answer from mock model."
SECOND_ASSISTANT_TEXT = "CLI lifecycle resumed answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_list_search_archive_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/session_archive_commands.rs",
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
        "second_body_contains_first_user_text": body_contains(second_body, FIRST_USER_TEXT),
        "second_body_contains_first_assistant_text": body_contains(
            second_body, FIRST_ASSISTANT_TEXT
        ),
        "second_body_contains_second_user_text": body_contains(second_body, SECOND_USER_TEXT),
        "any_body_contains_delete_resume_text": any(
            body_contains(body, DELETE_RESUME_TEXT) for body in bodies
        ),
    }


def normalize_lifecycle_stdout(stdout: str, thread_id: str | None) -> str:
    text = stdout.strip()
    if thread_id:
        text = text.replace(thread_id, "<thread-id>")
    return text


def normalize_error_class(output: str, thread_id: str | None) -> str:
    text = output.strip()
    if thread_id:
        text = text.replace(thread_id, "<thread-id>")
    lower = text.lower()
    if not text:
        return "empty"
    if "no active or archived session found matching" in lower:
        return "session_not_found"
    if "thread not found" in lower or "not found" in lower:
        return "session_not_found"
    if "archived" in lower and "cannot" in lower:
        return "archived_not_resumable"
    return text[-600:]


def run_cli_exec_command(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    prompt: str,
    *,
    resume_thread_id: str | None = None,
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
    if resume_thread_id is None:
        command.append(prompt)
    else:
        command.extend(["resume", resume_thread_id, prompt])

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
        "error_class": normalize_error_class(
            "\n".join([completed.stdout, completed.stderr]), resume_thread_id
        ),
    }


def run_lifecycle_command(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    action: str,
    thread_id: str,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.append(action)
    if action == "delete":
        command.append("--force")
    command.append(thread_id)

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
    return {
        "command": command,
        "exit_code": completed.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stdout": completed.stdout,
        "stderr_tail": completed.stderr[-6000:],
        "normalized_stdout": normalize_lifecycle_stdout(completed.stdout, thread_id),
        "error_class": normalize_error_class(completed.stdout + completed.stderr, thread_id),
    }


def summarize_original_lifecycle(codex_home: pathlib.Path) -> dict[str, Any]:
    summary = summarize_original_storage(codex_home)
    rollouts = summary.get("rollouts") or []
    active = [
        item for item in rollouts if not item.get("path", "").startswith("archived_sessions/")
    ]
    archived = [
        item for item in rollouts if item.get("path", "").startswith("archived_sessions/")
    ]
    return {
        "summary": summary,
        "active_rollout_count": len(active),
        "archived_rollout_count": len(archived),
        "total_rollout_count": len(rollouts),
        "active_line_counts": [item.get("line_count") for item in active],
        "archived_line_counts": [item.get("line_count") for item in archived],
        "total_rollout_lines": sum(item.get("line_count", 0) for item in rollouts),
        "rollout_paths": sorted(item.get("path") for item in rollouts),
    }


def summarize_chat_lifecycle(chat_root: pathlib.Path) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    packages = summary.get("packages") or []
    package_summaries = []
    for package in packages:
        package_path = pathlib.Path(package["package"])
        manifest_path = package_path / "manifest.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        lifecycle = manifest.get("lifecycle") or {}
        package_summaries.append(
            {
                "package": package["package"],
                "archived": lifecycle.get("archived"),
                "timeline_line_count": package.get("timeline_line_count"),
                "journal_line_count": package.get("journal_line_count"),
                "index_exists": package.get("index_exists"),
                "manifest_format": package.get("manifest_format"),
            }
        )
    return {
        "summary": summary,
        "package_count": len(packages),
        "active_package_count": sum(item.get("archived") is False for item in package_summaries),
        "archived_package_count": sum(item.get("archived") is True for item in package_summaries),
        "unknown_lifecycle_package_count": sum(
            item.get("archived") not in (True, False) for item in package_summaries
        ),
        "total_journal_lines": sum(
            item.get("journal_line_count") or 0 for item in package_summaries
        ),
        "packages": package_summaries,
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
        first_exec = run_cli_exec_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FIRST_USER_TEXT,
        )
        first_thread_ids = first_exec["thread_ids"]
        thread_id = first_thread_ids[0] if first_thread_ids else None
        if thread_id is None:
            raise RuntimeError(f"{tree_name}: first exec did not return a thread id")

        storage_after_first = (
            summarize_chat_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_lifecycle(codex_home)
        )
        archive = run_lifecycle_command(
            codex_bin, workspace, codex_home, config_overrides, "archive", thread_id
        )
        storage_after_archive = (
            summarize_chat_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_lifecycle(codex_home)
        )
        unarchive = run_lifecycle_command(
            codex_bin, workspace, codex_home, config_overrides, "unarchive", thread_id
        )
        storage_after_unarchive = (
            summarize_chat_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_lifecycle(codex_home)
        )
        resume_after_unarchive = run_cli_exec_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            SECOND_USER_TEXT,
            resume_thread_id=thread_id,
        )
        storage_after_resume = (
            summarize_chat_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_lifecycle(codex_home)
        )
        delete = run_lifecycle_command(
            codex_bin, workspace, codex_home, config_overrides, "delete", thread_id
        )
        storage_after_delete = (
            summarize_chat_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_lifecycle(codex_home)
        )
        resume_after_delete = run_cli_exec_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            DELETE_RESUME_TEXT,
            resume_thread_id=thread_id,
        )

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "thread_id": thread_id,
        "first_exec": first_exec,
        "archive": archive,
        "unarchive": unarchive,
        "resume_after_unarchive": resume_after_unarchive,
        "delete": delete,
        "resume_after_delete": resume_after_delete,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "storage_after_first": storage_after_first,
        "storage_after_archive": storage_after_archive,
        "storage_after_unarchive": storage_after_unarchive,
        "storage_after_resume": storage_after_resume,
        "storage_after_delete": storage_after_delete,
    }


def lifecycle_storage_ok(result: dict[str, Any], tree_name: str) -> dict[str, bool]:
    if tree_name == "chat-backend":
        first = result["storage_after_first"]
        archived = result["storage_after_archive"]
        unarchived = result["storage_after_unarchive"]
        after_resume = result["storage_after_resume"]
        deleted = result["storage_after_delete"]
        return {
            "active_after_first": first["active_package_count"] == 1
            and first["archived_package_count"] == 0,
            "archived_after_archive": archived["active_package_count"] == 0
            and archived["archived_package_count"] == 1,
            "active_after_unarchive": unarchived["active_package_count"] == 1
            and unarchived["archived_package_count"] == 0,
            "active_after_resume": after_resume["active_package_count"] == 1
            and after_resume["archived_package_count"] == 0,
            "removed_after_delete": deleted["package_count"] == 0,
        }
    first = result["storage_after_first"]
    archived = result["storage_after_archive"]
    unarchived = result["storage_after_unarchive"]
    after_resume = result["storage_after_resume"]
    deleted = result["storage_after_delete"]
    return {
        "active_after_first": first["active_rollout_count"] == 1
        and first["archived_rollout_count"] == 0,
        "archived_after_archive": archived["active_rollout_count"] == 0
        and archived["archived_rollout_count"] == 1,
        "active_after_unarchive": unarchived["active_rollout_count"] == 1
        and unarchived["archived_rollout_count"] == 0,
        "active_after_resume": after_resume["active_rollout_count"] == 1
        and after_resume["archived_rollout_count"] == 0,
        "removed_after_delete": deleted["total_rollout_count"] == 0,
    }


def normalized_lifecycle(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "archive": {
            "exit_code": result["archive"]["exit_code"],
            "stdout": result["archive"]["normalized_stdout"],
            "error_class": result["archive"]["error_class"],
        },
        "unarchive": {
            "exit_code": result["unarchive"]["exit_code"],
            "stdout": result["unarchive"]["normalized_stdout"],
            "error_class": result["unarchive"]["error_class"],
        },
        "delete": {
            "exit_code": result["delete"]["exit_code"],
            "stdout": result["delete"]["normalized_stdout"],
            "error_class": result["delete"]["error_class"],
        },
        "resume_after_delete": {
            "exit_code_zero": result["resume_after_delete"]["exit_code"] == 0,
            "error_class": result["resume_after_delete"]["error_class"],
            "normalized_events": result["resume_after_delete"]["normalized_events"],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-lifecycle-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_lifecycle = normalized_lifecycle(original_result)
    chat_lifecycle = normalized_lifecycle(chat_result)
    original_storage_ok = lifecycle_storage_ok(original_result, "original")
    chat_storage_ok = lifecycle_storage_ok(chat_result, "chat-backend")

    original_first_events = original_result["first_exec"]["normalized_events"]
    chat_first_events = chat_result["first_exec"]["normalized_events"]
    original_resume_events = original_result["resume_after_unarchive"]["normalized_events"]
    chat_resume_events = chat_result["resume_after_unarchive"]["normalized_events"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    original_lines_after_resume = original_result["storage_after_resume"][
        "total_rollout_lines"
    ]
    chat_lines_after_resume = chat_result["storage_after_resume"]["total_journal_lines"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-lifecycle-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_first_exec_exit_ok": original_result["first_exec"]["exit_code"] == 0,
        "chat_backend_first_exec_exit_ok": chat_result["first_exec"]["exit_code"] == 0,
        "first_exec_normalized_events_equal": original_first_events == chat_first_events,
        "lifecycle_command_outputs_equal": original_lifecycle == chat_lifecycle,
        "original_lifecycle": original_lifecycle,
        "chat_backend_lifecycle": chat_lifecycle,
        "original_storage_lifecycle_ok": all(original_storage_ok.values()),
        "chat_backend_storage_lifecycle_ok": all(chat_storage_ok.values()),
        "original_storage_checks": original_storage_ok,
        "chat_backend_storage_checks": chat_storage_ok,
        "original_resume_after_unarchive_exit_ok": original_result[
            "resume_after_unarchive"
        ]["exit_code"]
        == 0,
        "chat_backend_resume_after_unarchive_exit_ok": chat_result[
            "resume_after_unarchive"
        ]["exit_code"]
        == 0,
        "resume_after_unarchive_normalized_events_equal": (
            original_resume_events == chat_resume_events
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 2
        ),
        "mock_resume_context_equal": original_mock == chat_mock,
        "resume_after_unarchive_contains_prior_context": (
            original_mock["second_body_contains_first_user_text"]
            and original_mock["second_body_contains_first_assistant_text"]
            and original_mock["second_body_contains_second_user_text"]
            and chat_mock["second_body_contains_first_user_text"]
            and chat_mock["second_body_contains_first_assistant_text"]
            and chat_mock["second_body_contains_second_user_text"]
        ),
        "delete_resume_failed_on_both": (
            original_result["resume_after_delete"]["exit_code"] != 0
            and chat_result["resume_after_delete"]["exit_code"] != 0
        ),
        "delete_resume_error_class_equal": (
            original_result["resume_after_delete"]["error_class"]
            == chat_result["resume_after_delete"]["error_class"]
        ),
        "delete_resume_did_not_call_model": (
            not original_mock["any_body_contains_delete_resume_text"]
            and not chat_mock["any_body_contains_delete_resume_text"]
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
            "resume_after_unarchive": {
                "command": original_result["resume_after_unarchive"]["command"],
                "exit_code": original_result["resume_after_unarchive"]["exit_code"],
                "normalized_events": original_resume_events,
                "stderr_tail": original_result["resume_after_unarchive"]["stderr_tail"],
            },
            "resume_after_delete": {
                "command": original_result["resume_after_delete"]["command"],
                "exit_code": original_result["resume_after_delete"]["exit_code"],
                "error_class": original_result["resume_after_delete"]["error_class"],
                "stderr_tail": original_result["resume_after_delete"]["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "storage": {
                "after_first": original_result["storage_after_first"],
                "after_archive": original_result["storage_after_archive"],
                "after_unarchive": original_result["storage_after_unarchive"],
                "after_resume": original_result["storage_after_resume"],
                "after_delete": original_result["storage_after_delete"],
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
            "resume_after_unarchive": {
                "command": chat_result["resume_after_unarchive"]["command"],
                "exit_code": chat_result["resume_after_unarchive"]["exit_code"],
                "normalized_events": chat_resume_events,
                "stderr_tail": chat_result["resume_after_unarchive"]["stderr_tail"],
            },
            "resume_after_delete": {
                "command": chat_result["resume_after_delete"]["command"],
                "exit_code": chat_result["resume_after_delete"]["exit_code"],
                "error_class": chat_result["resume_after_delete"]["error_class"],
                "stderr_tail": chat_result["resume_after_delete"]["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "storage": {
                "after_first": chat_result["storage_after_first"],
                "after_archive": chat_result["storage_after_archive"],
                "after_unarchive": chat_result["storage_after_unarchive"],
                "after_resume": chat_result["storage_after_resume"],
                "after_delete": chat_result["storage_after_delete"],
            },
        },
    }

    passed = all(
        [
            summary["original_first_exec_exit_ok"],
            summary["chat_backend_first_exec_exit_ok"],
            summary["first_exec_normalized_events_equal"],
            summary["lifecycle_command_outputs_equal"],
            summary["original_storage_lifecycle_ok"],
            summary["chat_backend_storage_lifecycle_ok"],
            summary["original_resume_after_unarchive_exit_ok"],
            summary["chat_backend_resume_after_unarchive_exit_ok"],
            summary["resume_after_unarchive_normalized_events_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_resume_context_equal"],
            summary["resume_after_unarchive_contains_prior_context"],
            summary["delete_resume_failed_on_both"],
            summary["delete_resume_error_class_equal"],
            summary["delete_resume_did_not_call_model"],
            summary["original_rollout_lines_equal_chat_journal_lines_after_resume"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI lifecycle slice: after `codex "
        "exec --json` creates a completed thread, `codex archive`, `codex "
        "unarchive`, `codex exec --json resume <id>`, and `codex delete "
        "--force` have matching normalized behavior, storage lifecycle state, "
        "resume context, and durable line counts between original and .chat "
        "backends. It is not full CLI lifecycle, crash, or parity evidence."
    )
    summary["not_yet_proven"] = [
        "CLI archive/delete descendant ordering",
        "true process-kill archive/delete boundary",
        "CLI fork/rollback/compaction parity",
        "CLI list/search interactive picker parity",
        "complete CLI feature parity",
        "complete data fidelity",
        "final user-indistinguishability under all normal Codex usage",
    ]

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
