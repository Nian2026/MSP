#!/usr/bin/env python3
"""Run a real CLI/TUI rollback-many clear-all parity smoke.

This source-backed validation uses ordinary user-facing Codex CLI entry points:

    codex
    type three prompts into the real TUI
    press Esc, Esc, Left, Left, Enter to select the first user prompt
    optionally kill the TUI after the rollback-many marker is durable
    codex exec --json resume --last ...

The TUI does not expose an arbitrary rollback count such as app-server
`numTurns=99`. This smoke therefore proves only a narrow CLI RB02-adjacent
clear-all slice: selecting the first user message rolls back all current user
turns, future context starts from the follow-up prompt only, and durable source
history remains append-only.
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
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    body_contains,
    count_rollback_markers,
    durable_line_counts,
    response_request_count,
    strip_ansi,
    type_prompt_and_enter,
)


USER_TEXTS = [
    "CLI rollback many first turn to clear.",
    "CLI rollback many second turn to clear.",
    "CLI rollback many third turn to clear.",
]
ASSISTANT_TEXTS = [
    "CLI rollback many first answer to clear.",
    "CLI rollback many second answer to clear.",
    "CLI rollback many third answer to clear.",
]
FOLLOWUP_USER_TEXT = "CLI rollback many follow-up after clearing visible history."
FOLLOWUP_ASSISTANT_TEXT = "CLI rollback many follow-up answer from mock model."
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
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_process_kill_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_cumulative_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_stress_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_backtrack.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/input.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/rollout_reconstruction.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    followup_body = bodies[3] if len(bodies) > 3 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_first_user_text": body_contains(first_body, USER_TEXTS[0]),
        "second_body_contains_first_user_text": body_contains(second_body, USER_TEXTS[0]),
        "second_body_contains_first_assistant_text": body_contains(
            second_body,
            ASSISTANT_TEXTS[0],
        ),
        "second_body_contains_second_user_text": body_contains(second_body, USER_TEXTS[1]),
        "third_body_contains_first_user_text": body_contains(third_body, USER_TEXTS[0]),
        "third_body_contains_first_assistant_text": body_contains(
            third_body,
            ASSISTANT_TEXTS[0],
        ),
        "third_body_contains_second_user_text": body_contains(third_body, USER_TEXTS[1]),
        "third_body_contains_second_assistant_text": body_contains(
            third_body,
            ASSISTANT_TEXTS[1],
        ),
        "third_body_contains_third_user_text": body_contains(third_body, USER_TEXTS[2]),
        "followup_body_contains_followup_user_text": body_contains(
            followup_body,
            FOLLOWUP_USER_TEXT,
        ),
        "followup_body_contains_any_cleared_user_text": any(
            body_contains(followup_body, text) for text in USER_TEXTS
        ),
        "followup_body_contains_any_cleared_assistant_text": any(
            body_contains(followup_body, text) for text in ASSISTANT_TEXTS
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


def storage_text_presence(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    texts: list[str],
) -> dict[str, bool]:
    if tree_name == "chat-backend":
        files = [
            path
            for path in chat_root.rglob("*")
            if path.is_file() and path.suffix in {".json", ".ndjson"}
        ]
    else:
        files = [
            path
            for path in codex_home.rglob("*.jsonl")
            if path.is_file()
        ]

    haystack = "\n".join(path.read_text(errors="replace") for path in files)
    return {text: text in haystack for text in texts}


def send_backtrack_prime_key(master: int) -> None:
    os.write(master, b"\x1b")


def send_backtrack_open_overlay_key(master: int) -> None:
    os.write(master, b"\x1b")


def send_backtrack_step_older_key(master: int) -> None:
    # Use the explicit Left arrow inside the transcript overlay. Source routing
    # treats Left like Esc while preview is active, but it avoids racing another
    # bare Esc against overlay open/close handling.
    os.write(master, b"\x1b[D")


def send_backtrack_confirm_key(master: int) -> None:
    os.write(master, b"\r")


def clear_prefilled_composer(master: int) -> None:
    # Backtrack restores the selected user message into the composer. Clear it
    # before shutting down so it cannot be submitted accidentally.
    os.write(master, b"\x15")
    time.sleep(0.1)


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
        rollback_events = [
            event for event in timeline if event.get("type") == "timeline_rollback"
        ]
        packages.append(
            {
                "conversation_id": package_item.get("conversation_id"),
                "timeline_line_count": len(timeline),
                "journal_line_count": len(journal),
                "timeline_event_types": [event.get("type") for event in timeline],
                "timeline_rollback_count": len(rollback_events),
                "timeline_rollback_num_turns": [
                    ((event.get("body") or {}).get("num_turns"))
                    for event in rollback_events
                ],
                "journal_rollback_marker_count": count_rollback_markers(
                    "chat-backend",
                    pathlib.Path("/nonexistent"),
                    chat_root,
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
        "timeline_rollback_num_turns": [
            num_turns
            for package in packages
            for num_turns in package["timeline_rollback_num_turns"]
        ],
        "total_journal_rollback_marker_count": count_rollback_markers(
            "chat-backend",
            pathlib.Path("/nonexistent"),
            chat_root,
        ),
    }


def run_cli_three_turns_clear_all_tui(
    tree_name: str,
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
    *,
    kill_after_marker: bool = False,
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
    sent_prompts = [False, False, False]
    prompt_sent_at: list[float | None] = [None, None, None]
    enter_retry_sent = [False, False, False]
    response_seen_at: list[float | None] = [None, None, None]
    answer_visible_at: list[float | None] = [None, None, None]
    sent_backtrack_prime = False
    sent_backtrack_open_overlay = False
    backtrack_overlay_seen_at: float | None = None
    backtrack_older_steps_sent = 0
    backtrack_last_key_sent_at: float | None = None
    sent_clear_all_backtrack = False
    rollback_marker_seen_at: float | None = None
    sent_clear_after_rollback = False
    sent_ctrl_c = False
    killed_after_rollback_marker = False

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

            visible_tail = output.decode(errors="replace")[-2400:]
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
            if ready_for_prompt and not sent_prompts[0]:
                type_prompt_and_enter(master, USER_TEXTS[0])
                sent_prompts[0] = True
                prompt_sent_at[0] = time.time()

            requests_seen = response_request_count(mock_server.requests)
            output_text = output.decode(errors="replace")
            for index, answer_text in enumerate(ASSISTANT_TEXTS):
                if (
                    sent_prompts[index]
                    and requests_seen >= index + 1
                    and response_seen_at[index] is None
                ):
                    response_seen_at[index] = time.time()
                if (
                    response_seen_at[index] is not None
                    and answer_text in output_text
                    and answer_visible_at[index] is None
                ):
                    answer_visible_at[index] = time.time()

            for index in range(len(USER_TEXTS)):
                if (
                    sent_prompts[index]
                    and requests_seen < index + 1
                    and prompt_sent_at[index] is not None
                    and time.time() - (prompt_sent_at[index] or 0) > 2
                    and not enter_retry_sent[index]
                ):
                    os.write(master, b"\r")
                    enter_retry_sent[index] = True
                if index == 0:
                    continue
                previous_seen_at = answer_visible_at[index - 1]
                if (
                    previous_seen_at is not None
                    and time.time() - previous_seen_at > 1.5
                    and not sent_prompts[index]
                ):
                    type_prompt_and_enter(master, USER_TEXTS[index])
                    sent_prompts[index] = True
                    prompt_sent_at[index] = time.time()

            ready_for_backtrack = (
                answer_visible_at[2] is not None
                and time.time() - (answer_visible_at[2] or 0) > 1.5
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

            overlay_ready_for_step = (
                backtrack_overlay_seen_at is not None
                or (
                    sent_backtrack_open_overlay
                    and backtrack_last_key_sent_at is not None
                    and time.time() - backtrack_last_key_sent_at > 1.6
                )
            )
            if (
                overlay_ready_for_step
                and backtrack_older_steps_sent < 2
                and backtrack_last_key_sent_at is not None
                and time.time() - backtrack_last_key_sent_at > 0.7
            ):
                send_backtrack_step_older_key(master)
                backtrack_older_steps_sent += 1
                backtrack_last_key_sent_at = time.time()

            if (
                overlay_ready_for_step
                and backtrack_older_steps_sent == 2
                and not sent_clear_all_backtrack
                and backtrack_last_key_sent_at is not None
                and time.time() - backtrack_last_key_sent_at > 0.7
            ):
                send_backtrack_confirm_key(master)
                sent_clear_all_backtrack = True
                backtrack_last_key_sent_at = time.time()

            current_markers = count_rollback_markers(tree_name, codex_home, chat_root)
            if (
                sent_clear_all_backtrack
                and rollback_marker_seen_at is None
                and current_markers >= rollback_markers_before + 1
            ):
                rollback_marker_seen_at = time.time()

            if rollback_marker_seen_at is not None:
                if not sent_clear_after_rollback:
                    clear_prefilled_composer(master)
                    sent_clear_after_rollback = True
                marker_age = time.time() - rollback_marker_seen_at
                if kill_after_marker and marker_age >= ROLLBACK_MARKER_IDLE_SECONDS:
                    process.kill()
                    killed_after_rollback_marker = True
                    break
                if marker_age > 2 and not sent_ctrl_c:
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
        "sent_prompts": sent_prompts,
        "responses_seen": [item is not None for item in response_seen_at],
        "answers_visible": [item is not None for item in answer_visible_at],
        "enter_retry_sent": enter_retry_sent,
        "sent_backtrack_prime": sent_backtrack_prime,
        "sent_backtrack_open_overlay": sent_backtrack_open_overlay,
        "backtrack_overlay_marker_seen": backtrack_overlay_seen_at is not None,
        "backtrack_older_steps_sent": backtrack_older_steps_sent,
        "sent_clear_all_backtrack": sent_clear_all_backtrack,
        "rollback_marker_seen": rollback_marker_seen_at is not None,
        "sent_clear_after_rollback": sent_clear_after_rollback,
        "sent_ctrl_c": sent_ctrl_c,
        "killed_after_rollback_marker": killed_after_rollback_marker,
        "killed_by_sigkill": exit_code == -9,
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
    *,
    kill_after_marker: bool = False,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with SequenceMockResponsesServer([*ASSISTANT_TEXTS, FOLLOWUP_ASSISTANT_TEXT]) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        rollback_tui = run_cli_three_turns_clear_all_tui(
            tree_name,
            codex_bin,
            workspace,
            codex_home,
            chat_root,
            config_overrides,
            mock_server,
            kill_after_marker=kill_after_marker,
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
            "storage_text_presence": storage_text_presence(
                tree_name,
                codex_home,
                chat_root,
                [*USER_TEXTS, *ASSISTANT_TEXTS],
            ),
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=pathlib.Path)
    parser.add_argument("--kill-after-marker", action="store_true")
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    scope_slug = (
        "cli-rollback-many-process-kill-smoke"
        if args.kill_after_marker
        else "cli-rollback-many-smoke"
    )
    output_dir = (
        args.output_dir
        or validation_results_root()
        / (scope_slug + "-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
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
        kill_after_marker=args.kill_after_marker,
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        kill_after_marker=args.kill_after_marker,
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
            original_mock["response_request_count"] == 4,
            chat_mock["response_request_count"] == 4,
            original_mock["followup_body_contains_followup_user_text"],
            chat_mock["followup_body_contains_followup_user_text"],
            not original_mock["followup_body_contains_any_cleared_user_text"],
            not chat_mock["followup_body_contains_any_cleared_user_text"],
            not original_mock["followup_body_contains_any_cleared_assistant_text"],
            not chat_mock["followup_body_contains_any_cleared_assistant_text"],
        ]
    )
    storage_text_preserved = all(
        [
            all(original_result["storage_text_presence"].values()),
            all(chat_result["storage_text_presence"].values()),
        ]
    )
    chat_rollback_num_turns = chat_package.get("timeline_rollback_num_turns") or []
    original_completion_ok = (
        original_result["rollback_tui"].get("killed_by_sigkill")
        if args.kill_after_marker
        else original_result["rollback_tui"].get("exit_code") == 0
    )
    chat_completion_ok = (
        chat_result["rollback_tui"].get("killed_by_sigkill")
        if args.kill_after_marker
        else chat_result["rollback_tui"].get("exit_code") == 0
    )
    process_kill_checks = [
        original_result["rollback_tui"].get("killed_after_rollback_marker"),
        chat_result["rollback_tui"].get("killed_after_rollback_marker"),
        original_result["rollback_tui"].get("killed_by_sigkill"),
        chat_result["rollback_tui"].get("killed_by_sigkill"),
    ]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": scope_slug,
        "matrix_slice": [
            "RB02-adjacent",
            "R01-adjacent",
            *(
                ["H05-adjacent-process-kill-after-durable-rollback-many-marker"]
                if args.kill_after_marker
                else []
            ),
        ],
        "is_final_parity_claim": False,
        "kill_after_marker": args.kill_after_marker,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_rollback_tui_completion_ok": original_completion_ok,
        "chat_backend_rollback_tui_completion_ok": chat_completion_ok,
        "original_rollback_tui_exit_ok": original_result["rollback_tui"].get("exit_code")
        == 0,
        "chat_backend_rollback_tui_exit_ok": chat_result["rollback_tui"].get("exit_code")
        == 0,
        "original_rollback_tui_killed_by_sigkill": original_result["rollback_tui"].get(
            "killed_by_sigkill"
        ),
        "chat_backend_rollback_tui_killed_by_sigkill": chat_result["rollback_tui"].get(
            "killed_by_sigkill"
        ),
        "original_killed_after_rollback_marker": original_result["rollback_tui"].get(
            "killed_after_rollback_marker"
        ),
        "chat_backend_killed_after_rollback_marker": chat_result["rollback_tui"].get(
            "killed_after_rollback_marker"
        ),
        "original_tui_prompts_and_responses_seen": all(
            [
                all(original_result["rollback_tui"].get("sent_prompts") or []),
                all(original_result["rollback_tui"].get("responses_seen") or []),
                all(original_result["rollback_tui"].get("answers_visible") or []),
            ]
        ),
        "chat_backend_tui_prompts_and_responses_seen": all(
            [
                all(chat_result["rollback_tui"].get("sent_prompts") or []),
                all(chat_result["rollback_tui"].get("responses_seen") or []),
                all(chat_result["rollback_tui"].get("answers_visible") or []),
            ]
        ),
        "original_clear_all_backtrack_sent": original_result["rollback_tui"].get(
            "sent_clear_all_backtrack"
        ),
        "chat_backend_clear_all_backtrack_sent": chat_result["rollback_tui"].get(
            "sent_clear_all_backtrack"
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
        "followup_context_contains_only_followup_turn": followup_context_ok,
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
        "durable_line_counts_equal_after_followup": original_result["final_line_counts"]
        == chat_result["final_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "chat_backend_timeline_rollback_count_expected_one": chat_package.get(
            "total_timeline_rollback_count"
        )
        == 1,
        "chat_backend_journal_rollback_count_expected_one": chat_package.get(
            "total_journal_rollback_marker_count"
        )
        == 1,
        "chat_backend_timeline_rollback_num_turns_expected_three": chat_rollback_num_turns
        == [3],
        "chat_backend_standard_projections_ok": chat_package.get(
            "all_packages_have_standard_projections"
        ),
        "source_history_preserved_despite_visible_clear": storage_text_preserved,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_rollback_tui": original_result["rollback_tui"],
        "chat_backend_rollback_tui": chat_result["rollback_tui"],
        "chat_package_summary": chat_package,
        "original_storage_text_presence": original_result["storage_text_presence"],
        "chat_backend_storage_text_presence": chat_result["storage_text_presence"],
        "not_yet_proven": [
            "arbitrary over-count rollback through a user-facing CLI surface",
            "rollback during active turn RB04 through CLI",
            "rollback after compaction RB05 through CLI",
            "picker/overlay visual parity beyond successful Esc/Esc/Left/Left/Enter command dispatch",
            *(
                [
                    "process kill before rollback marker is durable",
                    "process kill during rollback request before app-server response",
                    "rollback during active turn RB04 through a process-kill boundary",
                    "rollback after compaction RB05 through a process-kill boundary",
                ]
                if args.kill_after_marker
                else ["true process-kill rollback recovery"]
            ),
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }
    summary["passed"] = all(
        [
            summary["original_rollback_tui_completion_ok"],
            summary["chat_backend_rollback_tui_completion_ok"],
            *(process_kill_checks if args.kill_after_marker else []),
            summary["original_tui_prompts_and_responses_seen"],
            summary["chat_backend_tui_prompts_and_responses_seen"],
            summary["original_clear_all_backtrack_sent"],
            summary["chat_backend_clear_all_backtrack_sent"],
            summary["original_rollback_marker_seen"],
            summary["chat_backend_rollback_marker_seen"],
            summary["original_followup_exec_ok"],
            summary["chat_backend_followup_exec_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["followup_context_contains_only_followup_turn"],
            summary["rollback_marker_counts_equal"],
            summary["rollback_marker_counts_expected_one"],
            summary["durable_line_counts_equal_after_followup"],
            summary["chat_backend_timeline_rollback_count_expected_one"],
            summary["chat_backend_journal_rollback_count_expected_one"],
            summary["chat_backend_timeline_rollback_num_turns_expected_three"],
            summary["chat_backend_standard_projections_ok"],
            summary["source_history_preserved_despite_visible_clear"],
        ]
    )

    write_json(output_dir / "original/cli-rollback-many-response.json", original_result)
    write_json(output_dir / "chat-backend/cli-rollback-many-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report_title = (
        "CLI Rollback Many Process-Kill Smoke"
        if args.kill_after_marker
        else "CLI Rollback Many Smoke"
    )
    process_kill_scope_line = (
        "SIGKILL the TUI after the rollback-many marker is durably observable\n"
        if args.kill_after_marker
        else ""
    )
    process_kill_result_lines = (
        f"- original TUI killed by SIGKILL: `{summary['original_rollback_tui_killed_by_sigkill']}`\n"
        f"- `.chat` TUI killed by SIGKILL: `{summary['chat_backend_rollback_tui_killed_by_sigkill']}`\n"
        f"- original killed after rollback marker: `{summary['original_killed_after_rollback_marker']}`\n"
        f"- `.chat` killed after rollback marker: `{summary['chat_backend_killed_after_rollback_marker']}`\n"
        if args.kill_after_marker
        else ""
    )
    process_kill_not_yet = (
        "This smoke does not prove process death before rollback marker durability, "
        "death during the rollback request, RB04/RB05 through process-kill "
        "boundaries, complete data fidelity, or final user-indistinguishability."
        if args.kill_after_marker
        else "This smoke does not prove arbitrary over-count rollback through a "
        "user-facing CLI surface, rollback during active turn, rollback after "
        "compaction, picker/overlay visual parity beyond successful "
        "Esc/Esc/Left/Left/Enter command dispatch, true process-kill rollback "
        "recovery, complete data fidelity, or final user-indistinguishability."
    )

    report = f"""# {report_title} - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives ordinary user-facing CLI/TUI entry points and a local mock Responses
