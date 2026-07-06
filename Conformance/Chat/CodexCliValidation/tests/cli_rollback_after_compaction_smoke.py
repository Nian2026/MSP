#!/usr/bin/env python3
"""Run a real CLI/TUI rollback-after-compaction parity smoke.

This source-backed validation uses ordinary user-facing Codex CLI entry points:

    codex
    type two prompts into the real TUI
    type /compact into the same TUI
    press Esc, Esc, Enter in the real TUI backtrack flow
    codex exec --json resume --last ...

The TUI backtrack UI targets user messages, not arbitrary control events. This
therefore proves only a narrow RB05-adjacent slice: a real rollback command is
issued after a real TUI compaction boundary, and the original backend remains
the oracle for which context survives into the follow-up turn.
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
    MockResponsesServer,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from cli_exec_resume_smoke import (  # noqa: E402
    normalize_exec_events,
    response_request_bodies,
    run_cli_command,
)
from cli_rollback_many_smoke import (  # noqa: E402
    clear_prefilled_composer,
    send_backtrack_confirm_key,
    send_backtrack_open_overlay_key,
    send_backtrack_prime_key,
    storage_text_presence,
)
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    body_contains,
    count_rollback_markers,
    durable_line_counts,
    response_request_count,
    strip_ansi,
    type_prompt_and_enter,
)


FIRST_USER_TEXT = "CLI rollback after compaction first durable turn."
SECOND_USER_TEXT = "CLI rollback after compaction second turn."
FOLLOWUP_USER_TEXT = "CLI rollback after compaction follow-up after backtrack."
FIRST_ASSISTANT_TEXT = "CLI rollback after compaction first answer."
SECOND_ASSISTANT_TEXT = "CLI rollback after compaction second answer."
COMPACTION_SUMMARY_TEXT = "CLI rollback after compaction compact summary."
FOLLOWUP_ASSISTANT_TEXT = "CLI rollback after compaction follow-up answer."
SUMMARY_PREFIX = "Summarize before CLI rollback after compaction."
ROLLBACK_MARKER_IDLE_SECONDS = 0.5

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
    "Conformance/Chat/CodexCliValidation/tests/cli_compaction_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_process_kill_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_many_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_after_compaction_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_backtrack.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/input.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/slash_dispatch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/rollout_reconstruction.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class RollbackAfterCompactionCliMockServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FOLLOWUP_ASSISTANT_TEXT)
        self._answers = [
            FIRST_ASSISTANT_TEXT,
            SECOND_ASSISTANT_TEXT,
            COMPACTION_SUMMARY_TEXT,
            FOLLOWUP_ASSISTANT_TEXT,
        ]

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text = self._answers[min(counter - 1, len(self._answers) - 1)]
        return sse_response(
            f"resp-cli-rollback-after-compaction-{counter}",
            f"msg-cli-rollback-after-compaction-{counter}",
            answer_text,
        )


def write_rb05_cli_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"
model_provider = "mock_provider"
compact_prompt = "{SUMMARY_PREFIX}"
model_auto_compact_token_limit = 1000

[model_providers.mock_provider]
name = "Mock provider for CLI rollback-after-compaction smoke"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    compaction_bodies = [
        body
        for body in bodies
        if body_contains(body, SUMMARY_PREFIX)
        and not body_contains(body, FOLLOWUP_USER_TEXT)
    ]
    followup_body = bodies[-1] if len(bodies) > 0 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_first_user_text": body_contains(first_body, FIRST_USER_TEXT),
        "first_body_contains_second_user_text": body_contains(first_body, SECOND_USER_TEXT),
        "second_body_contains_first_user_text": body_contains(second_body, FIRST_USER_TEXT),
        "second_body_contains_first_assistant_text": body_contains(
            second_body,
            FIRST_ASSISTANT_TEXT,
        ),
        "second_body_contains_second_user_text": body_contains(second_body, SECOND_USER_TEXT),
        "compaction_request_count": len(compaction_bodies),
        "any_compaction_request_contains_prompt": any(
            body_contains(body, SUMMARY_PREFIX) for body in compaction_bodies
        ),
        "any_compaction_request_contains_first_user_text": any(
            body_contains(body, FIRST_USER_TEXT) for body in compaction_bodies
        ),
        "any_compaction_request_contains_second_user_text": any(
            body_contains(body, SECOND_USER_TEXT) for body in compaction_bodies
        ),
        "followup_body_contains_first_user_text": body_contains(
            followup_body,
            FIRST_USER_TEXT,
        ),
        "followup_body_contains_first_assistant_text": body_contains(
            followup_body,
            FIRST_ASSISTANT_TEXT,
        ),
        "followup_body_contains_second_user_text": body_contains(
            followup_body,
            SECOND_USER_TEXT,
        ),
        "followup_body_contains_second_assistant_text": body_contains(
            followup_body,
            SECOND_ASSISTANT_TEXT,
        ),
        "followup_body_contains_compaction_summary": body_contains(
            followup_body,
            COMPACTION_SUMMARY_TEXT,
        ),
        "followup_body_contains_followup_user_text": body_contains(
            followup_body,
            FOLLOWUP_USER_TEXT,
        ),
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


def original_storage_detail(summary: dict[str, Any], codex_home: pathlib.Path) -> dict[str, Any]:
    lines: list[dict[str, Any]] = []
    for rollout in summary.get("rollouts") or []:
        path = rollout.get("path") or ""
        if not path.endswith(".jsonl") or not (
            path.startswith("sessions/") or path.startswith("archived_sessions/")
        ):
            continue
        lines.extend(read_json_lines(codex_home / path))
    serialized = json.dumps(lines, ensure_ascii=False)
    compacted = [line for line in lines if line.get("type") == "compacted"]
    replacement_history_counts = [
        len(((line.get("payload") or {}).get("replacement_history") or []))
        for line in compacted
    ]
    return {
        "rollout_line_count": len(lines),
        "compacted_count": len(compacted),
        "rollback_marker_count": serialized.count("thread_rolled_back")
        + serialized.count("ThreadRolledBack"),
        "has_replacement_history": any(count > 0 for count in replacement_history_counts),
        "replacement_history_counts": replacement_history_counts,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
        "contains_second_user_text": SECOND_USER_TEXT in serialized,
        "contains_compaction_summary": COMPACTION_SUMMARY_TEXT in serialized,
        "contains_rollback_marker": (
            "thread_rolled_back" in serialized or "ThreadRolledBack" in serialized
        ),
    }


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
        serialized = json.dumps({"timeline": timeline, "journal": journal}, ensure_ascii=False)
        rollback_events = [
            event for event in timeline if event.get("type") == "timeline_rollback"
        ]
        compaction_events = [
            event
            for event in timeline
            if event.get("type") == "durable_compaction_checkpoint"
        ]
        journal_compaction_events = [
            line
            for line in journal
            if ((line.get("source_transport") or {}).get("payload") or {}).get("type")
            == "compacted"
        ]
        packages.append(
            {
                "conversation_id": package_item.get("conversation_id"),
                "package": str(package),
                "timeline_line_count": len(timeline),
                "journal_line_count": len(journal),
                "timeline_event_types": [event.get("type") for event in timeline],
                "timeline_rollback_count": len(rollback_events),
                "timeline_rollback_num_turns": [
                    ((event.get("body") or {}).get("num_turns"))
                    for event in rollback_events
                ],
                "timeline_compaction_event_count": len(compaction_events),
                "journal_compaction_event_count": len(journal_compaction_events),
                "journal_rollback_marker_count": serialized.count("thread_rolled_back")
                + serialized.count("ThreadRolledBack"),
                "has_replacement_history": "replacement_history" in serialized,
                "contains_first_user_text": FIRST_USER_TEXT in serialized,
                "contains_second_user_text": SECOND_USER_TEXT in serialized,
                "contains_compaction_summary": COMPACTION_SUMMARY_TEXT in serialized,
                "contains_rollback_marker": (
                    "thread_rolled_back" in serialized
                    or "ThreadRolledBack" in serialized
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
        "journal_line_counts": sorted(
            package["journal_line_count"] for package in packages
        ),
        "timeline_line_counts": sorted(
            package["timeline_line_count"] for package in packages
        ),
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
        "total_timeline_compaction_event_count": sum(
            package["timeline_compaction_event_count"] for package in packages
        ),
        "total_journal_compaction_event_count": sum(
            package["journal_compaction_event_count"] for package in packages
        ),
        "timeline_rollback_num_turns": [
            num_turns
            for package in packages
            for num_turns in package["timeline_rollback_num_turns"]
        ],
        "any_package_has_replacement_history": any(
            package["has_replacement_history"] for package in packages
        ),
        "any_package_contains_compaction_summary": any(
            package["contains_compaction_summary"] for package in packages
        ),
    }


def run_cli_two_turns_compact_and_backtrack_tui(
    tree_name: str,
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    mock_server: RollbackAfterCompactionCliMockServer,
    kill_after_rollback_marker: bool,
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

        winsize = struct.pack("HHHH", 34, 110, 0, 0)
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
    model_ready_seen_at: float | None = None
    sent_first_prompt = False
    sent_second_prompt = False
    first_prompt_sent_at: float | None = None
    second_prompt_sent_at: float | None = None
    first_enter_retry_sent = False
    second_enter_retry_sent = False
    first_response_seen_at: float | None = None
    second_response_seen_at: float | None = None
    first_answer_visible_at: float | None = None
    second_answer_visible_at: float | None = None
    sent_compact_command = False
    compact_command_sent_at: float | None = None
    compaction_request_seen_at: float | None = None
    sent_backtrack_prime = False
    sent_backtrack_open_overlay = False
    backtrack_overlay_seen_at: float | None = None
    sent_backtrack_confirm = False
    backtrack_last_key_sent_at: float | None = None
    rollback_marker_seen_at: float | None = None
    killed_after_rollback_marker = False
    sent_clear_after_rollback = False
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 100:
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

            visible_tail = output.decode(errors="replace")[-2600:]
            compact_visible_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))
            lower_compact_visible_tail = compact_visible_tail.lower()
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

            if model_ready_seen_at is None and "model:mock-model" in compact_visible_tail:
                model_ready_seen_at = time.time()
            ready_for_prompt = (
                "OpenAICodex" in compact_visible_tail
                and model_ready_seen_at is not None
                and time.time() - model_ready_seen_at > 0.7
                and (
                    sent_trust_continue
                    or "Doyoutrustthecontentsofthisdirectory?"
                    not in compact_visible_tail
                )
            )
            if ready_for_prompt and not sent_first_prompt:
                type_prompt_and_enter(master, FIRST_USER_TEXT)
                sent_first_prompt = True
                first_prompt_sent_at = time.time()

            requests_seen = response_request_count(mock_server.requests)
            output_text = output.decode(errors="replace")
            if sent_first_prompt and requests_seen >= 1 and first_response_seen_at is None:
                first_response_seen_at = time.time()
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
                sent_first_prompt
                and requests_seen < 1
                and first_prompt_sent_at is not None
                and time.time() - first_prompt_sent_at > 2
                and not first_enter_retry_sent
            ):
                os.write(master, b"\r")
                first_enter_retry_sent = True
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

            if (
                second_answer_visible_at is not None
                and time.time() - second_answer_visible_at > 1.5
                and not sent_compact_command
            ):
                type_prompt_and_enter(master, "/compact")
                sent_compact_command = True
                compact_command_sent_at = time.time()

            if sent_compact_command and requests_seen >= 3 and compaction_request_seen_at is None:
                compaction_request_seen_at = time.time()

            ready_for_backtrack = (
                compaction_request_seen_at is not None
                and time.time() - compaction_request_seen_at > 3
            )
            if ready_for_backtrack and not sent_backtrack_prime:
                send_backtrack_prime_key(master)
                sent_backtrack_prime = True
                backtrack_last_key_sent_at = time.time()
            if (
                sent_backtrack_prime
                and not sent_backtrack_open_overlay
                and backtrack_last_key_sent_at is not None
                and time.time() - backtrack_last_key_sent_at > 0.7
            ):
                send_backtrack_open_overlay_key(master)
                sent_backtrack_open_overlay = True
                backtrack_last_key_sent_at = time.time()
            if (
                sent_backtrack_open_overlay
                and backtrack_overlay_seen_at is None
                and (
                    "/TRANSCRIPT/" in compact_visible_tail
                    or "entertoeditmessage" in lower_compact_visible_tail
                )
            ):
                backtrack_overlay_seen_at = time.time()

            overlay_ready_for_confirm = (
                backtrack_overlay_seen_at is not None
                or (
                    sent_backtrack_open_overlay
                    and backtrack_last_key_sent_at is not None
                    and time.time() - backtrack_last_key_sent_at > 1.6
                )
            )
            if (
                overlay_ready_for_confirm
                and not sent_backtrack_confirm
                and backtrack_last_key_sent_at is not None
                and time.time() - backtrack_last_key_sent_at > 0.7
            ):
                send_backtrack_confirm_key(master)
                sent_backtrack_confirm = True
                backtrack_last_key_sent_at = time.time()

            current_markers = count_rollback_markers(tree_name, codex_home, chat_root)
            if (
                sent_backtrack_confirm
                and rollback_marker_seen_at is None
                and current_markers >= rollback_markers_before + 1
            ):
                rollback_marker_seen_at = time.time()

            if rollback_marker_seen_at is not None:
                if kill_after_rollback_marker:
                    if (
                        time.time() - rollback_marker_seen_at
                        >= ROLLBACK_MARKER_IDLE_SECONDS
                    ):
                        process.kill()
                        killed_after_rollback_marker = True
                        break
                    continue
                if not sent_clear_after_rollback:
                    clear_prefilled_composer(master)
                    sent_clear_after_rollback = True
                if time.time() - rollback_marker_seen_at > 2 and not sent_ctrl_c:
                    os.write(master, b"\x03")
                    sent_ctrl_c = True

            if process.poll() is not None:
                break

        if process.poll() is None and not killed_after_rollback_marker:
            try:
                os.write(master, b"\x03")
                sent_ctrl_c = True
            except OSError:
                pass
            time.sleep(0.5)
        if process.poll() is None and not killed_after_rollback_marker:
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
        "first_enter_retry_sent": first_enter_retry_sent,
        "second_enter_retry_sent": second_enter_retry_sent,
        "first_response_seen": first_response_seen_at is not None,
        "second_response_seen": second_response_seen_at is not None,
        "first_answer_visible": first_answer_visible_at is not None,
        "second_answer_visible": second_answer_visible_at is not None,
        "sent_compact_command": sent_compact_command,
        "compact_command_sent_at": compact_command_sent_at,
        "compaction_request_seen": compaction_request_seen_at is not None,
        "sent_backtrack_prime": sent_backtrack_prime,
        "sent_backtrack_open_overlay": sent_backtrack_open_overlay,
        "backtrack_overlay_marker_seen": backtrack_overlay_seen_at is not None,
        "sent_backtrack_confirm": sent_backtrack_confirm,
        "rollback_marker_seen": rollback_marker_seen_at is not None,
        "kill_after_rollback_marker": kill_after_rollback_marker,
        "killed_after_rollback_marker": killed_after_rollback_marker,
        "killed_by_sigkill": exit_code == -9,
        "sent_clear_after_rollback": sent_clear_after_rollback,
        "sent_ctrl_c": sent_ctrl_c,
        "rollback_markers_before": rollback_markers_before,
        "rollback_markers_after": rollback_markers_after,
        "output_tail_stripped": stripped_output[-4000:],
        "raw_output_bytes": len(output),
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    kill_after_rollback_marker: bool,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with RollbackAfterCompactionCliMockServer() as mock_server:
        write_rb05_cli_mock_config(codex_home, mock_server.url)
        rollback_tui = run_cli_two_turns_compact_and_backtrack_tui(
            tree_name,
            codex_bin,
            workspace,
            codex_home,
            chat_root,
            config_overrides,
            mock_server,
            kill_after_rollback_marker,
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
        storage_detail = (
            chat_package_observation(chat_root)
            if tree_name == "chat-backend"
            else original_storage_detail(final_storage, codex_home)
        )
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
            "storage_detail": storage_detail,
            "chat_package_summary": chat_package_observation(chat_root)
            if tree_name == "chat-backend"
            else None,
            "rollback_marker_count": count_rollback_markers(
                tree_name,
                codex_home,
                chat_root,
            ),
            "storage_text_presence": storage_text_presence(
                tree_name,
                codex_home,
                chat_root,
                [
                    FIRST_USER_TEXT,
                    SECOND_USER_TEXT,
                    FIRST_ASSISTANT_TEXT,
                    SECOND_ASSISTANT_TEXT,
                    COMPACTION_SUMMARY_TEXT,
                ],
            ),
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=None,
    )
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument(
        "--kill-after-rollback-marker",
        action="store_true",
        help=(
            "After the post-compaction rollback marker is durably observable, "
            "SIGKILL the TUI before clean shutdown and then validate resume."
        ),
    )
    args = parser.parse_args()

    scope = (
        "cli-rollback-after-compaction-process-kill-smoke"
        if args.kill_after_rollback_marker
        else "cli-rollback-after-compaction-smoke"
    )
    output_dir = (
        args.output_dir
        or validation_results_root()
        / (scope + "-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    ).resolve()
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
        kill_after_rollback_marker=args.kill_after_rollback_marker,
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        kill_after_rollback_marker=args.kill_after_rollback_marker,
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
    chat_rollback_num_turns = sorted(chat_package.get("timeline_rollback_num_turns") or [])

    request_shape_ok = all(
        [
            original_mock == chat_mock,
            original_mock["response_request_count"] >= 4,
            original_mock["first_body_contains_first_user_text"],
            original_mock["second_body_contains_first_user_text"],
            original_mock["second_body_contains_first_assistant_text"],
            original_mock["second_body_contains_second_user_text"],
            original_mock["any_compaction_request_contains_prompt"],
            original_mock["followup_body_contains_followup_user_text"],
        ]
    )
    storage_text_preserved = all(
        [
            all(original_result["storage_text_presence"].values()),
            all(chat_result["storage_text_presence"].values()),
        ]
    )

    original_tui_exit_matches_mode = (
        original_result["rollback_tui"].get("killed_by_sigkill")
        and original_result["rollback_tui"].get("killed_after_rollback_marker")
        if args.kill_after_rollback_marker
        else original_result["rollback_tui"].get("exit_code") == 0
    )
    chat_backend_tui_exit_matches_mode = (
        chat_result["rollback_tui"].get("killed_by_sigkill")
        and chat_result["rollback_tui"].get("killed_after_rollback_marker")
        if args.kill_after_rollback_marker
        else chat_result["rollback_tui"].get("exit_code") == 0
    )

    not_yet_proven = [
        "exact app-server RB05 control-event rollback shape through a CLI surface",
        "automatic compaction K01 through CLI",
        "world state full/patch K04 through CLI",
        "legacy compaction fallback K05",
        "broader compaction-boundary rollback variants",
        "compact-summary-as-resume-baseline behavior beyond original CLI oracle",
        "complete data fidelity",
        "final user-indistinguishability",
    ]
    if not args.kill_after_rollback_marker:
        not_yet_proven.insert(6, "true process-kill rollback/compaction recovery")
    else:
        not_yet_proven.insert(
            6,
            "process kill before or during rollback marker durability after compaction",
        )
        not_yet_proven.insert(
            7,
            "process kill around automatic compaction or app-server RB05 control-event rollback",
        )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": scope,
        "matrix_slice": [
            "RB05-adjacent",
            "K02-adjacent",
            "R01-adjacent",
        ]
        + (
            ["H05-adjacent-process-kill-after-rb05-durable-rollback-marker"]
            if args.kill_after_rollback_marker
            else []
        ),
        "is_final_parity_claim": False,
        "kill_after_rollback_marker": args.kill_after_rollback_marker,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_exit_ok": original_result["rollback_tui"].get("exit_code") == 0,
        "chat_backend_tui_exit_ok": chat_result["rollback_tui"].get("exit_code") == 0,
        "original_tui_exit_matches_mode": original_tui_exit_matches_mode,
        "chat_backend_tui_exit_matches_mode": chat_backend_tui_exit_matches_mode,
        "original_tui_killed_by_sigkill": original_result["rollback_tui"].get(
            "killed_by_sigkill"
        ),
        "chat_backend_tui_killed_by_sigkill": chat_result["rollback_tui"].get(
            "killed_by_sigkill"
        ),
        "original_killed_after_rollback_marker": original_result["rollback_tui"].get(
            "killed_after_rollback_marker"
        ),
        "chat_backend_killed_after_rollback_marker": chat_result["rollback_tui"].get(
            "killed_after_rollback_marker"
        ),
        "original_tui_prompts_responses_compaction_and_backtrack_seen": all(
            [
                original_result["rollback_tui"].get("sent_first_prompt"),
                original_result["rollback_tui"].get("sent_second_prompt"),
                original_result["rollback_tui"].get("first_response_seen"),
                original_result["rollback_tui"].get("second_response_seen"),
                original_result["rollback_tui"].get("sent_compact_command"),
                original_result["rollback_tui"].get("compaction_request_seen"),
                original_result["rollback_tui"].get("sent_backtrack_prime"),
                original_result["rollback_tui"].get("sent_backtrack_open_overlay"),
                original_result["rollback_tui"].get("sent_backtrack_confirm"),
                original_result["rollback_tui"].get("rollback_marker_seen"),
            ]
        ),
        "chat_backend_tui_prompts_responses_compaction_and_backtrack_seen": all(
            [
                chat_result["rollback_tui"].get("sent_first_prompt"),
                chat_result["rollback_tui"].get("sent_second_prompt"),
                chat_result["rollback_tui"].get("first_response_seen"),
                chat_result["rollback_tui"].get("second_response_seen"),
                chat_result["rollback_tui"].get("sent_compact_command"),
                chat_result["rollback_tui"].get("compaction_request_seen"),
                chat_result["rollback_tui"].get("sent_backtrack_prime"),
                chat_result["rollback_tui"].get("sent_backtrack_open_overlay"),
                chat_result["rollback_tui"].get("sent_backtrack_confirm"),
                chat_result["rollback_tui"].get("rollback_marker_seen"),
            ]
        ),
        "original_followup_exec_ok": original_result["followup_exec"].get("exit_code")
        == 0,
        "chat_backend_followup_exec_ok": chat_result["followup_exec"].get("exit_code")
        == 0,
        "normalized_followup_exec_equal": original_followup_events == chat_followup_events,
        "mock_request_summaries_equal": original_mock == chat_mock,
        "request_shape_ok": request_shape_ok,
        "rollback_marker_counts_equal": original_result["rollback_marker_count"]
        == chat_result["rollback_marker_count"],
        "rollback_marker_counts_expected_one": all(
            [
                original_result["rollback_marker_count"] == 1,
                chat_result["rollback_marker_count"] == 1,
            ]
        ),
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "durable_line_counts_equal_after_rollback_or_kill": original_result[
            "after_rollback_line_counts"
        ]
        == chat_result["after_rollback_line_counts"],
        "original_after_rollback_or_kill_line_counts": original_result[
            "after_rollback_line_counts"
        ],
        "chat_backend_after_rollback_or_kill_line_counts": chat_result[
            "after_rollback_line_counts"
        ],
        "durable_line_counts_equal_after_followup": original_result["final_line_counts"]
        == chat_result["final_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "chat_backend_compaction_events_present": all(
            [
                chat_package.get("total_timeline_compaction_event_count", 0) >= 1,
                chat_package.get("total_journal_compaction_event_count", 0) >= 1,
            ]
        ),
        "chat_backend_rollback_events_present": all(
            [
                chat_package.get("total_timeline_rollback_count") == 1,
                chat_package.get("total_journal_rollback_marker_count") >= 1,
            ]
        ),
        "chat_backend_timeline_rollback_num_turns": chat_rollback_num_turns,
        "chat_backend_standard_projections_ok": chat_package.get(
            "all_packages_have_standard_projections"
        ),
        "chat_backend_replacement_history_present": chat_package.get(
            "any_package_has_replacement_history"
        ),
        "source_history_preserved_despite_backtrack_after_compaction": storage_text_preserved,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_rollback_tui": original_result["rollback_tui"],
        "chat_backend_rollback_tui": chat_result["rollback_tui"],
        "original_storage_detail": original_result["storage_detail"],
        "chat_package_summary": chat_package,
        "original_storage_text_presence": original_result["storage_text_presence"],
        "chat_backend_storage_text_presence": chat_result["storage_text_presence"],
        "not_yet_proven": not_yet_proven,
    }
    summary["passed"] = all(
        [
            summary["original_tui_exit_matches_mode"],
            summary["chat_backend_tui_exit_matches_mode"],
            summary["original_tui_prompts_responses_compaction_and_backtrack_seen"],
            summary["chat_backend_tui_prompts_responses_compaction_and_backtrack_seen"],
            summary["original_followup_exec_ok"],
            summary["chat_backend_followup_exec_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["request_shape_ok"],
            summary["rollback_marker_counts_equal"],
            summary["rollback_marker_counts_expected_one"],
            summary["durable_line_counts_equal_after_rollback_or_kill"],
            summary["durable_line_counts_equal_after_followup"],
            summary["chat_backend_compaction_events_present"],
            summary["chat_backend_rollback_events_present"],
            summary["chat_backend_standard_projections_ok"],
            summary["chat_backend_replacement_history_present"],
            summary["source_history_preserved_despite_backtrack_after_compaction"],
        ]
    )

    write_json(output_dir / "original/cli-rollback-after-compaction-response.json", original_result)
    write_json(
        output_dir / "chat-backend/cli-rollback-after-compaction-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# CLI Rollback After Compaction Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives ordinary user-facing CLI/TUI entry points and a local mock Responses
API.

## Scope

```text
codex
type two prompts in the real TUI
/compact in the same real TUI
Esc, Esc, Enter in the real TUI backtrack flow
codex exec --json resume --last ...
```

This is RB05-adjacent, not full RB05. The TUI backtrack path targets user
messages, while the app-server RB05 oracle can roll back the visible compaction
control turn directly. This smoke proves that a user-facing rollback after a
real TUI compaction boundary preserves original-vs-`.chat` behavior for request
context, visible follow-up output, durable rollback markers, compaction
checkpoint/source transport, and line counts.

If `kill_after_rollback_marker` is true, this smoke additionally kills the real
TUI with SIGKILL after the post-compaction rollback marker is durably
observable and before clean shutdown, then validates cold `resume --last`.

## Result

- passed: `{summary['passed']}`
- kill after rollback marker: `{summary['kill_after_rollback_marker']}`
- original TUI exit ok: `{summary['original_tui_exit_ok']}`
- `.chat` TUI exit ok: `{summary['chat_backend_tui_exit_ok']}`
- original TUI exit matches mode: `{summary['original_tui_exit_matches_mode']}`
- `.chat` TUI exit matches mode: `{summary['chat_backend_tui_exit_matches_mode']}`
- original TUI killed by SIGKILL: `{summary['original_tui_killed_by_sigkill']}`
- `.chat` TUI killed by SIGKILL: `{summary['chat_backend_tui_killed_by_sigkill']}`
- original killed after rollback marker: `{summary['original_killed_after_rollback_marker']}`
- `.chat` killed after rollback marker: `{summary['chat_backend_killed_after_rollback_marker']}`
- original TUI prompts/responses/compaction/backtrack seen: `{summary['original_tui_prompts_responses_compaction_and_backtrack_seen']}`
- `.chat` TUI prompts/responses/compaction/backtrack seen: `{summary['chat_backend_tui_prompts_responses_compaction_and_backtrack_seen']}`
- normalized follow-up exec equal: `{summary['normalized_followup_exec_equal']}`
- mock request summaries equal: `{summary['mock_request_summaries_equal']}`
- request shape ok: `{summary['request_shape_ok']}`
- rollback marker counts equal: `{summary['rollback_marker_counts_equal']}`
- rollback marker counts expected one: `{summary['rollback_marker_counts_expected_one']}`
- durable line counts equal after rollback/kill: `{summary['durable_line_counts_equal_after_rollback_or_kill']}`
- durable line counts equal after follow-up: `{summary['durable_line_counts_equal_after_followup']}`
- `.chat` compaction events present: `{summary['chat_backend_compaction_events_present']}`
- `.chat` rollback events present: `{summary['chat_backend_rollback_events_present']}`
- `.chat` timeline rollback num_turns: `{summary['chat_backend_timeline_rollback_num_turns']}`
- `.chat` standard projections ok: `{summary['chat_backend_standard_projections_ok']}`
- `.chat` replacement history present: `{summary['chat_backend_replacement_history_present']}`
- source history preserved after backtrack: `{summary['source_history_preserved_despite_backtrack_after_compaction']}`

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## TUI Observations

```json
{json.dumps({'original': summary['original_rollback_tui'], 'chat_backend': summary['chat_backend_rollback_tui']}, indent=2, sort_keys=True)}
```

## Storage Observations

```json
{json.dumps({'original': summary['original_storage_detail'], 'chat_backend': chat_package}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-rollback-after-compaction-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-rollback-after-compaction-response.json
```

## Not Yet Proven

This smoke does not prove the exact app-server RB05 control-event rollback shape
through a CLI surface, automatic compaction, world-state full/patch restore,
legacy compaction fallback, broader compaction-boundary rollback variants, true
process-kill rollback/compaction recovery, complete data fidelity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
