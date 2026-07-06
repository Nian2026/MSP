#!/usr/bin/env python3
"""Run a real CLI/TUI active-turn rollback parity smoke.

This source-backed validation drives ordinary user-facing Codex CLI/TUI entry
points:

    codex
    type one completed prompt
    type a second prompt whose model response is still running
    Ctrl+T, Esc, Enter through the transcript overlay backtrack flow
    codex exec --json resume --last ...

The expected behavior is rejection, not rollback: active-turn rollback should
fail the same way on the original backend and the `.chat` backend, should not
write a rollback marker, and should leave the active turn intact once it
completes. This proves only a narrow CLI RB04-adjacent slice.
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
    sse_response,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    normalize_exec_events,
    response_request_bodies,
    run_cli_command,
)
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    chat_package_observation,
    count_rollback_markers,
    durable_line_counts,
    response_request_count,
    strip_ansi,
    type_prompt_and_enter,
)


SEED_USER_TEXT = "CLI active rollback seed turn."
ACTIVE_USER_TEXT = "CLI active rollback running turn."
FOLLOWUP_USER_TEXT = "CLI active rollback follow-up after rejected backtrack."
SEED_ASSISTANT_TEXT = "CLI active rollback seed answer from mock model."
ACTIVE_ASSISTANT_TEXT = "CLI active rollback delayed answer from mock model."
FOLLOWUP_ASSISTANT_TEXT = "CLI active rollback follow-up answer from mock model."
ROLLBACK_ACTIVE_ERROR_FRAGMENT = "Cannot rollback while a turn is in progress"
ROLLBACK_TUI_ERROR_FRAGMENT = "thread/rollback failed in TUI"

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_active_turn_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/input.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_backtrack.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class DelayedActiveTurnMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FOLLOWUP_ASSISTANT_TEXT)
        self._responses = [
            (SEED_ASSISTANT_TEXT, 0.0),
            (ACTIVE_ASSISTANT_TEXT, 6.0),
            (FOLLOWUP_ASSISTANT_TEXT, 0.0),
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text, delay_seconds = self._responses[
            min(counter - 1, len(self._responses) - 1)
        ]
        if delay_seconds:
            time.sleep(delay_seconds)
        return sse_response(
            f"resp-cli-active-rollback-smoke-{counter}",
            f"msg-cli-active-rollback-smoke-{counter}",
            answer_text,
        )


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
        "first_body_contains_seed_user_text": body_contains(first_body, SEED_USER_TEXT),
        "second_body_contains_seed_user_text": body_contains(second_body, SEED_USER_TEXT),
        "second_body_contains_seed_assistant_text": body_contains(
            second_body,
            SEED_ASSISTANT_TEXT,
        ),
        "second_body_contains_active_user_text": body_contains(
            second_body,
            ACTIVE_USER_TEXT,
        ),
        "followup_body_contains_seed_user_text": body_contains(
            followup_body,
            SEED_USER_TEXT,
        ),
        "followup_body_contains_seed_assistant_text": body_contains(
            followup_body,
            SEED_ASSISTANT_TEXT,
        ),
        "followup_body_contains_active_user_text": body_contains(
            followup_body,
            ACTIVE_USER_TEXT,
        ),
        "followup_body_contains_active_assistant_text": body_contains(
            followup_body,
            ACTIVE_ASSISTANT_TEXT,
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


def run_cli_active_turn_backtrack_attempt_tui(
    tree_name: str,
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    mock_server: DelayedActiveTurnMockResponsesServer,
    *,
    kill_after_backtrack_enter: bool = False,
    kill_after_error_visible: bool = False,
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
    sent_seed_prompt = False
    ready_for_prompt_seen_at: float | None = None
    seed_prompt_sent_at: float | None = None
    seed_enter_retry_sent = False
    seed_response_seen_at: float | None = None
    seed_answer_visible_at: float | None = None
    sent_active_prompt = False
    active_prompt_sent_at: float | None = None
    active_enter_retry_sent = False
    active_response_seen_at: float | None = None
    sent_transcript_overlay = False
    sent_overlay_backtrack_escape = False
    sent_overlay_backtrack_enter = False
    active_answer_visible_at: float | None = None
    rollback_error_visible_at: float | None = None
    killed_after_backtrack_enter = False
    killed_after_rollback_error_visible = False
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 75:
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

            visible_tail = output.decode(errors="replace")[-2200:]
            compact_visible_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))
            output_text = output.decode(errors="replace")
            stripped_output = strip_ansi(output_text)

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
            if ready_for_prompt and ready_for_prompt_seen_at is None:
                ready_for_prompt_seen_at = time.time()
            if (
                ready_for_prompt_seen_at is not None
                and time.time() - ready_for_prompt_seen_at > 1.0
                and not sent_seed_prompt
            ):
                type_prompt_and_enter(master, SEED_USER_TEXT)
                sent_seed_prompt = True
                seed_prompt_sent_at = time.time()

            requests_seen = response_request_count(mock_server.requests)
            if (
                sent_seed_prompt
                and requests_seen < 1
                and seed_prompt_sent_at is not None
                and time.time() - seed_prompt_sent_at > 2
                and not seed_enter_retry_sent
            ):
                os.write(master, b"\r")
                seed_enter_retry_sent = True
            if sent_seed_prompt and requests_seen >= 1 and seed_response_seen_at is None:
                seed_response_seen_at = time.time()
            if (
                seed_response_seen_at is not None
                and SEED_ASSISTANT_TEXT in output_text
                and seed_answer_visible_at is None
            ):
                seed_answer_visible_at = time.time()
            if (
                seed_answer_visible_at is not None
                and time.time() - seed_answer_visible_at > 1.2
                and not sent_active_prompt
            ):
                type_prompt_and_enter(master, ACTIVE_USER_TEXT)
                sent_active_prompt = True
                active_prompt_sent_at = time.time()
            if (
                sent_active_prompt
                and requests_seen < 2
                and active_prompt_sent_at is not None
                and time.time() - active_prompt_sent_at > 2
                and not active_enter_retry_sent
            ):
                os.write(master, b"\r")
                active_enter_retry_sent = True

            if sent_active_prompt and requests_seen >= 2 and active_response_seen_at is None:
                active_response_seen_at = time.time()
            if (
                active_response_seen_at is not None
                and time.time() - active_response_seen_at > 0.5
                and not sent_transcript_overlay
            ):
                os.write(master, b"\x14")
                sent_transcript_overlay = True
            if (
                sent_transcript_overlay
                and time.time() - active_response_seen_at > 1.0
                and not sent_overlay_backtrack_escape
            ):
                os.write(master, b"\x1b")
                sent_overlay_backtrack_escape = True
            if (
                sent_overlay_backtrack_escape
                and time.time() - active_response_seen_at > 1.4
                and not sent_overlay_backtrack_enter
            ):
                os.write(master, b"\r")
                sent_overlay_backtrack_enter = True
                if kill_after_backtrack_enter:
                    process.kill()
                    killed_after_backtrack_enter = True
                    break

            if (
                sent_overlay_backtrack_enter
                and rollback_error_visible_at is None
                and (
                    ROLLBACK_ACTIVE_ERROR_FRAGMENT in stripped_output
                    or ROLLBACK_TUI_ERROR_FRAGMENT in stripped_output
                )
            ):
                rollback_error_visible_at = time.time()
                if kill_after_error_visible:
                    process.kill()
                    killed_after_rollback_error_visible = True
                    break

            if (
                active_response_seen_at is not None
                and ACTIVE_ASSISTANT_TEXT in output_text
                and active_answer_visible_at is None
            ):
                active_answer_visible_at = time.time()

            if (
                active_answer_visible_at is not None
                and sent_overlay_backtrack_enter
                and time.time() - active_answer_visible_at > 2
                and not sent_ctrl_c
            ):
                os.write(master, b"\x03")
                sent_ctrl_c = True

            if process.poll() is not None:
                break

        if process.poll() is None and not (
            killed_after_backtrack_enter or killed_after_rollback_error_visible
        ):
            try:
                os.write(master, b"\x03")
                sent_ctrl_c = True
            except OSError:
                pass
            time.sleep(0.5)
        if process.poll() is None and not (
            killed_after_backtrack_enter or killed_after_rollback_error_visible
        ):
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
        "sent_seed_prompt": sent_seed_prompt,
        "seed_enter_retry_sent": seed_enter_retry_sent,
        "sent_active_prompt": sent_active_prompt,
        "active_enter_retry_sent": active_enter_retry_sent,
        "seed_response_seen": seed_response_seen_at is not None,
        "seed_answer_visible": seed_answer_visible_at is not None,
        "active_response_seen": active_response_seen_at is not None,
        "sent_transcript_overlay": sent_transcript_overlay,
        "sent_overlay_backtrack_escape": sent_overlay_backtrack_escape,
        "sent_overlay_backtrack_enter": sent_overlay_backtrack_enter,
        "rollback_error_visible": rollback_error_visible_at is not None,
        "active_answer_visible": active_answer_visible_at is not None,
        "killed_after_backtrack_enter": killed_after_backtrack_enter,
        "killed_after_rollback_error_visible": killed_after_rollback_error_visible,
        "killed_by_sigkill": exit_code == -9,
        "sent_ctrl_c": sent_ctrl_c,
        "rollback_markers_before": rollback_markers_before,
        "rollback_markers_after": rollback_markers_after,
        "rollback_marker_delta": rollback_markers_after - rollback_markers_before,
        "output_tail_stripped": stripped_output[-4000:],
        "raw_output_bytes": len(output),
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    *,
    kill_after_backtrack_enter: bool = False,
    kill_after_error_visible: bool = False,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with DelayedActiveTurnMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        tui_attempt = run_cli_active_turn_backtrack_attempt_tui(
            tree_name,
            codex_bin,
            workspace,
            codex_home,
            chat_root,
            config_overrides,
            mock_server,
            kill_after_backtrack_enter=kill_after_backtrack_enter,
            kill_after_error_visible=kill_after_error_visible,
        )
        after_tui_storage = storage_summary(tree_name, codex_home, chat_root)
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
            "tui_attempt": tui_attempt,
            "followup_exec": followup_exec,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "after_tui_storage": after_tui_storage,
            "final_storage": final_storage,
            "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
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
        default=None,
    )
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument(
        "--kill-after-backtrack-enter",
        action="store_true",
        help=(
            "Kill the real TUI with SIGKILL immediately after dispatching the "
            "active-turn rollback confirmation key, before waiting for the "
            "rejection to render."
        ),
    )
    parser.add_argument(
        "--kill-after-error-visible",
        action="store_true",
        help=(
            "Kill the real TUI with SIGKILL immediately after the active-turn "
            "rollback rejection is visible, then validate cold resume parity."
        ),
    )
    args = parser.parse_args()
    if args.kill_after_backtrack_enter and args.kill_after_error_visible:
        raise RuntimeError(
            "--kill-after-backtrack-enter and --kill-after-error-visible are mutually exclusive"
        )

    default_run_name = (
        "cli-rollback-active-turn-request-process-kill-smoke-"
        if args.kill_after_backtrack_enter
        else "cli-rollback-active-turn-process-kill-smoke-"
        if args.kill_after_error_visible
        else "cli-rollback-active-turn-smoke-"
    ) + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = (
        args.output_dir
        if args.output_dir is not None
        else validation_results_root() / default_run_name
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
        kill_after_backtrack_enter=args.kill_after_backtrack_enter,
        kill_after_error_visible=args.kill_after_error_visible,
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        kill_after_backtrack_enter=args.kill_after_backtrack_enter,
        kill_after_error_visible=args.kill_after_error_visible,
    )

    original_tui = original_result["tui_attempt"]
    chat_tui = chat_result["tui_attempt"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_followup_events = normalize_exec_events(
        original_result["followup_exec"].get("events") or []
    )
    chat_followup_events = normalize_exec_events(
        chat_result["followup_exec"].get("events") or []
    )
    chat_package = chat_result["chat_package_summary"] or {}

    active_turn_context_preserved = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["followup_body_contains_seed_user_text"],
            chat_mock["followup_body_contains_seed_user_text"],
            original_mock["followup_body_contains_seed_assistant_text"],
            chat_mock["followup_body_contains_seed_assistant_text"],
            original_mock["followup_body_contains_active_user_text"],
            chat_mock["followup_body_contains_active_user_text"],
            not original_mock["followup_body_contains_active_assistant_text"],
            not chat_mock["followup_body_contains_active_assistant_text"],
            original_mock["followup_body_contains_followup_user_text"],
            chat_mock["followup_body_contains_followup_user_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": (
            "cli-rollback-active-turn-request-process-kill-smoke"
            if args.kill_after_backtrack_enter
            else "cli-rollback-active-turn-process-kill-smoke"
            if args.kill_after_error_visible
            else "cli-rollback-active-turn-smoke"
        ),
        "matrix_slice": (
            [
                "RB04-adjacent",
                "R01-adjacent",
                "H05-adjacent-process-kill-after-active-rollback-key-dispatch",
            ]
            if args.kill_after_backtrack_enter
            else [
                "RB04-adjacent",
                "R01-adjacent",
                "H05-adjacent-process-kill-after-active-rollback-rejection",
            ]
            if args.kill_after_error_visible
            else ["RB04-adjacent", "R01-adjacent"]
        ),
        "is_final_parity_claim": False,
        "kill_after_backtrack_enter": args.kill_after_backtrack_enter,
        "kill_after_error_visible": args.kill_after_error_visible,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_exit_code": original_tui.get("exit_code"),
        "chat_backend_tui_exit_code": chat_tui.get("exit_code"),
        "tui_exit_codes_equal": original_tui.get("exit_code")
        == chat_tui.get("exit_code"),
        "original_tui_exited_with_rollback_error": original_tui.get("exit_code") != 0,
        "chat_backend_tui_exited_with_rollback_error": chat_tui.get("exit_code") != 0,
        "original_prompts_and_responses_seen": all(
            [
                original_tui.get("sent_seed_prompt"),
                original_tui.get("sent_active_prompt"),
                original_tui.get("seed_response_seen"),
                original_tui.get("active_response_seen"),
                original_tui.get("seed_answer_visible"),
            ]
        ),
        "chat_backend_prompts_and_responses_seen": all(
            [
                chat_tui.get("sent_seed_prompt"),
                chat_tui.get("sent_active_prompt"),
                chat_tui.get("seed_response_seen"),
                chat_tui.get("active_response_seen"),
                chat_tui.get("seed_answer_visible"),
            ]
        ),
        "original_overlay_backtrack_keys_sent": all(
            [
                original_tui.get("sent_transcript_overlay"),
                original_tui.get("sent_overlay_backtrack_escape"),
                original_tui.get("sent_overlay_backtrack_enter"),
            ]
        ),
        "chat_backend_overlay_backtrack_keys_sent": all(
            [
                chat_tui.get("sent_transcript_overlay"),
                chat_tui.get("sent_overlay_backtrack_escape"),
                chat_tui.get("sent_overlay_backtrack_enter"),
            ]
        ),
        "original_active_rollback_error_visible": original_tui.get(
            "rollback_error_visible"
        ),
        "chat_backend_active_rollback_error_visible": chat_tui.get(
            "rollback_error_visible"
        ),
        "original_tui_killed_after_backtrack_enter": original_tui.get(
            "killed_after_backtrack_enter"
        ),
        "chat_backend_tui_killed_after_backtrack_enter": chat_tui.get(
            "killed_after_backtrack_enter"
        ),
        "original_tui_killed_after_rollback_error_visible": original_tui.get(
            "killed_after_rollback_error_visible"
        ),
        "chat_backend_tui_killed_after_rollback_error_visible": chat_tui.get(
            "killed_after_rollback_error_visible"
        ),
        "original_tui_killed_by_sigkill": original_tui.get("killed_by_sigkill"),
        "chat_backend_tui_killed_by_sigkill": chat_tui.get("killed_by_sigkill"),
        "original_no_rollback_marker_written_during_attempt": original_tui.get(
            "rollback_marker_delta"
        )
        == 0,
        "chat_backend_no_rollback_marker_written_during_attempt": chat_tui.get(
            "rollback_marker_delta"
        )
        == 0,
        "rollback_marker_counts_equal_final": original_result["rollback_marker_count"]
        == chat_result["rollback_marker_count"],
        "original_rollback_marker_count_final": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count_final": chat_result["rollback_marker_count"],
        "original_followup_exec_ok": original_result["followup_exec"].get("exit_code")
        == 0,
        "chat_backend_followup_exec_ok": chat_result["followup_exec"].get("exit_code")
        == 0,
        "normalized_followup_exec_equal": original_followup_events == chat_followup_events,
        "mock_request_summaries_equal": original_mock == chat_mock,
        "active_turn_context_preserved_after_rejected_rollback": (
            active_turn_context_preserved
        ),
        "durable_line_counts_equal_after_followup": original_result["final_line_counts"]
        == chat_result["final_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "chat_backend_timeline_rollback_count": chat_package.get(
            "total_timeline_rollback_count"
        ),
        "chat_backend_no_timeline_rollback_event_present": chat_package.get(
            "total_timeline_rollback_count"
        )
        == 0,
        "chat_backend_standard_projections_ok": chat_package.get(
            "all_packages_have_standard_projections"
        ),
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_tui_attempt": original_tui,
        "chat_backend_tui_attempt": chat_tui,
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "direct app-server RB04 is already covered separately; this is only the CLI/TUI overlay adjacency",
            "arbitrary active-turn rollback paths beyond Ctrl+T/Esc/Enter transcript overlay",
            "rollback after automatic or legacy compaction boundaries",
            (
                "active-turn rollback rejection rendering after key dispatch"
                if args.kill_after_backtrack_enter
                else "process death before the active-turn rollback rejection is visible"
                if args.kill_after_error_visible
                else "true process-kill rollback recovery"
            ),
            "process death during the active-turn rollback request before rejection",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }
    process_kill_checks = (
        [
            summary["original_tui_killed_after_backtrack_enter"],
            summary["chat_backend_tui_killed_after_backtrack_enter"],
            summary["original_tui_killed_by_sigkill"],
            summary["chat_backend_tui_killed_by_sigkill"],
        ]
        if args.kill_after_backtrack_enter
        else [
            summary["original_tui_killed_after_rollback_error_visible"],
            summary["chat_backend_tui_killed_after_rollback_error_visible"],
            summary["original_tui_killed_by_sigkill"],
            summary["chat_backend_tui_killed_by_sigkill"],
        ]
        if args.kill_after_error_visible
        else [
            summary["original_tui_exited_with_rollback_error"],
            summary["chat_backend_tui_exited_with_rollback_error"],
        ]
    )
    active_error_checks = (
        []
        if args.kill_after_backtrack_enter
        else [
            summary["original_active_rollback_error_visible"],
            summary["chat_backend_active_rollback_error_visible"],
        ]
    )
    summary["passed"] = all(
        [
            summary["tui_exit_codes_equal"],
            *process_kill_checks,
            summary["original_prompts_and_responses_seen"],
            summary["chat_backend_prompts_and_responses_seen"],
            summary["original_overlay_backtrack_keys_sent"],
            summary["chat_backend_overlay_backtrack_keys_sent"],
            *active_error_checks,
            summary["original_no_rollback_marker_written_during_attempt"],
            summary["chat_backend_no_rollback_marker_written_during_attempt"],
            summary["rollback_marker_counts_equal_final"],
            summary["original_followup_exec_ok"],
            summary["chat_backend_followup_exec_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["active_turn_context_preserved_after_rejected_rollback"],
            summary["durable_line_counts_equal_after_followup"],
            summary["chat_backend_no_timeline_rollback_event_present"],
            summary["chat_backend_standard_projections_ok"],
        ]
    )

    write_json(output_dir / "original/cli-rollback-active-turn-response.json", original_result)
    write_json(output_dir / "chat-backend/cli-rollback-active-turn-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report_title = (
        "CLI Rollback Active Turn Request Process-Kill Smoke"
        if args.kill_after_backtrack_enter
        else "CLI Rollback Active Turn Process-Kill Smoke"
        if args.kill_after_error_visible
        else "CLI Rollback Active Turn Smoke"
    )
    process_line = (
        "SIGKILL immediately after dispatching the active-turn rollback confirmation key"
        if args.kill_after_backtrack_enter
        else "SIGKILL immediately after the active-turn rollback rejection is visible"
        if args.kill_after_error_visible
        else "let the active turn finish after the rejected rollback attempt"
    )
    report = f"""# {report_title} - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives ordinary user-facing CLI/TUI entry points and a local mock Responses
