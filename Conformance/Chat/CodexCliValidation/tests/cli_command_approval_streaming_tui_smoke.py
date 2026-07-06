#!/usr/bin/env python3
"""Run real TUI approval-state command streaming parity smoke.

This source-backed validation combines two previously separate user-facing slices:

    codex
    type a prompt that triggers shell_command approval
    accept the approval in the TUI
    observe stdout/stderr stream markers before the final answer
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final approval, command-streaming, crash-recovery, or
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

from app_server_command_approval_smoke import write_approval_config  # noqa: E402
from app_server_command_execution_smoke import (  # noqa: E402
    ev_completed,
    ev_response_created,
    sse,
    summarize_command_timeline,
)
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
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


USER_TEXT = "Run the TUI approval streaming .chat parity smoke."
FOLLOWUP_USER_TEXT = "TUI approval streaming follow-up."
FINAL_TEXT = "TUI approval streaming smoke complete."
FOLLOWUP_TEXT = "TUI approval streaming follow-up complete."
STREAM_CALL_ID = "call-command-approval-streaming-tui"
STREAM_MARKERS = [
    "APPROVAL_STREAM_STDOUT_1",
    "APPROVAL_STREAM_STDERR_1",
    "APPROVAL_STREAM_STDOUT_2",
    "APPROVAL_STREAM_STDERR_2",
    "APPROVAL_STREAM_STDOUT_3",
    "APPROVAL_STREAM_STDERR_3",
]

# Build the marker prefix inside Python so the full markers do not appear in the
# approval overlay's command text before the command has actually run.
STREAM_COMMAND = (
    "python3 -c 'import sys, time; "
    "p=\"APPR\"+\"OVAL_STREAM_\"; "
    "print(p+\"STDOUT_\"+str(1), flush=True); time.sleep(0.25); "
    "print(p+\"STDERR_\"+str(1), file=sys.stderr, flush=True); time.sleep(0.25); "
    "print(p+\"STDOUT_\"+str(2), flush=True); time.sleep(0.25); "
    "print(p+\"STDERR_\"+str(2), file=sys.stderr, flush=True); time.sleep(0.25); "
    "print(p+\"STDOUT_\"+str(3), flush=True); time.sleep(0.25); "
    "print(p+\"STDERR_\"+str(3), file=sys.stderr, flush=True)'"
)
APPROVAL_IDLE_SECONDS = 1.4

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
    "Conformance/Chat/CodexCliValidation/tests/cli_command_streaming_tui_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server-protocol/src/protocol/v2/item.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def ev_shell_command_call(response_id: str, call_id: str, command: str) -> bytes:
    arguments = json.dumps(
        {
            "command": command,
            "workdir": None,
            "timeout_ms": 10000,
        },
        separators=(",", ":"),
    )
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": call_id,
                    "name": "shell_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message(response_id: str, message_id: str, text: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": message_id,
                    "content": [{"type": "output_text", "text": text}],
                },
            },
            ev_completed(response_id),
        ]
    )


class ApprovalStreamingTuiResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FOLLOWUP_TEXT)
        self.responses = [
            ev_shell_command_call(
                "resp-cli-approval-stream-1",
                STREAM_CALL_ID,
                STREAM_COMMAND,
            ),
            ev_final_message(
                "resp-cli-approval-stream-2",
                "msg-cli-approval-stream-final",
                FINAL_TEXT,
            ),
            ev_final_message(
                "resp-cli-approval-stream-3",
                "msg-cli-approval-stream-followup",
                FOLLOWUP_TEXT,
            ),
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter <= len(self.responses):
            return self.responses[counter - 1]
        return ev_final_message(
            f"resp-cli-approval-stream-extra-{counter}",
            f"msg-cli-approval-stream-extra-{counter}",
            FOLLOWUP_TEXT,
        )


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    serialized = [json.dumps(body, ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "second_body_contains_function_output": any(
            STREAM_CALL_ID in body and "function_call_output" in body
            for body in serialized[1:2]
        ),
        "second_body_contains_all_markers": all(
            marker in json.dumps(second_body, ensure_ascii=False)
            for marker in STREAM_MARKERS
        ),
        "third_body_contains_followup_user_text": body_contains(third_body, FOLLOWUP_USER_TEXT),
        "third_body_contains_original_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_final_text": FINAL_TEXT in json.dumps(third_body, ensure_ascii=False),
        "third_body_contains_all_markers": all(
            marker in json.dumps(third_body, ensure_ascii=False)
            for marker in STREAM_MARKERS
        ),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def ordered_marker_positions(text: str) -> dict[str, int | None]:
    return {
        marker: (text.find(marker) if marker in text else None)
        for marker in STREAM_MARKERS
    }


def marker_sequence_ok(positions: dict[str, int | None]) -> bool:
    values = [positions[marker] for marker in STREAM_MARKERS]
    if any(value is None for value in values):
        return False
    numeric_values = [int(value) for value in values if value is not None]
    return numeric_values == sorted(numeric_values) and len(set(numeric_values)) == len(numeric_values)


def run_cli_approval_streaming_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: ApprovalStreamingTuiResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    master, slave = pty.openpty()
    try:
        import fcntl
        import termios

        winsize = struct.pack("HHHH", 34, 120, 0, 0)
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
    sent_prompt = False
    prompt_sent_at: float | None = None
    prompt_enter_retry_sent = False
    approval_visible_at: float | None = None
    sent_approval_accept = False
    marker_first_seen: dict[str, float] = {}
    final_answer_visible_at: float | None = None
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 95:
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

            visible_text = output.decode(errors="replace")
            visible_tail = visible_text[-2800:]
            stripped_text = strip_ansi(visible_text)
            stripped_tail = stripped_text[-2800:]
            compact_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))

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
                sent_trust_continue = True

            if (
                sent_trust_answer
                and not sent_trust_continue
                and "Pressentertocontinue" in compact_tail
            ):
                os.write(master, b"\r")
                sent_trust_continue = True

            if "Continue anyway?" in stripped_tail and not sent_term_gate_answer:
                os.write(master, b"y\r")
                sent_term_gate_answer = True

            ready_for_prompt = (
                "OpenAICodex" in compact_tail
                and "mock-model" in compact_tail
                and (
                    sent_trust_continue
                    or "Doyoutrustthecontentsofthisdirectory?" not in compact_tail
                )
            )
            if ready_for_prompt and not sent_prompt:
                type_prompt_and_enter(master, USER_TEXT)
                sent_prompt = True
                prompt_sent_at = time.time()

            if (
                sent_prompt
                and response_request_count(mock_server.requests) < 1
                and prompt_sent_at is not None
                and time.time() - prompt_sent_at > 2.0
                and not prompt_enter_retry_sent
            ):
                os.write(master, b"\r")
                prompt_enter_retry_sent = True

            if (
                "Wouldyouliketorunthefollowingcommand?" in compact_tail
                and approval_visible_at is None
            ):
                approval_visible_at = time.time()

            if (
                approval_visible_at is not None
                and not sent_approval_accept
                and time.time() - approval_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"y")
                sent_approval_accept = True

            if sent_approval_accept:
                for marker in STREAM_MARKERS:
                    if marker not in marker_first_seen and marker in stripped_text:
                        marker_first_seen[marker] = time.time()

            if FINAL_TEXT in stripped_text and final_answer_visible_at is None:
                final_answer_visible_at = time.time()

            if (
                final_answer_visible_at is not None
                and time.time() - final_answer_visible_at > 1.5
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

    stripped_output = strip_ansi(output.decode(errors="replace"))
    marker_positions = ordered_marker_positions(stripped_output)
    final_position = stripped_output.find(FINAL_TEXT) if FINAL_TEXT in stripped_output else None
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_prompt": sent_prompt,
        "prompt_enter_retry_sent": prompt_enter_retry_sent,
        "approval_prompt_visible": approval_visible_at is not None,
        "sent_approval_accept": sent_approval_accept,
        "final_answer_visible": final_answer_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "markers_seen": sorted(marker_first_seen),
        "all_markers_visible": all(marker in marker_first_seen for marker in STREAM_MARKERS),
        "marker_positions": marker_positions,
        "marker_sequence_in_output": marker_sequence_ok(marker_positions),
        "final_position": final_position,
        "all_markers_before_final": (
            final_position is not None
            and all(
                position is not None and position < final_position
                for position in marker_positions.values()
            )
        ),
        "output_tail_stripped": stripped_output[-4000:],
        "raw_output_bytes": len(output),
    }


def durable_line_counts(summary: dict[str, Any], tree_name: str) -> list[int]:
    if tree_name == "chat-backend":
        return sorted(
            package.get("journal_line_count")
            for package in (summary.get("packages") or [])
            if package.get("journal_line_count") is not None
        )
    return sorted(
        rollout.get("line_count")
        for rollout in (summary.get("rollouts") or [])
        if rollout.get("line_count") is not None
        and (
            (rollout.get("path") or "").startswith("sessions/")
            or (rollout.get("path") or "").startswith("archived_sessions/")
        )
    )


def summarize_chat_streaming_retention(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        journal_lines = read_json_lines(package / "journal.ndjson")
        command_outputs = []
        for line in journal_lines:
            payload = (
                ((line.get("source_transport") or {}).get("payload") or {}).get("payload")
                or {}
            )
            if (
                payload.get("type") == "function_call_output"
                and payload.get("call_id") == STREAM_CALL_ID
            ):
                output = payload.get("output") or ""
                command_outputs.append(
                    {
                        "contains_all_markers": all(marker in output for marker in STREAM_MARKERS),
                        "output_length": len(output),
                    }
                )
        packages.append(
            {
                "package": str(package),
                "command_output_count": len(command_outputs),
                "command_outputs": command_outputs,
            }
        )
    return {
        "package_count": len(packages),
        "packages": packages,
        "has_full_streaming_output": any(
            command_output.get("contains_all_markers")
            for package in packages
            for command_output in package.get("command_outputs", [])
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

    with ApprovalStreamingTuiResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        approval_streaming_tui = run_cli_approval_streaming_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        after_tui_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        followup_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_last=True,
        )
        final_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

    result: dict[str, Any] = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "approval_streaming_tui": approval_streaming_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["command_timeline_summary"] = summarize_command_timeline(chat_root)
        result["streaming_retention_summary"] = summarize_chat_streaming_retention(chat_root)
    return result


def command_timeline_has_streaming_call(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    call_ids = [
        call_id
        for package in packages
        for call_id in package.get("call_ids", [])
    ]
    event_types = [
        event_type
        for package in packages
        for event_type in package.get("command_event_types", [])
    ]
    return (
        STREAM_CALL_ID in call_ids
        and "command_call" in event_types
        and "command_output" in event_types
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-command-approval-streaming-tui-smoke-"
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

    original_tui = original_result["approval_streaming_tui"]
    chat_tui = chat_result["approval_streaming_tui"]
    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    command_timeline_summary = chat_result["command_timeline_summary"]
    streaming_retention_summary = chat_result["streaming_retention_summary"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-command-approval-streaming-tui-smoke",
        "matrix_slice": ["T03-adjacent", "T06-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_exit_ok": original_tui["exit_code"] in {0, 130, -2},
        "chat_backend_tui_exit_ok": chat_tui["exit_code"] in {0, 130, -2},
        "original_tui_prompt_sent": original_tui["sent_prompt"],
        "chat_backend_tui_prompt_sent": chat_tui["sent_prompt"],
        "original_tui_reached_approval": original_tui["approval_prompt_visible"],
        "chat_backend_tui_reached_approval": chat_tui["approval_prompt_visible"],
        "original_tui_sent_accept": original_tui["sent_approval_accept"],
        "chat_backend_tui_sent_accept": chat_tui["sent_approval_accept"],
        "original_tui_final_visible": original_tui["final_answer_visible"],
        "chat_backend_tui_final_visible": chat_tui["final_answer_visible"],
        "original_tui_all_markers_visible": original_tui["all_markers_visible"],
        "chat_backend_tui_all_markers_visible": chat_tui["all_markers_visible"],
        "original_marker_sequence_in_output": original_tui["marker_sequence_in_output"],
        "chat_backend_marker_sequence_in_output": chat_tui["marker_sequence_in_output"],
        "original_all_markers_before_final": original_tui["all_markers_before_final"],
        "chat_backend_all_markers_before_final": chat_tui["all_markers_before_final"],
        "tui_response_request_counts_equal_after_streaming": (
            original_tui["response_request_count_after_tui"]
            == chat_tui["response_request_count_after_tui"]
            == 2
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "mock_command_output_round_trip": (
            original_mock["second_body_contains_function_output"]
            and chat_mock["second_body_contains_function_output"]
            and original_mock["second_body_contains_all_markers"]
            and chat_mock["second_body_contains_all_markers"]
        ),
        "followup_context_preserved_after_approval_streaming": (
            original_mock["third_body_contains_original_user_text"]
            and chat_mock["third_body_contains_original_user_text"]
            and original_mock["third_body_contains_final_text"]
            and chat_mock["third_body_contains_final_text"]
            and original_mock["third_body_contains_all_markers"]
            and chat_mock["third_body_contains_all_markers"]
        ),
        "final_durable_line_counts_equal": (
            original_result["final_line_counts"] == chat_result["final_line_counts"]
            and bool(original_result["final_line_counts"])
        ),
        "chat_backend_has_command_timeline": command_timeline_has_streaming_call(
            command_timeline_summary
        ),
        "chat_backend_journal_retains_full_streaming_output": streaming_retention_summary[
            "has_full_streaming_output"
        ],
        "original": {
            "approval_streaming_tui": original_tui,
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "final_line_counts": original_result["final_line_counts"],
        },
        "chat_backend": {
            "approval_streaming_tui": chat_tui,
            "followup_exec": {
                "command": chat_followup["command"],
                "exit_code": chat_followup["exit_code"],
                "normalized_events": normalize_exec_events(chat_followup["events"]),
                "stderr_tail": chat_followup["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "final_line_counts": chat_result["final_line_counts"],
            "command_timeline_summary": command_timeline_summary,
            "streaming_retention_summary": streaming_retention_summary,
        },
        "not_yet_proven": [
            "network/file-change/additional-permission approval TUI variants",
            "command execution crash recovery",
            "standard artifact/blob references for command-created files",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_exit_ok"],
            summary["chat_backend_tui_exit_ok"],
            summary["original_tui_prompt_sent"],
            summary["chat_backend_tui_prompt_sent"],
            summary["original_tui_reached_approval"],
            summary["chat_backend_tui_reached_approval"],
            summary["original_tui_sent_accept"],
            summary["chat_backend_tui_sent_accept"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["original_tui_all_markers_visible"],
            summary["chat_backend_tui_all_markers_visible"],
            summary["original_marker_sequence_in_output"],
            summary["chat_backend_marker_sequence_in_output"],
            summary["original_all_markers_before_final"],
            summary["chat_backend_all_markers_before_final"],
            summary["tui_response_request_counts_equal_after_streaming"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_command_output_round_trip"],
            summary["followup_context_preserved_after_approval_streaming"],
            summary["final_durable_line_counts_equal"],
            summary["chat_backend_has_command_timeline"],
            summary["chat_backend_journal_retains_full_streaming_output"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow real TUI approval-state command streaming slice: "
        "both original and .chat-backend Codex reach the command approval prompt, "
        "accept the command through the TUI shortcut, show stdout/stderr stream "
        "markers in order before the final answer, preserve the approved command "
        "output for follow-up resume context, keep durable line counts equal, "
        "retain the full streaming output in the .chat source transport, and map "
        "the command into the neutral .chat command timeline. It is not final "
        "approval, command-streaming, crash-recovery, or user-indistinguishability "
        "evidence."
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
