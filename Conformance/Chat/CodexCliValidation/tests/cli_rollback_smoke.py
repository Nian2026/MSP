#!/usr/bin/env python3
"""Run a real CLI/TUI backtrack rollback parity smoke.

This source-backed validation uses ordinary user-facing Codex CLI entry points:

    codex
    type two prompts into the TUI
    press Esc, Esc, Enter to trigger backtrack rollback
    codex exec --json resume --last ...

The middle command enters the interactive TUI, so the test drives it through a
PTY and waits for the durable rollback marker to appear. This proves only a
narrow CLI RB01-adjacent slice; it is not final rollback parity or a
user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import errno
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


FIRST_USER_TEXT = "CLI rollback first durable turn."
SECOND_USER_TEXT = "CLI rollback second turn to remove."
FOLLOWUP_USER_TEXT = "CLI rollback follow-up after backtrack."
FIRST_ASSISTANT_TEXT = "CLI rollback first answer from mock model."
SECOND_ASSISTANT_TEXT = "CLI rollback second answer that must disappear."
FOLLOWUP_ASSISTANT_TEXT = "CLI rollback follow-up answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_compaction_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/input.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_backtrack.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_server_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

ANSI_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
TERMINAL_PROBE_RESPONSE = (
    b"\x1b[20;10R"
    b"\x1b]10;rgb:eeee/eeee/eeee\x07"
    b"\x1b]11;rgb:1111/1111/1111\x07"
    b"\x1b[?64;1;2c"
    b"\x1b[?7u"
)


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
    followup_body = bodies[2] if len(bodies) > 2 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_first_user_text": body_contains(first_body, FIRST_USER_TEXT),
        "first_body_contains_second_user_text": body_contains(first_body, SECOND_USER_TEXT),
        "second_body_contains_first_user_text": body_contains(second_body, FIRST_USER_TEXT),
        "second_body_contains_first_assistant_text": body_contains(
            second_body, FIRST_ASSISTANT_TEXT
        ),
        "second_body_contains_second_user_text": body_contains(second_body, SECOND_USER_TEXT),
        "followup_body_contains_first_user_text": body_contains(followup_body, FIRST_USER_TEXT),
        "followup_body_contains_first_assistant_text": body_contains(
            followup_body, FIRST_ASSISTANT_TEXT
        ),
        "followup_body_contains_second_user_text": body_contains(
            followup_body, SECOND_USER_TEXT
        ),
        "followup_body_contains_second_assistant_text": body_contains(
            followup_body, SECOND_ASSISTANT_TEXT
        ),
        "followup_body_contains_followup_user_text": body_contains(
            followup_body, FOLLOWUP_USER_TEXT
        ),
    }


def is_rollback_record(record: dict[str, Any]) -> bool:
    if record.get("type") == "timeline_rollback":
        return True
    if record.get("type") == "event_msg":
        return (record.get("payload") or {}).get("type") == "thread_rolled_back"
    if record.get("entry_type") == "source_transport":
        source_payload = ((record.get("source_transport") or {}).get("payload") or {})
        return (
            source_payload.get("type") == "event_msg"
            and (source_payload.get("payload") or {}).get("type") == "thread_rolled_back"
        )
    return False


def count_rollback_records_in_file(path: pathlib.Path) -> int:
    if not path.exists() or path.is_dir():
        return 0
    try:
        records = read_json_lines(path)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return 0
    return sum(1 for record in records if is_rollback_record(record))


def is_session_rollout_path(path: pathlib.Path, codex_home: pathlib.Path) -> bool:
    try:
        relative = path.relative_to(codex_home).as_posix()
    except ValueError:
        return False
    return relative.startswith("sessions/") or relative.startswith("archived_sessions/")


def count_rollback_markers(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> int:
    if tree_name == "chat-backend":
        return sum(
            count_rollback_records_in_file(path)
            for path in chat_root.glob("*.chat/timeline.ndjson")
        )
    return sum(
        count_rollback_records_in_file(path)
        for path in codex_home.rglob("*.jsonl")
        if is_session_rollout_path(path, codex_home)
    )


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(
        1 for request in requests if request.get("path", "").endswith("/responses")
    )


def type_prompt_and_enter(master: int, text: str) -> None:
    for byte in text.encode():
        os.write(master, bytes([byte]))
        time.sleep(0.004)
    time.sleep(0.2)
    os.write(master, b"\r")


def run_cli_two_turns_and_backtrack_tui(
    tree_name: str,
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    rollback_markers_before = count_rollback_markers(tree_name, codex_home, chat_root)

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
    sent_probe_response = False
    sent_trust_answer = False
    sent_trust_continue = False
    sent_term_gate_answer = False
    sent_first_prompt = False
    sent_second_prompt = False
    first_response_seen_at: float | None = None
    first_answer_visible_at: float | None = None
    second_prompt_sent_at: float | None = None
    second_enter_retry_sent = False
    second_response_seen_at: float | None = None
    second_answer_visible_at: float | None = None
    sent_first_escape = False
    sent_second_escape = False
    sent_backtrack_enter = False
    sent_ctrl_c = False
    rollback_marker_seen_at: float | None = None

    try:
        while time.time() - started_at < 60:
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

            visible_tail = output.decode(errors="replace")[-1800:]
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

            ready_for_prompt = (
                "OpenAICodex" in compact_visible_tail
                and "mock-model" in compact_visible_tail
                and (
                    sent_trust_continue
                    or "Doyoutrustthecontentsofthisdirectory?"
                    not in compact_visible_tail
                )
            )
            if ready_for_prompt and not sent_first_prompt:
                type_prompt_and_enter(master, FIRST_USER_TEXT)
                sent_first_prompt = True

            requests_seen = response_request_count(mock_server.requests)
            if sent_first_prompt and requests_seen >= 1 and first_response_seen_at is None:
                first_response_seen_at = time.time()
            output_text = output.decode(errors="replace")
            if (
                first_response_seen_at is not None
                and FIRST_ASSISTANT_TEXT in output_text
                and first_answer_visible_at is None
            ):
                first_answer_visible_at = time.time()
            if (
                first_answer_visible_at is not None
                and time.time() - first_answer_visible_at > 1.5
                and not sent_second_prompt
            ):
                type_prompt_and_enter(master, SECOND_USER_TEXT)
                sent_second_prompt = True
                second_prompt_sent_at = time.time()
            if (
                sent_second_prompt
                and requests_seen < 2
                and second_prompt_sent_at is not None
                and time.time() - second_prompt_sent_at > 2
                and not second_enter_retry_sent
            ):
                os.write(master, b"\r")
                second_enter_retry_sent = True

            if sent_second_prompt and requests_seen >= 2 and second_response_seen_at is None:
                second_response_seen_at = time.time()
            if (
                second_response_seen_at is not None
                and SECOND_ASSISTANT_TEXT in output_text
                and second_answer_visible_at is None
            ):
                second_answer_visible_at = time.time()
            ready_for_backtrack = (
                second_answer_visible_at is not None
                and time.time() - second_answer_visible_at > 1.5
            )
            if ready_for_backtrack and not sent_first_escape:
                os.write(master, b"\x1b")
                sent_first_escape = True
                time.sleep(0.2)
            if sent_first_escape and not sent_second_escape:
                os.write(master, b"\x1b")
                sent_second_escape = True
                time.sleep(0.2)
            if sent_second_escape and not sent_backtrack_enter:
                os.write(master, b"\r")
                sent_backtrack_enter = True

            if sent_backtrack_enter and rollback_marker_seen_at is None:
                current_markers = count_rollback_markers(
                    tree_name,
                    codex_home,
                    chat_root,
                )
                if current_markers > rollback_markers_before:
                    rollback_marker_seen_at = time.time()

            if rollback_marker_seen_at is not None:
                if time.time() - rollback_marker_seen_at > 2 and not sent_ctrl_c:
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

    stripped_output = strip_ansi(output.decode(errors="replace"))
    rollback_markers_after = count_rollback_markers(tree_name, codex_home, chat_root)
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_first_prompt": sent_first_prompt,
        "sent_second_prompt": sent_second_prompt,
        "first_answer_visible": first_answer_visible_at is not None,
        "second_enter_retry_sent": second_enter_retry_sent,
        "first_response_seen": first_response_seen_at is not None,
        "second_response_seen": second_response_seen_at is not None,
        "second_answer_visible": second_answer_visible_at is not None,
        "sent_first_escape": sent_first_escape,
        "sent_second_escape": sent_second_escape,
        "sent_backtrack_enter": sent_backtrack_enter,
        "sent_ctrl_c": sent_ctrl_c,
        "rollback_markers_before": rollback_markers_before,
        "rollback_markers_after": rollback_markers_after,
        "rollback_marker_seen": rollback_marker_seen_at is not None,
        "output_tail_stripped": stripped_output[-3000:],
        "raw_output_bytes": len(output),
    }


def storage_summary(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> dict[str, Any]:
    return (
        summarize_chat_packages(chat_root)
        if tree_name == "chat-backend"
        else summarize_original_storage(codex_home)
    )


def durable_line_counts(summary: dict[str, Any], tree_name: str) -> list[int]:
    if tree_name == "chat-backend":
        return sorted(
            package.get("journal_line_count")
            for package in (summary.get("packages") or [])
            if package.get("journal_line_count") is not None
        )
    return sorted(
        item.get("line_count")
        for item in (summary.get("rollouts") or [])
        if item.get("line_count") is not None
        and (
            (item.get("path") or "").startswith("sessions/")
            or (item.get("path") or "").startswith("archived_sessions/")
        )
    )


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    packages = []
    for package_item in summary.get("packages") or []:
        package = pathlib.Path(package_item["package"])
        timeline = read_json_lines(package / "timeline.ndjson")
        journal = read_json_lines(package / "journal.ndjson")
        projections = sorted(
            item.relative_to(package).as_posix()
            for item in (package / "projections").glob("*.ndjson")
        )
        packages.append(
            {
                "conversation_id": package_item.get("conversation_id"),
                "timeline_line_count": len(timeline),
                "journal_line_count": len(journal),
                "timeline_event_types": [event.get("type") for event in timeline],
                "timeline_rollback_count": sum(
                    1 for event in timeline if event.get("type") == "timeline_rollback"
                ),
                "journal_rollback_marker_count": count_rollback_records_in_file(
                    package / "journal.ndjson"
                ),
                "projection_files": projections,
                "has_standard_projections": all(
                    projection in projections
                    for projection in [
                        "projections/chat-read.ndjson",
                        "projections/model-context.ndjson",
                        "projections/audit.ndjson",
                    ]
                ),
            }
        )
    return {
        "package_count": summary.get("package_count"),
        "packages": packages,
        "all_packages_have_standard_projections": all(
            package["has_standard_projections"] for package in packages
        )
        if packages
        else False,
        "total_timeline_rollback_count": sum(
            package["timeline_rollback_count"] for package in packages
        ),
        "total_journal_rollback_marker_count": sum(
            package["journal_rollback_marker_count"] for package in packages
        ),
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
        [FIRST_ASSISTANT_TEXT, SECOND_ASSISTANT_TEXT, FOLLOWUP_ASSISTANT_TEXT]
    ) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        rollback_tui = run_cli_two_turns_and_backtrack_tui(
            tree_name,
            codex_bin,
            workspace,
            codex_home,
            chat_root,
            config_overrides,
            mock_server,
        )
        after_rollback_storage = storage_summary(tree_name, codex_home, chat_root)
        followup_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_last=True,
        )
        final_storage = storage_summary(tree_name, codex_home, chat_root)
        return {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "rollback_tui": rollback_tui,
            "followup_exec": followup_exec,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "after_rollback_storage": after_rollback_storage,
            "final_storage": final_storage,
            "after_rollback_line_counts": durable_line_counts(
                after_rollback_storage,
                tree_name,
            ),
            "final_line_counts": durable_line_counts(final_storage, tree_name),
            "chat_package_summary": chat_package_observation(chat_root)
            if tree_name == "chat-backend"
            else None,
            "rollback_marker_count": count_rollback_markers(
                tree_name,
                codex_home,
                chat_root,
            ),
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-rollback-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_result = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_followup_events = normalize_exec_events(
        original_result["followup_exec"].get("events") or []
    )
    chat_followup_events = normalize_exec_events(
        chat_result["followup_exec"].get("events") or []
    )
    chat_package = chat_result["chat_package_summary"] or {}

    followup_context_ok = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["followup_body_contains_first_user_text"],
            chat_mock["followup_body_contains_first_user_text"],
            original_mock["followup_body_contains_first_assistant_text"],
            chat_mock["followup_body_contains_first_assistant_text"],
            original_mock["followup_body_contains_followup_user_text"],
            chat_mock["followup_body_contains_followup_user_text"],
            not original_mock["followup_body_contains_second_user_text"],
            not chat_mock["followup_body_contains_second_user_text"],
            not original_mock["followup_body_contains_second_assistant_text"],
            not chat_mock["followup_body_contains_second_assistant_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-rollback-smoke",
        "matrix_slice": ["RB01-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_rollback_tui_exit_ok": original_result["rollback_tui"].get("exit_code")
        == 0,
        "chat_backend_rollback_tui_exit_ok": chat_result["rollback_tui"].get("exit_code")
        == 0,
        "original_tui_prompts_and_responses_seen": all(
            [
                original_result["rollback_tui"].get("sent_first_prompt"),
                original_result["rollback_tui"].get("sent_second_prompt"),
                original_result["rollback_tui"].get("first_response_seen"),
                original_result["rollback_tui"].get("second_response_seen"),
            ]
        ),
        "chat_backend_tui_prompts_and_responses_seen": all(
            [
                chat_result["rollback_tui"].get("sent_first_prompt"),
                chat_result["rollback_tui"].get("sent_second_prompt"),
                chat_result["rollback_tui"].get("first_response_seen"),
                chat_result["rollback_tui"].get("second_response_seen"),
            ]
        ),
        "original_backtrack_keys_sent": all(
            [
                original_result["rollback_tui"].get("sent_first_escape"),
                original_result["rollback_tui"].get("sent_second_escape"),
                original_result["rollback_tui"].get("sent_backtrack_enter"),
            ]
        ),
        "chat_backend_backtrack_keys_sent": all(
            [
                chat_result["rollback_tui"].get("sent_first_escape"),
                chat_result["rollback_tui"].get("sent_second_escape"),
                chat_result["rollback_tui"].get("sent_backtrack_enter"),
            ]
        ),
        "original_rollback_marker_seen": original_result["rollback_tui"].get(
            "rollback_marker_seen"
        ),
        "chat_backend_rollback_marker_seen": chat_result["rollback_tui"].get(
            "rollback_marker_seen"
        ),
        "original_followup_exec_ok": original_result["followup_exec"].get("exit_code")
        == 0,
        "chat_backend_followup_exec_ok": chat_result["followup_exec"].get("exit_code")
        == 0,
        "normalized_followup_exec_equal": original_followup_events == chat_followup_events,
        "mock_request_summaries_equal": original_mock == chat_mock,
        "followup_context_excludes_rolled_back_turn": followup_context_ok,
        "rollback_marker_counts_equal": original_result["rollback_marker_count"]
        == chat_result["rollback_marker_count"],
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "durable_line_counts_equal_after_followup": original_result["final_line_counts"]
        == chat_result["final_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "chat_backend_timeline_rollback_event_present": chat_package.get(
            "total_timeline_rollback_count"
        )
        == 1,
        "chat_backend_standard_projections_ok": chat_package.get(
            "all_packages_have_standard_projections"
        ),
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_rollback_tui": original_result["rollback_tui"],
        "chat_backend_rollback_tui": chat_result["rollback_tui"],
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "rollback many turns RB02 through CLI",
            "cumulative rollback markers RB03 through CLI",
            "rollback during active turn RB04 through CLI",
            "rollback after compaction RB05 through CLI",
            "picker/overlay visual parity beyond Esc/Esc/Enter command success",
            "true process-kill rollback recovery",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }
    summary["passed"] = all(
        [
            summary["original_rollback_tui_exit_ok"],
            summary["chat_backend_rollback_tui_exit_ok"],
            summary["original_tui_prompts_and_responses_seen"],
            summary["chat_backend_tui_prompts_and_responses_seen"],
            summary["original_backtrack_keys_sent"],
            summary["chat_backend_backtrack_keys_sent"],
            summary["original_rollback_marker_seen"],
            summary["chat_backend_rollback_marker_seen"],
            summary["original_followup_exec_ok"],
            summary["chat_backend_followup_exec_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["followup_context_excludes_rolled_back_turn"],
            summary["rollback_marker_counts_equal"],
            summary["durable_line_counts_equal_after_followup"],
            summary["chat_backend_timeline_rollback_event_present"],
            summary["chat_backend_standard_projections_ok"],
        ]
    )

    write_json(output_dir / "original/cli-rollback-response.json", original_result)
    write_json(output_dir / "chat-backend/cli-rollback-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# CLI Rollback Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives ordinary user-facing CLI/TUI entry points and a local mock Responses
API.

## Scope

```text
codex
type two prompts in the real TUI
Esc, Esc, Enter in the real TUI backtrack flow
codex exec --json resume --last ...
```

This proves only a narrow RB01-adjacent CLI slice: the latest user turn can be
rolled back through the real TUI backtrack path, then a follow-up CLI resume
request excludes the rolled-back user/assistant turn while preserving earlier
context.

## Result

- passed: `{summary['passed']}`
- original rollback TUI exit ok: `{summary['original_rollback_tui_exit_ok']}`
- `.chat` rollback TUI exit ok: `{summary['chat_backend_rollback_tui_exit_ok']}`
- original TUI prompts/responses seen: `{summary['original_tui_prompts_and_responses_seen']}`
- `.chat` TUI prompts/responses seen: `{summary['chat_backend_tui_prompts_and_responses_seen']}`
- original rollback marker seen: `{summary['original_rollback_marker_seen']}`
- `.chat` rollback marker seen: `{summary['chat_backend_rollback_marker_seen']}`
- normalized follow-up exec equal: `{summary['normalized_followup_exec_equal']}`
- mock request summaries equal: `{summary['mock_request_summaries_equal']}`
- follow-up context excludes rolled-back turn: `{summary['followup_context_excludes_rolled_back_turn']}`
- rollback marker counts equal: `{summary['rollback_marker_counts_equal']}`
- durable line counts equal after follow-up: `{summary['durable_line_counts_equal_after_followup']}`
- `.chat` timeline rollback event present: `{summary['chat_backend_timeline_rollback_event_present']}`
- `.chat` standard projections ok: `{summary['chat_backend_standard_projections_ok']}`

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## TUI Observations

```json
{json.dumps({'original': summary['original_rollback_tui'], 'chat_backend': summary['chat_backend_rollback_tui']}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-rollback-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-rollback-response.json
```

## Not Yet Proven

This smoke does not prove rollback-many-turns, cumulative rollback markers,
rollback during active turn, rollback after compaction, picker/overlay visual
parity beyond successful Esc/Esc/Enter command dispatch, true process-kill
rollback recovery, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
