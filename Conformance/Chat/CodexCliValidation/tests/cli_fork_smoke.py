#!/usr/bin/env python3
"""Run a real CLI fork parity smoke through the interactive TUI entry.

This source-backed validation uses the user-facing Codex CLI path:

    codex exec --json ...
    codex fork <source-thread-id> ...

The fork command enters the interactive TUI, so the test runs it under a PTY,
waits for the fork prompt to reach the mock Responses API, and then exits the
TUI with Ctrl-C. This proves only a narrow CLI fork slice; it is not a final
fork parity or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import errno
import hashlib
import json
import os
import pathlib
import pty
import re
import select
import struct
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
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    normalize_exec_events,
    response_request_bodies,
    run_cli_command,
)


FIRST_USER_TEXT = "CLI fork source durable turn."
FORK_USER_TEXT = "CLI fork prompt after source history."
FIRST_ASSISTANT_TEXT = "CLI fork source answer from mock model."
FORK_ASSISTANT_TEXT = "CLI fork answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_lifecycle_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_fork_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_server_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

ANSI_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ROLLOUT_RE = re.compile(
    r"^(?:archived_sessions/)?sessions/\d{4}/\d{2}/\d{2}/"
    r"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?P<thread_id>.+)\.jsonl$"
)
TERMINAL_PROBE_RESPONSE = (
    b"\x1b[20;10R"
    b"\x1b]10;rgb:eeee/eeee/eeee\x07"
    b"\x1b]11;rgb:1111/1111/1111\x07"
    b"\x1b[?64;1;2c"
    b"\x1b[?7u"
)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strip_ansi(text: str) -> str:
    stripped = ANSI_RE.sub("", text)
    stripped = stripped.replace("\r", "\n")
    lines = [line.strip() for line in stripped.splitlines()]
    return "\n".join(line for line in lines if line)


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
        "first_body_contains_fork_user_text": body_contains(first_body, FORK_USER_TEXT),
        "second_body_contains_first_user_text": body_contains(second_body, FIRST_USER_TEXT),
        "second_body_contains_first_assistant_text": body_contains(
            second_body, FIRST_ASSISTANT_TEXT
        ),
        "second_body_contains_fork_user_text": body_contains(second_body, FORK_USER_TEXT),
    }


def rollout_session_meta(path: pathlib.Path) -> list[dict[str, Any]]:
    session_meta = []
    for line_number, line in enumerate(read_json_lines(path), start=1):
        if line.get("type") != "session_meta":
            continue
        payload = line.get("payload") or {}
        session_meta.append(
            {
                "line": line_number,
                "session_id": payload.get("session_id"),
                "id": payload.get("id"),
                "source": payload.get("source"),
                "forked_from_id": payload.get("forked_from_id"),
                "parent_thread_id": payload.get("parent_thread_id"),
                "history_mode": payload.get("history_mode"),
            }
        )
    return session_meta


def session_rollouts(codex_home: pathlib.Path) -> list[dict[str, Any]]:
    summary = summarize_original_storage(codex_home)
    rollouts = []
    for item in summary.get("rollouts", []):
        path = item.get("path") or ""
        match = ROLLOUT_RE.match(path)
        if not match:
            continue
        full_path = codex_home / path
        session_meta = rollout_session_meta(full_path) if full_path.exists() else []
        rollouts.append(
            {
                "thread_id": match.group("thread_id"),
                "path": path,
                "line_count": item.get("line_count"),
                "sha256": sha256_file(full_path) if full_path.exists() else None,
                "session_meta": session_meta[0] if session_meta else None,
                "session_meta_count": len(session_meta),
            }
        )
    return sorted(rollouts, key=lambda item: item["path"])


def original_thread_snapshot(codex_home: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {"thread_id": None, "exists": False}
    matches = [item for item in session_rollouts(codex_home) if item["thread_id"] == thread_id]
    if not matches:
        return {"thread_id": thread_id, "exists": False}
    item = matches[0]
    return {
        "thread_id": thread_id,
        "exists": True,
        "path": item["path"],
        "line_count": item["line_count"],
        "sha256": item["sha256"],
    }


def chat_package_snapshot(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {"thread_id": None, "exists": False}
    package = chat_root / f"{thread_id}.chat"
    if not package.exists():
        return {"thread_id": thread_id, "exists": False}
    timeline_path = package / "timeline.ndjson"
    journal_path = package / "journal.ndjson"
    timeline = read_json_lines(timeline_path)
    journal = read_json_lines(journal_path)
    return {
        "thread_id": thread_id,
        "exists": True,
        "package": str(package),
        "timeline_line_count": len(timeline),
        "journal_line_count": len(journal),
        "timeline_sha256": sha256_file(timeline_path) if timeline_path.exists() else None,
        "journal_sha256": sha256_file(journal_path) if journal_path.exists() else None,
        "timeline_event_types": [event.get("type") for event in timeline],
    }


def inspect_chat_packages(chat_root: pathlib.Path, source_thread_id: str | None) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    package_details = []
    for package in summary.get("packages", []):
        package_path = pathlib.Path(package["package"])
        manifest_path = package_path / "manifest.json"
        index_path = package_path / "indexes/thread-metadata.json"
        projections = sorted(
            item.relative_to(package_path).as_posix()
            for item in (package_path / "projections").glob("*.ndjson")
        )
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        index = json.loads(index_path.read_text()) if index_path.exists() else {}
        manifest_text = json.dumps(manifest, ensure_ascii=False, sort_keys=True)
        index_text = json.dumps(index, ensure_ascii=False, sort_keys=True)
        package_details.append(
            {
                "conversation_id": package.get("conversation_id"),
                "journal_line_count": package.get("journal_line_count"),
                "timeline_line_count": package.get("timeline_line_count"),
                "projection_files": projections,
                "has_standard_projections": all(
                    projection in projections
                    for projection in [
                        "projections/chat-read.ndjson",
                        "projections/model-context.ndjson",
                        "projections/audit.ndjson",
                    ]
                ),
                "manifest_conversation": manifest.get("conversation"),
                "index_thread_id": index.get("thread_id"),
                "index_forked_from_id": index.get("forked_from_id"),
                "mentions_source_thread": bool(source_thread_id)
                and source_thread_id in (manifest_text + index_text),
            }
        )
    return {
        "summary": summary,
        "packages": package_details,
        "package_count": summary.get("package_count"),
        "journal_line_counts": sorted(
            package.get("journal_line_count")
            for package in summary.get("packages", [])
            if package.get("journal_line_count") is not None
        ),
        "timeline_line_counts": sorted(
            package.get("timeline_line_count")
            for package in summary.get("packages", [])
            if package.get("timeline_line_count") is not None
        ),
        "all_packages_have_standard_projections": all(
            package["has_standard_projections"] for package in package_details
        )
        if package_details
        else False,
        "fork_package_mentions_source_thread": any(
            package["mentions_source_thread"]
            for package in package_details
            if package.get("conversation_id") != source_thread_id
        ),
    }


def summarize_original_sessions(
    codex_home: pathlib.Path,
    source_thread_id: str | None,
) -> dict[str, Any]:
    rollouts = session_rollouts(codex_home)
    return {
        "rollouts": rollouts,
        "session_rollout_count": len(rollouts),
        "thread_ids": sorted(item["thread_id"] for item in rollouts),
        "line_counts": sorted(item["line_count"] for item in rollouts),
        "total_session_rollout_lines": sum(item.get("line_count") or 0 for item in rollouts),
        "fork_rollout_records_source_relation": bool(source_thread_id)
        and any(
            item["thread_id"] != source_thread_id
            and (item.get("session_meta") or {}).get("forked_from_id") == source_thread_id
            for item in rollouts
        ),
    }


def run_cli_fork_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
    source_thread_id: str | None,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    if source_thread_id is not None:
        command.extend(["fork", source_thread_id, FORK_USER_TEXT])
    else:
        command.extend(["fork", "--last", FORK_USER_TEXT])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    master, slave = pty.openpty()
    try:
        import fcntl
        import termios

        winsize = struct.pack("HHHH", 30, 100, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)
    except OSError:
        pass
    started_at = time.time()
    process = subprocess.Popen(
        command,
        cwd=str(workspace),
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        text=False,
    )
    os.close(slave)

    output = b""
    sent_term_gate_answer = False
    sent_probe_response = False
    sent_trust_answer = False
    sent_trust_continue = False
    sent_ctrl_c = False
    second_response_seen_at: float | None = None

    try:
        while time.time() - started_at < 45:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    chunk = os.read(master, 8192)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk

            visible_tail = output.decode(errors="replace")[-1200:]
            compact_visible_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))
            if not sent_probe_response and (
                "\x1b[6n" in visible_tail
                or "]10;?" in visible_tail
                or "[?u" in visible_tail
            ):
                os.write(master, TERMINAL_PROBE_RESPONSE)
                sent_probe_response = True
            if (
                not sent_trust_answer
                and "Doyoutrustthecontentsofthisdirectory?" in compact_visible_tail
            ):
                os.write(master, b"1\r\r")
                sent_trust_answer = True
                sent_trust_continue = True
            if (
                sent_trust_answer
                and not sent_trust_continue
                and "Pressentertocontinue" in compact_visible_tail
            ):
                os.write(master, b"\r")
                sent_trust_continue = True
            if "Continue anyway?" in visible_tail and not sent_term_gate_answer:
                os.write(master, b"y\r")
                sent_term_gate_answer = True

            response_count = len(response_request_bodies(mock_server.requests))
            if response_count >= 2 and second_response_seen_at is None:
                second_response_seen_at = time.time()
            if (
                second_response_seen_at is not None
                and time.time() - second_response_seen_at > 3
                and not sent_ctrl_c
            ):
                os.write(master, b"\x03")
                sent_ctrl_c = True

            if process.poll() is not None:
                break

        if process.poll() is None:
            try:
                os.write(master, b"\x03")
                sent_ctrl_c = True
            except OSError:
                pass
            time.sleep(0.5)
        if process.poll() is None:
            process.terminate()
            time.sleep(0.5)
        if process.poll() is None:
            process.kill()
        exit_code = process.wait(timeout=5)
    finally:
        try:
            os.close(master)
        except OSError:
            pass

    output_text = output.decode(errors="replace")
    stripped_output = strip_ansi(output_text)
    return {
        "command": command,
        "mode": "explicit-session-id" if source_thread_id is not None else "--last",
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_ctrl_c": sent_ctrl_c,
        "second_response_seen": second_response_seen_at is not None,
        "output_tail_stripped": stripped_output[-3000:],
        "raw_output_bytes": len(output),
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
        [FIRST_ASSISTANT_TEXT, FORK_ASSISTANT_TEXT]
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
        source_thread_ids = first_exec["thread_ids"]
        source_thread_id = source_thread_ids[0] if len(source_thread_ids) == 1 else None
        source_snapshot_before_fork = (
            chat_package_snapshot(chat_root, source_thread_id)
            if tree_name == "chat-backend"
            else original_thread_snapshot(codex_home, source_thread_id)
        )
        pre_fork_storage = (
            inspect_chat_packages(chat_root, source_thread_id)
            if tree_name == "chat-backend"
            else summarize_original_sessions(codex_home, source_thread_id)
        )
        fork_tui = run_cli_fork_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
            source_thread_id,
        )
        post_fork_storage = (
            inspect_chat_packages(chat_root, source_thread_id)
            if tree_name == "chat-backend"
            else summarize_original_sessions(codex_home, source_thread_id)
        )
        source_snapshot_after_fork = (
            chat_package_snapshot(chat_root, source_thread_id)
            if tree_name == "chat-backend"
            else original_thread_snapshot(codex_home, source_thread_id)
        )

    if tree_name == "chat-backend":
        post_thread_ids = sorted(
            package.get("conversation_id")
            for package in post_fork_storage.get("packages", [])
            if package.get("conversation_id")
        )
    else:
        post_thread_ids = post_fork_storage.get("thread_ids", [])
    fork_thread_ids = [
        thread_id for thread_id in post_thread_ids if thread_id != source_thread_id
    ]

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "first_exec": first_exec,
        "source_thread_id": source_thread_id,
        "fork_thread_ids": fork_thread_ids,
        "fork_tui": fork_tui,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "pre_fork_storage": pre_fork_storage,
        "post_fork_storage": post_fork_storage,
        "source_snapshot_before_fork": source_snapshot_before_fork,
        "source_snapshot_after_fork": source_snapshot_after_fork,
        "source_durable_history_unchanged": (
            source_snapshot_before_fork == source_snapshot_after_fork
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-fork-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_session_lines = original_result["post_fork_storage"]["line_counts"]
    chat_journal_lines = chat_result["post_fork_storage"]["journal_line_counts"]
    fork_request_includes_source_history = (
        original_mock["second_body_contains_first_user_text"]
        and chat_mock["second_body_contains_first_user_text"]
        and original_mock["second_body_contains_first_assistant_text"]
        and chat_mock["second_body_contains_first_assistant_text"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-fork-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_first_exec_exit_ok": original_result["first_exec"]["exit_code"] == 0,
        "chat_backend_first_exec_exit_ok": chat_result["first_exec"]["exit_code"] == 0,
        "first_exec_normalized_events_equal": original_first_events == chat_first_events,
        "original_fork_tui_exit_ok": original_result["fork_tui"]["exit_code"] == 0,
        "chat_backend_fork_tui_exit_ok": chat_result["fork_tui"]["exit_code"] == 0,
        "original_fork_tui_reached_model": original_result["fork_tui"][
            "second_response_seen"
        ],
        "chat_backend_fork_tui_reached_model": chat_result["fork_tui"][
            "second_response_seen"
        ],
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 2
        ),
        "mock_fork_context_equal": original_mock == chat_mock,
        "fork_request_contains_fork_prompt": (
            original_mock["second_body_contains_fork_user_text"]
            and chat_mock["second_body_contains_fork_user_text"]
        ),
        "fork_request_prior_context_parity": (
            original_mock["second_body_contains_first_user_text"]
            == chat_mock["second_body_contains_first_user_text"]
            and original_mock["second_body_contains_first_assistant_text"]
            == chat_mock["second_body_contains_first_assistant_text"]
        ),
        "fork_request_includes_source_history": fork_request_includes_source_history,
        "original_source_thread_id_present": original_result["source_thread_id"] is not None,
        "chat_backend_source_thread_id_present": chat_result["source_thread_id"] is not None,
        "original_fork_thread_created": len(original_result["fork_thread_ids"]) == 1,
        "chat_backend_fork_thread_created": len(chat_result["fork_thread_ids"]) == 1,
        "original_source_durable_history_unchanged": original_result[
            "source_durable_history_unchanged"
        ],
        "chat_backend_source_durable_history_unchanged": chat_result[
            "source_durable_history_unchanged"
        ],
        "session_line_counts_equal_chat_journal_lines": (
            original_session_lines == chat_journal_lines and len(original_session_lines) == 2
        ),
        "chat_package_count_is_two": chat_result["post_fork_storage"]["package_count"] == 2,
        "chat_packages_have_standard_projections": chat_result["post_fork_storage"][
            "all_packages_have_standard_projections"
        ],
        "original_fork_rollout_records_source_relation": original_result[
            "post_fork_storage"
        ]["fork_rollout_records_source_relation"],
        "chat_fork_package_records_source_relation": chat_result["post_fork_storage"][
            "fork_package_mentions_source_thread"
        ],
        "original": {
            "first_exec": {
                "command": original_result["first_exec"]["command"],
                "exit_code": original_result["first_exec"]["exit_code"],
                "normalized_events": original_first_events,
                "thread_ids": original_result["first_exec"]["thread_ids"],
                "stderr_tail": original_result["first_exec"]["stderr_tail"],
            },
            "fork_tui": original_result["fork_tui"],
            "source_thread_id": original_result["source_thread_id"],
            "fork_thread_ids": original_result["fork_thread_ids"],
            "mock_server_summary": original_mock,
            "source_snapshot_before_fork": original_result["source_snapshot_before_fork"],
            "source_snapshot_after_fork": original_result["source_snapshot_after_fork"],
            "post_fork_storage": original_result["post_fork_storage"],
        },
        "chat_backend": {
            "first_exec": {
                "command": chat_result["first_exec"]["command"],
                "exit_code": chat_result["first_exec"]["exit_code"],
                "normalized_events": chat_first_events,
                "thread_ids": chat_result["first_exec"]["thread_ids"],
                "stderr_tail": chat_result["first_exec"]["stderr_tail"],
            },
            "fork_tui": chat_result["fork_tui"],
            "source_thread_id": chat_result["source_thread_id"],
            "fork_thread_ids": chat_result["fork_thread_ids"],
            "mock_server_summary": chat_mock,
            "source_snapshot_before_fork": chat_result["source_snapshot_before_fork"],
            "source_snapshot_after_fork": chat_result["source_snapshot_after_fork"],
            "post_fork_storage": chat_result["post_fork_storage"],
        },
    }

    passed = all(
        [
            summary["original_first_exec_exit_ok"],
            summary["chat_backend_first_exec_exit_ok"],
            summary["first_exec_normalized_events_equal"],
            summary["original_fork_tui_exit_ok"],
            summary["chat_backend_fork_tui_exit_ok"],
            summary["original_fork_tui_reached_model"],
            summary["chat_backend_fork_tui_reached_model"],
            summary["mock_response_request_counts_equal"],
            summary["mock_fork_context_equal"],
            summary["fork_request_contains_fork_prompt"],
            summary["fork_request_prior_context_parity"],
            summary["fork_request_includes_source_history"],
            summary["original_source_thread_id_present"],
            summary["chat_backend_source_thread_id_present"],
            summary["original_fork_thread_created"],
            summary["chat_backend_fork_thread_created"],
            summary["original_source_durable_history_unchanged"],
            summary["chat_backend_source_durable_history_unchanged"],
            summary["session_line_counts_equal_chat_journal_lines"],
            summary["chat_package_count_is_two"],
            summary["chat_packages_have_standard_projections"],
            summary["original_fork_rollout_records_source_relation"],
            summary["chat_fork_package_records_source_relation"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow CLI F01-adjacent slice: after a source `codex exec` "
        "turn, `codex fork <source-thread-id> <prompt>` through the real TUI entry "
        "creates a new durable fork on both original and .chat backends, sends an "
        "equivalent fork prompt request shape to the mock model, includes copied "
        "source history in the fork request, records source-relation metadata in "
        "both original rollout metadata and .chat package metadata, leaves source "
        "durable history unchanged, and materializes standard .chat projections. "
        "It does not prove `codex fork --last` selection semantics for "
        "non-interactive source threads, fork-by-turn-id, pathless forks, picker UI "
        "parity, interrupted active-turn fork through every surface, broader "
        "relation/list edge cases, or final user-indistinguishability."
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