API.

## Scope

```text
codex
type three prompts in the real TUI
Esc, Esc, Left, Left, Enter in the real TUI backtrack flow
{process_kill_scope_line}\
codex exec --json resume --last ...
```

This proves only a narrow RB02-adjacent CLI clear-all slice: selecting the first
user message in the real TUI rolls back all current user turns, then a follow-up
CLI resume request starts from the follow-up prompt only. The app-server
`numTurns=99` overflow path remains the exact over-count oracle; this smoke only
proves what the ordinary TUI exposes.
When `--kill-after-marker` is set, it additionally covers the H05-adjacent
boundary after the rollback-many marker is durable and before a clean TUI
shutdown.

## Result

- passed: `{summary['passed']}`
- original rollback TUI exit ok: `{summary['original_rollback_tui_exit_ok']}`
- `.chat` rollback TUI exit ok: `{summary['chat_backend_rollback_tui_exit_ok']}`
- original rollback TUI completion ok: `{summary['original_rollback_tui_completion_ok']}`
- `.chat` rollback TUI completion ok: `{summary['chat_backend_rollback_tui_completion_ok']}`
{process_kill_result_lines}\
- original TUI prompts/responses seen: `{summary['original_tui_prompts_and_responses_seen']}`
- `.chat` TUI prompts/responses seen: `{summary['chat_backend_tui_prompts_and_responses_seen']}`
- original clear-all backtrack sent: `{summary['original_clear_all_backtrack_sent']}`
- `.chat` clear-all backtrack sent: `{summary['chat_backend_clear_all_backtrack_sent']}`
- original rollback marker seen: `{summary['original_rollback_marker_seen']}`
- `.chat` rollback marker seen: `{summary['chat_backend_rollback_marker_seen']}`
- normalized follow-up exec equal: `{summary['normalized_followup_exec_equal']}`
- mock request summaries equal: `{summary['mock_request_summaries_equal']}`
- follow-up context contains only follow-up turn: `{summary['followup_context_contains_only_followup_turn']}`
- rollback marker counts equal: `{summary['rollback_marker_counts_equal']}`
- rollback marker counts expected one: `{summary['rollback_marker_counts_expected_one']}`
- durable line counts equal after follow-up: `{summary['durable_line_counts_equal_after_followup']}`
- `.chat` timeline rollback count expected one: `{summary['chat_backend_timeline_rollback_count_expected_one']}`
- `.chat` journal rollback count expected one: `{summary['chat_backend_journal_rollback_count_expected_one']}`
- `.chat` timeline rollback num_turns expected three: `{summary['chat_backend_timeline_rollback_num_turns_expected_three']}`
- `.chat` standard projections ok: `{summary['chat_backend_standard_projections_ok']}`
- source history preserved despite visible clear: `{summary['source_history_preserved_despite_visible_clear']}`

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

## Storage Text Presence

```json
{json.dumps({'original': summary['original_storage_text_presence'], 'chat_backend': summary['chat_backend_storage_text_presence']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-rollback-many-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-rollback-many-response.json
```

## Not Yet Proven

{process_kill_not_yet}
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
