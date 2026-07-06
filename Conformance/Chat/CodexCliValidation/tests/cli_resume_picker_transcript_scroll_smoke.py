#!/usr/bin/env python3
"""Run a real CLI resume-picker long transcript overlay parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI picker slice:

    codex exec --json <target prompt>
    codex exec --json resume --last <target continuation prompts...>
    codex exec --json <decoy prompt>
    codex resume --include-non-interactive
      type a target-only picker search query
      press Ctrl+T to open the selected row transcript overlay
      press Home to jump to the top and see the target top marker
      press End to jump back to the bottom and see the target bottom marker
      close the overlay, select the target, and send a follow-up prompt

This proves only the selected-row transcript overlay long-history scrolling
path for the resume picker. It is not final picker/list/search parity or final
user-indistinguishability evidence.
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
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
    run_cli_command,
)
from cli_resume_picker_preview_smoke import compact, storage_summary  # noqa: E402
from cli_resume_picker_search_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    body_contains,
    strip_ansi,
    write_typed_text,
)


TARGET_TOP_MARKER = "RESUME_SCROLL_TARGET_TOP_MARKER"
TARGET_BOTTOM_MARKER = "RESUME_SCROLL_TARGET_BOTTOM_MARKER"
DECOY_MARKER = "RESUME_SCROLL_DECOY_MARKER"
PICKER_QUERY = "resume scroll target anchor"
FOLLOWUP_USER_TEXT = "CLI resume picker long transcript selected target follow-up."
FOLLOWUP_ASSISTANT_TEXT = "CLI resume picker long transcript resumed answer from mock model."

TARGET_TURNS: list[tuple[str, str]] = [
    (
        f"{TARGET_TOP_MARKER} resume scroll target anchor turn 01. "
        "This selected transcript intentionally starts with a unique top marker "
        "and enough text to wrap inside the full transcript overlay.",
        "Resume scroll target answer 01 from mock model, preserving the top marker context.",
    ),
    (
        "Resume scroll target anchor turn 02 with additional transcript body "
        "so the selected-row overlay has more than one viewport of content.",
        "Resume scroll target answer 02 from mock model with middle transcript evidence.",
    ),
    (
        "Resume scroll target anchor turn 03. This is middle evidence for the "
        "long transcript overlay and should remain part of resumed history.",
        "Resume scroll target answer 03 from mock model with another middle marker.",
    ),
    (
        "Resume scroll target anchor turn 04. The text stays deliberately long "
        "enough to wrap across the terminal viewport in the overlay.",
        "Resume scroll target answer 04 from mock model with wrapped transcript text.",
    ),
    (
        "Resume scroll target anchor turn 05. This keeps the target history long "
        "without introducing extra tools or command approvals.",
        "Resume scroll target answer 05 from mock model with durable replay content.",
    ),
    (
        "Resume scroll target anchor turn 06. The resumed request should include "
        "this turn after target selection and exclude the decoy session.",
        "Resume scroll target answer 06 from mock model with more target-only history.",
    ),
    (
        "Resume scroll target anchor turn 07. This near-bottom turn gives the "
        "overlay pager another wrapped page before the final bottom marker.",
        "Resume scroll target answer 07 from mock model with near-bottom evidence.",
    ),
    (
        f"Resume scroll target anchor turn 08 ending with {TARGET_BOTTOM_MARKER}. "
        "This bottom marker should appear at the transcript tail and after End.",
        f"Resume scroll target answer 08 from mock model carrying {TARGET_BOTTOM_MARKER}.",
    ),
]

TARGET_USER_TEXTS = [turn[0] for turn in TARGET_TURNS]
TARGET_ASSISTANT_TEXTS = [turn[1] for turn in TARGET_TURNS]
TARGET_LAST_ASSISTANT_TEXT = TARGET_ASSISTANT_TEXTS[-1]
DECOY_USER_TEXT = f"{DECOY_MARKER} resume scroll decoy durable turn."
DECOY_ASSISTANT_TEXT = "CLI resume picker long transcript decoy answer from mock model."

COMPACT_TARGET_TOP_MARKER = compact(TARGET_TOP_MARKER)
COMPACT_TARGET_BOTTOM_MARKER = compact(TARGET_BOTTOM_MARKER)
COMPACT_DECOY_MARKER = compact(DECOY_MARKER)
COMPACT_FOLLOWUP_USER_TEXT = compact(FOLLOWUP_USER_TEXT)
COMPACT_FOLLOWUP_ASSISTANT_TEXT = compact(FOLLOWUP_ASSISTANT_TEXT)
TARGET_TOP_UI_NEEDLE = "SCROLL_TARGET_TOP_MARKER"
TARGET_BOTTOM_UI_NEEDLE = "SCROLL_TARGET_BOTTOM_MARKER"
COMPACT_TARGET_TOP_UI_NEEDLE = compact(TARGET_TOP_UI_NEEDLE)
COMPACT_TARGET_BOTTOM_UI_NEEDLE = compact(TARGET_BOTTOM_UI_NEEDLE)

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_search_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_transcript_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_transcript_scroll_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/pager_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/pager_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def stripped_since(output: bytes, offset: int | None) -> str:
    if offset is None:
        return ""
    return strip_ansi(output[offset:].decode(errors="replace"))


def send_home(master: int) -> None:
    os.write(master, b"\x1b[H")


def send_end(master: int) -> None:
    os.write(master, b"\x1b[F")


def top_marker_visible(text: str, compact_text: str) -> bool:
    return (
        TARGET_TOP_MARKER in text
        or TARGET_TOP_UI_NEEDLE in text
        or COMPACT_TARGET_TOP_MARKER in compact_text
        or COMPACT_TARGET_TOP_UI_NEEDLE in compact_text
    )


def bottom_marker_visible(text: str, compact_text: str) -> bool:
    return (
        TARGET_BOTTOM_MARKER in text
        or TARGET_BOTTOM_UI_NEEDLE in text
        or COMPACT_TARGET_BOTTOM_MARKER in compact_text
        or COMPACT_TARGET_BOTTOM_UI_NEEDLE in compact_text
    )


def run_resume_picker_transcript_scroll_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(["resume", "--include-non-interactive"])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    master, slave = pty.openpty()
    try:
        import fcntl
        import termios

        winsize = struct.pack("HHHH", 28, 112, 0, 0)
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
    exit_code: int | None = None
    sent_probe_response = False
    sent_trust_answer = False
    sent_query_text = False
    sent_open_transcript = False
    sent_jump_top = False
    sent_jump_bottom = False
    sent_close_transcript = False
    sent_accept = False
    sent_followup_text = False
    sent_followup_submit = False
    sent_ctrl_c = False
    query_sent_at: float | None = None
    transcript_open_sent_at: float | None = None
    jump_top_sent_at: float | None = None
    jump_bottom_sent_at: float | None = None
    transcript_close_sent_at: float | None = None
    accept_sent_at: float | None = None
    followup_text_sent_at: float | None = None
    followup_seen_at: float | None = None
    transcript_open_offset: int | None = None
    jump_top_offset: int | None = None
    jump_bottom_offset: int | None = None
    transcript_close_offset: int | None = None
    target_seen_before_query = False
    decoy_seen_before_query = False
    transcript_loading_seen = False
    transcript_overlay_title_seen = False
    transcript_initial_bottom_seen = False
    transcript_top_after_home_seen = False
    transcript_bottom_after_end_seen = False
    picker_seen_after_close = False

    try:
        while time.time() - started_at < 120:
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

            visible = output.decode(errors="replace")
            stripped = strip_ansi(visible)
            compact_output = compact(stripped)
            visible_tail = visible[-2400:]
            stripped_tail = strip_ansi(visible_tail)
            compact_tail = compact(stripped_tail)

            if not sent_probe_response and (
                "\x1b[6n" in visible_tail
                or "]10;?" in visible_tail
                or "[?u" in visible_tail
            ):
                os.write(master, TERMINAL_PROBE_RESPONSE)
                sent_probe_response = True

            if (
                not sent_trust_answer
                and "Doyoutrustthecontentsofthisdirectory?" in compact_tail
            ):
                os.write(master, b"1\r\r")
                sent_trust_answer = True

            if top_marker_visible(stripped, compact_output):
                target_seen_before_query = True
            if DECOY_MARKER in stripped or COMPACT_DECOY_MARKER in compact_output:
                decoy_seen_before_query = True

            if (
                not sent_query_text
                and target_seen_before_query
                and decoy_seen_before_query
                and len(response_request_bodies(mock_server.requests)) >= len(TARGET_TURNS) + 1
            ):
                write_typed_text(master, PICKER_QUERY)
                sent_query_text = True
                query_sent_at = time.time()

            if (
                sent_query_text
                and not sent_open_transcript
                and query_sent_at is not None
                and time.time() - query_sent_at > 1.5
                and "Search:" in stripped
            ):
                transcript_open_offset = len(output)
                os.write(master, b"\x14")
                sent_open_transcript = True
                transcript_open_sent_at = time.time()

            if sent_open_transcript:
                after_open = stripped_since(output, transcript_open_offset)
                compact_after_open = compact(after_open)
                transcript_loading_seen = transcript_loading_seen or (
                    "Loading transcript" in after_open
                    or "Loadingtranscript" in compact_after_open
                )
                transcript_overlay_title_seen = transcript_overlay_title_seen or (
                    "T R A N S C R I P T" in after_open
                    or "TRANSCRIPT" in compact_after_open
                )
                transcript_initial_bottom_seen = (
                    transcript_initial_bottom_seen
                    or bottom_marker_visible(after_open, compact_after_open)
                )

            if (
                sent_open_transcript
                and not sent_jump_top
                and transcript_open_sent_at is not None
                and time.time() - transcript_open_sent_at > 0.8
                and transcript_overlay_title_seen
                and transcript_initial_bottom_seen
            ):
                jump_top_offset = len(output)
                send_home(master)
                sent_jump_top = True
                jump_top_sent_at = time.time()

            if sent_jump_top:
                after_top = stripped_since(output, jump_top_offset)
                compact_after_top = compact(after_top)
                transcript_top_after_home_seen = (
                    transcript_top_after_home_seen
                    or top_marker_visible(after_top, compact_after_top)
                )

            if (
                sent_jump_top
                and not sent_jump_bottom
                and jump_top_sent_at is not None
                and time.time() - jump_top_sent_at > 0.8
                and transcript_top_after_home_seen
            ):
                jump_bottom_offset = len(output)
                send_end(master)
                sent_jump_bottom = True
                jump_bottom_sent_at = time.time()

            if sent_jump_bottom:
                after_bottom = stripped_since(output, jump_bottom_offset)
                compact_after_bottom = compact(after_bottom)
                transcript_bottom_after_end_seen = (
                    transcript_bottom_after_end_seen
                    or bottom_marker_visible(after_bottom, compact_after_bottom)
                )

            if (
                sent_jump_bottom
                and not sent_close_transcript
                and jump_bottom_sent_at is not None
                and time.time() - jump_bottom_sent_at > 0.8
                and transcript_bottom_after_end_seen
            ):
                transcript_close_offset = len(output)
                os.write(master, b"\x14")
                sent_close_transcript = True
                transcript_close_sent_at = time.time()

            if sent_close_transcript:
                after_close = stripped_since(output, transcript_close_offset)
                picker_seen_after_close = picker_seen_after_close or "Search:" in after_close

            if (
                sent_close_transcript
                and not sent_accept
                and transcript_close_sent_at is not None
                and time.time() - transcript_close_sent_at > 0.8
                and picker_seen_after_close
            ):
                os.write(master, b"\r")
                sent_accept = True
                accept_sent_at = time.time()

            if (
                sent_accept
                and not sent_followup_text
                and accept_sent_at is not None
                and time.time() - accept_sent_at > 1.5
                and (
                    TARGET_BOTTOM_MARKER in stripped
                    or COMPACT_TARGET_BOTTOM_MARKER in compact_output
                    or "Pressentertocontinue" in compact_tail
                )
            ):
                write_typed_text(master, FOLLOWUP_USER_TEXT)
                sent_followup_text = True
                followup_text_sent_at = time.time()

            followup_text_visible = (
                FOLLOWUP_USER_TEXT in stripped or COMPACT_FOLLOWUP_USER_TEXT in compact_output
            )
            if (
                sent_followup_text
                and not sent_followup_submit
                and followup_text_sent_at is not None
                and time.time() - followup_text_sent_at > 0.5
                and followup_text_visible
            ):
                os.write(master, b"\r")
                sent_followup_submit = True

            if (
                len(response_request_bodies(mock_server.requests)) >= len(TARGET_TURNS) + 2
                and followup_seen_at is None
            ):
                followup_seen_at = time.time()

            if (
                followup_seen_at is not None
                and time.time() - followup_seen_at > 2
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
    compact_stripped_output = compact(stripped_output)
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_query_text": sent_query_text,
        "sent_open_transcript": sent_open_transcript,
        "sent_jump_top": sent_jump_top,
        "sent_jump_bottom": sent_jump_bottom,
        "sent_close_transcript": sent_close_transcript,
        "sent_accept": sent_accept,
        "sent_followup_text": sent_followup_text,
        "sent_followup_submit": sent_followup_submit,
        "sent_ctrl_c": sent_ctrl_c,
        "followup_response_seen": followup_seen_at is not None,
        "target_seen_before_query": target_seen_before_query,
        "decoy_seen_before_query": decoy_seen_before_query,
        "transcript_loading_seen": transcript_loading_seen,
        "transcript_overlay_title_seen": transcript_overlay_title_seen,
        "transcript_initial_bottom_seen": transcript_initial_bottom_seen,
        "transcript_top_after_home_seen": transcript_top_after_home_seen,
        "transcript_bottom_after_end_seen": transcript_bottom_after_end_seen,
        "picker_seen_after_close": picker_seen_after_close,
        "output_contains_target_top_marker": top_marker_visible(
            stripped_output, compact_stripped_output
        ),
        "output_contains_target_bottom_marker": bottom_marker_visible(
            stripped_output, compact_stripped_output
        ),
        "output_contains_decoy_marker": DECOY_MARKER in stripped_output
        or COMPACT_DECOY_MARKER in compact_stripped_output,
        "output_contains_followup_assistant": FOLLOWUP_ASSISTANT_TEXT in stripped_output
        or COMPACT_FOLLOWUP_ASSISTANT_TEXT in compact_stripped_output,
        "transcript_after_open_tail": stripped_since(output, transcript_open_offset)[-3000:],
        "transcript_after_home_tail": stripped_since(output, jump_top_offset)[-3000:],
        "transcript_after_end_tail": stripped_since(output, jump_bottom_offset)[-3000:],
        "transcript_after_close_tail": stripped_since(output, transcript_close_offset)[-1600:],
        "output_tail_stripped": stripped_output[-3000:],
        "raw_output_bytes": len(output),
    }


def mock_request_summary(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    target_bodies = bodies[: len(TARGET_TURNS)]
    decoy_body = bodies[len(TARGET_TURNS)] if len(bodies) > len(TARGET_TURNS) else {}
    followup_body = (
        bodies[len(TARGET_TURNS) + 1] if len(bodies) > len(TARGET_TURNS) + 1 else {}
    )
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "all_target_turns_sent": len(target_bodies) == len(TARGET_TURNS),
        "target_first_request_contains_top_marker": bool(target_bodies)
        and body_contains(target_bodies[0], TARGET_TOP_MARKER),
        "target_last_request_contains_bottom_marker": len(target_bodies) == len(TARGET_TURNS)
        and body_contains(target_bodies[-1], TARGET_BOTTOM_MARKER),
        "decoy_body_contains_decoy_marker": body_contains(decoy_body, DECOY_MARKER),
        "decoy_body_contains_target_top_marker": body_contains(decoy_body, TARGET_TOP_MARKER),
        "followup_body_contains_target_top_marker": body_contains(
            followup_body, TARGET_TOP_MARKER
        ),
        "followup_body_contains_target_bottom_marker": body_contains(
            followup_body, TARGET_BOTTOM_MARKER
        ),
        "followup_body_contains_target_last_assistant": body_contains(
            followup_body, TARGET_LAST_ASSISTANT_TEXT
        ),
        "followup_body_contains_followup_user": body_contains(
            followup_body, FOLLOWUP_USER_TEXT
        ),
        "followup_body_contains_decoy_marker": body_contains(followup_body, DECOY_MARKER),
        "followup_body_contains_decoy_assistant": body_contains(
            followup_body, DECOY_ASSISTANT_TEXT
        ),
    }


def run_target_history(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> list[dict[str, Any]]:
    target_execs: list[dict[str, Any]] = []
    for index, prompt in enumerate(TARGET_USER_TEXTS):
        result = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            prompt,
            resume_last=index > 0,
        )
        target_execs.append(result)
    return target_execs


def summarize_exec(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "exit_code": result["exit_code"],
        "normalized_events": result["normalized_events"],
        "thread_ids": result["thread_ids"],
        "stderr_tail": result["stderr_tail"],
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

    responses = TARGET_ASSISTANT_TEXTS + [DECOY_ASSISTANT_TEXT, FOLLOWUP_ASSISTANT_TEXT]
    with SequenceMockResponsesServer(responses) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        target_execs = run_target_history(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
        )
        decoy_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            DECOY_USER_TEXT,
            resume_last=False,
        )
        before_picker_storage = storage_summary(tree_name, codex_home, chat_root)
        picker_tui = run_resume_picker_transcript_scroll_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        after_picker_storage = storage_summary(tree_name, codex_home, chat_root)
        mock_summary = mock_request_summary(mock_server.requests)

    target_thread_ids = [
        result["thread_ids"][0]
        for result in target_execs
        if len(result.get("thread_ids") or []) == 1
    ]
    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "target_execs": [summarize_exec(result) for result in target_execs],
        "target_thread_ids": target_thread_ids,
        "same_target_thread_for_all_turns": (
            len(target_thread_ids) == len(TARGET_TURNS)
            and len(set(target_thread_ids)) == 1
        ),
        "decoy_exec": summarize_exec(decoy_exec),
        "picker_tui": picker_tui,
        "mock_server_summary": mock_summary,
        "before_picker_storage": before_picker_storage,
        "after_picker_storage": after_picker_storage,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    picker = result["picker_tui"]
    return {
        "target_exec_exit_codes": [item["exit_code"] for item in result["target_execs"]],
        "same_target_thread_for_all_turns": result["same_target_thread_for_all_turns"],
        "decoy_exec_exit_code": result["decoy_exec"]["exit_code"],
        "picker_sent_query_text": picker["sent_query_text"],
        "picker_sent_open_transcript": picker["sent_open_transcript"],
        "picker_transcript_loading_seen": picker["transcript_loading_seen"],
        "picker_transcript_overlay_title_seen": picker["transcript_overlay_title_seen"],
        "picker_transcript_initial_bottom_seen": picker["transcript_initial_bottom_seen"],
        "picker_sent_jump_top": picker["sent_jump_top"],
        "picker_transcript_top_after_home_seen": picker["transcript_top_after_home_seen"],
        "picker_sent_jump_bottom": picker["sent_jump_bottom"],
        "picker_transcript_bottom_after_end_seen": picker[
            "transcript_bottom_after_end_seen"
        ],
        "picker_sent_close_transcript": picker["sent_close_transcript"],
        "picker_seen_after_close": picker["picker_seen_after_close"],
        "picker_sent_accept": picker["sent_accept"],
        "picker_sent_followup_text": picker["sent_followup_text"],
        "picker_sent_followup_submit": picker["sent_followup_submit"],
        "picker_followup_response_seen": picker["followup_response_seen"],
        "target_seen_before_query": picker["target_seen_before_query"],
        "decoy_seen_before_query": picker["decoy_seen_before_query"],
        "mock": result["mock_server_summary"],
        "after_line_counts": result["after_picker_storage"]["line_counts"],
        "after_package_count": result["after_picker_storage"]["package_count"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Resume Picker Transcript Scroll Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final picker/list/search parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Overlay title seen: `{summary['picker_transcript_overlay_title_seen']}`",
        f"- Initial bottom marker seen: `{summary['picker_transcript_initial_bottom_seen']}`",
        f"- Top marker seen after Home: `{summary['picker_transcript_top_after_home_seen']}`",
        f"- Bottom marker seen again after End: `{summary['picker_transcript_bottom_after_end_seen']}`",
        f"- Returned to picker after close: `{summary['picker_returned_after_close']}`",
        f"- Resume request preserved target long history: `{summary['picker_selected_target_long_history']}`",
        f"- Resume request excluded decoy history: `{summary['picker_excluded_decoy_history']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke creates one long target history through `codex exec --json`",
        "plus repeated `resume --last`, creates a decoy history, opens the real",
        "`codex resume --include-non-interactive` picker, searches for the",
        "target, opens the selected row full transcript overlay with Ctrl+T,",
        "uses Home and End inside the real overlay pager, closes the overlay,",
        "then selects the target and sends a follow-up prompt from the resumed",
        "TUI.",
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
            "cli-resume-picker-transcript-scroll-smoke-"
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

    original_normalized = normalized_tree_summary(original_result)
    chat_normalized = normalized_tree_summary(chat_result)

    picker_transcript_overlay_title_seen = all(
        [
            original_normalized["picker_transcript_overlay_title_seen"],
            chat_normalized["picker_transcript_overlay_title_seen"],
        ]
    )
    picker_transcript_initial_bottom_seen = all(
        [
            original_normalized["picker_transcript_initial_bottom_seen"],
            chat_normalized["picker_transcript_initial_bottom_seen"],
        ]
    )
    picker_transcript_top_after_home_seen = all(
        [
            original_normalized["picker_transcript_top_after_home_seen"],
            chat_normalized["picker_transcript_top_after_home_seen"],
        ]
    )
    picker_transcript_bottom_after_end_seen = all(
        [
            original_normalized["picker_transcript_bottom_after_end_seen"],
            chat_normalized["picker_transcript_bottom_after_end_seen"],
        ]
    )
    picker_returned_after_close = all(
        [
            original_normalized["picker_seen_after_close"],
            chat_normalized["picker_seen_after_close"],
        ]
    )
    picker_selected_target_long_history = all(
        [
            original_normalized["mock"]["followup_body_contains_target_top_marker"],
            original_normalized["mock"]["followup_body_contains_target_bottom_marker"],
            original_normalized["mock"]["followup_body_contains_target_last_assistant"],
            original_normalized["mock"]["followup_body_contains_followup_user"],
            chat_normalized["mock"]["followup_body_contains_target_top_marker"],
            chat_normalized["mock"]["followup_body_contains_target_bottom_marker"],
            chat_normalized["mock"]["followup_body_contains_target_last_assistant"],
            chat_normalized["mock"]["followup_body_contains_followup_user"],
        ]
    )
    picker_excluded_decoy_history = not any(
        [
            original_normalized["mock"]["followup_body_contains_decoy_marker"],
            original_normalized["mock"]["followup_body_contains_decoy_assistant"],
            chat_normalized["mock"]["followup_body_contains_decoy_marker"],
            chat_normalized["mock"]["followup_body_contains_decoy_assistant"],
        ]
    )
    durable_line_counts_equal = (
        original_normalized["after_line_counts"] == chat_normalized["after_line_counts"]
        and original_normalized["after_package_count"] == chat_normalized["after_package_count"] == 2
    )
    normalized_summaries_equal = original_normalized == chat_normalized

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-resume-picker-transcript-scroll-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "picker_transcript_overlay_title_seen": picker_transcript_overlay_title_seen,
        "picker_transcript_initial_bottom_seen": picker_transcript_initial_bottom_seen,
        "picker_transcript_top_after_home_seen": picker_transcript_top_after_home_seen,
        "picker_transcript_bottom_after_end_seen": picker_transcript_bottom_after_end_seen,
        "picker_returned_after_close": picker_returned_after_close,
        "picker_selected_target_long_history": picker_selected_target_long_history,
        "picker_excluded_decoy_history": picker_excluded_decoy_history,
        "durable_line_counts_equal": durable_line_counts_equal,
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI resume picker long transcript "
            "overlay slice: an exec-created multi-turn target and a decoy "
            "session can be loaded into `codex resume --include-non-interactive`, "
            "typed picker search can focus the target, Ctrl+T can open the "
            "selected row transcript overlay, Home and End can reveal top and "
            "bottom markers through the overlay pager, the resumed TUI sends a "
            "follow-up request containing the target long history and excluding "
            "decoy history, and original and .chat backends keep durable counts "
            "aligned."
        ),
        "not_yet_proven": [
            "full visual resume picker parity across viewport sizes",
            "resume picker pagination beyond two loaded rows",
            "arbitrary transcript overlay scroll positions beyond Home/End",
            "fork picker transcript overlay long-history scrolling",
            "fork picker pagination",
            "running-thread picker/rejoin parity",
            "complete CLI feature parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }

    summary["passed"] = all(
        [
            normalized_summaries_equal,
            picker_transcript_overlay_title_seen,
            picker_transcript_initial_bottom_seen,
            picker_transcript_top_after_home_seen,
            picker_transcript_bottom_after_end_seen,
            picker_returned_after_close,
            picker_selected_target_long_history,
            picker_excluded_decoy_history,
            durable_line_counts_equal,
        ]
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    write_markdown_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