API.

## Scope

```text
codex
type one completed prompt
type a second prompt whose model response is still running
Ctrl+T, Esc, Enter in the real TUI transcript overlay backtrack flow
{process_line}
codex exec --json resume --last ...
```

This is RB04-adjacent: rollback is attempted through a real CLI/TUI overlay
while a turn is active. The expected oracle is no rollback marker and
original-equivalent follow-up context. In process-kill modes, the active
assistant answer is intentionally unfinished and must not be fabricated during
resume.

## Result

- passed: `{summary['passed']}`
- original TUI exit code: `{summary['original_tui_exit_code']}`
- `.chat` TUI exit code: `{summary['chat_backend_tui_exit_code']}`
- TUI exit codes equal: `{summary['tui_exit_codes_equal']}`
- original TUI exited with rollback error: `{summary['original_tui_exited_with_rollback_error']}`
- `.chat` TUI exited with rollback error: `{summary['chat_backend_tui_exited_with_rollback_error']}`
- original prompts/responses seen: `{summary['original_prompts_and_responses_seen']}`
- `.chat` prompts/responses seen: `{summary['chat_backend_prompts_and_responses_seen']}`
- original overlay backtrack keys sent: `{summary['original_overlay_backtrack_keys_sent']}`
- `.chat` overlay backtrack keys sent: `{summary['chat_backend_overlay_backtrack_keys_sent']}`
- original active rollback error visible: `{summary['original_active_rollback_error_visible']}`
- `.chat` active rollback error visible: `{summary['chat_backend_active_rollback_error_visible']}`
- original TUI killed after backtrack enter: `{summary['original_tui_killed_after_backtrack_enter']}`
- `.chat` TUI killed after backtrack enter: `{summary['chat_backend_tui_killed_after_backtrack_enter']}`
- original TUI killed after rollback error visible: `{summary['original_tui_killed_after_rollback_error_visible']}`
- `.chat` TUI killed after rollback error visible: `{summary['chat_backend_tui_killed_after_rollback_error_visible']}`
- original TUI killed by SIGKILL: `{summary['original_tui_killed_by_sigkill']}`
- `.chat` TUI killed by SIGKILL: `{summary['chat_backend_tui_killed_by_sigkill']}`
- original no rollback marker written during attempt: `{summary['original_no_rollback_marker_written_during_attempt']}`
- `.chat` no rollback marker written during attempt: `{summary['chat_backend_no_rollback_marker_written_during_attempt']}`
- rollback marker counts equal final: `{summary['rollback_marker_counts_equal_final']}`
- normalized follow-up exec equal: `{summary['normalized_followup_exec_equal']}`
- mock request summaries equal: `{summary['mock_request_summaries_equal']}`
- active turn context preserved after rejected rollback: `{summary['active_turn_context_preserved_after_rejected_rollback']}`
- durable line counts equal after follow-up: `{summary['durable_line_counts_equal_after_followup']}`
- `.chat` timeline rollback count: `{summary['chat_backend_timeline_rollback_count']}`
- `.chat` standard projections ok: `{summary['chat_backend_standard_projections_ok']}`

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## TUI Observations

```json
{json.dumps({'original': summary['original_tui_attempt'], 'chat_backend': summary['chat_backend_tui_attempt']}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-rollback-active-turn-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-rollback-active-turn-response.json
```

## Not Yet Proven

This smoke does not prove every active-turn rollback path, rollback across
automatic or legacy compaction boundaries, true process-kill rollback recovery,
complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
