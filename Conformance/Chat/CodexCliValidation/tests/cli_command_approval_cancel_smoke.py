#!/usr/bin/env python3
"""Run real CLI/TUI command approval cancel parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a shell_command approval
    press the TUI shortcut for "No, and tell Codex what to do differently"
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06 approval or user-indistinguishability claim.
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

from app_server_command_approval_smoke import (  # noqa: E402
    DECLINE_CALL_ID,
    DECLINE_COMMAND,
    DECLINE_FINAL_TEXT,
    DECLINE_USER_TEXT,
    ev_final_message,
    ev_shell_command_call,
    summarize_chat_timeline,
    summarize_original_rollouts,
    write_approval_config,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    MockResponsesServer,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from cli_command_approval_smoke import durable_line_counts  # noqa: E402
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


FOLLOWUP_USER_TEXT = "CLI approval cancel follow-up after rejected command."
FOLLOWUP_ASSISTANT_TEXT = "CLI approval cancel follow-up answer from mock model."
CANCEL_IDLE_SECONDS = 1.8
REJECTION_TEXT = "exec command rejected by user"
DECLINE_OUTPUT_MARKER = "APPROVAL_DECLINE_SHOULD_NOT_RUN"

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
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/events.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class ApprovalCancelTuiResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FOLLOWUP_ASSISTANT_TEXT)
        self.responses = [
            ev_shell_command_call("resp-cli-approval-decline-1", DECLINE_CALL_ID, DECLINE_COMMAND),
            ev_final_message(
                "resp-cli-approval-decline-2",
                "msg-cli-approval-decline-final",
                DECLINE_FINAL_TEXT,
            ),
            ev_final_message(
                "resp-cli-approval-decline-3",
                "msg-cli-approval-decline-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter <= len(self.responses):
            return self.responses[counter - 1]
        return ev_final_message(
            f"resp-cli-approval-decline-extra-{counter}",
            f"msg-cli-approval-decline-extra-{counter}",
            FOLLOWUP_ASSISTANT_TEXT,
        )


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, DECLINE_USER_TEXT),
        "second_body_contains_function_output_text": (
            serialized_contains(second_body, DECLINE_CALL_ID)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_followup_user_text": body_contains(second_body, FOLLOWUP_USER_TEXT),
        "second_body_contains_original_user_text": body_contains(second_body, DECLINE_USER_TEXT),
        "second_body_contains_cancel_message": serialized_contains(
            second_body,
            "Conversation interrupted",
        ),
        "second_body_contains_rejection_text": serialized_contains(second_body, REJECTION_TEXT),
        "second_body_contains_decline_command_output": serialized_contains(
            second_body,
            DECLINE_OUTPUT_MARKER,
        ),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_approval_cancel_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: ApprovalCancelTuiResponsesServer,
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

        winsize = struct.pack("HHHH", 30, 110, 0, 0)
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
    sent_cancel = False
    final_answer_visible_at: float | None = None
    cancel_message_visible_at: float | None = None
    no_output_visible_at: float | None = None
    interrupted_visible_at: float | None = None
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

            decoded_output = output.decode(errors="replace")
            visible_tail = decoded_output[-2600:]
            stripped_tail = strip_ansi(visible_tail)
            compact_tail = re.sub(r"\s+", "", stripped_tail)

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
                type_prompt_and_enter(master, DECLINE_USER_TEXT)
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

            approval_visible = (
                "Wouldyouliketorunthefollowingcommand?" in compact_tail
                or DECLINE_OUTPUT_MARKER in compact_tail
            )
            if approval_visible and approval_visible_at is None:
                approval_visible_at = time.time()

            if (
                approval_visible_at is not None
                and not sent_cancel
                and time.time() - approval_visible_at >= CANCEL_IDLE_SECONDS
            ):
                os.write(master, b"n")
                sent_cancel = True

            if DECLINE_FINAL_TEXT in decoded_output and final_answer_visible_at is None:
                final_answer_visible_at = time.time()

            if "You canceled the request to run" in decoded_output and cancel_message_visible_at is None:
                cancel_message_visible_at = time.time()

            if "(no output)" in decoded_output and no_output_visible_at is None:
                no_output_visible_at = time.time()

            if "Conversation interrupted" in decoded_output and interrupted_visible_at is None:
                interrupted_visible_at = time.time()

            if (
                interrupted_visible_at is not None
                and time.time() - interrupted_visible_at > 1.0
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
        "sent_cancel": sent_cancel,
        "final_answer_visible": final_answer_visible_at is not None,
        "cancel_message_visible": (
            cancel_message_visible_at is not None
            or "You canceled the request to run" in stripped_output
        ),
        "no_output_visible": no_output_visible_at is not None or "(no output)" in stripped_output,
        "interrupted_visible": (
            interrupted_visible_at is not None or "Conversation interrupted" in stripped_output
        ),
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-3000:],
        "raw_output_bytes": len(output),
    }


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    timeline = summarize_chat_timeline(chat_root)
    summary = summarize_chat_packages(chat_root)
    serialized = json.dumps(timeline, ensure_ascii=False)
    return {
        "summary": summary,
        "timeline": timeline,
        "package_count": summary.get("package_count"),
        "timeline_has_command_call": any(
            package.get("timeline_has_command_call")
            for package in timeline.get("packages") or []
        ),
        "timeline_has_command_output": any(
            package.get("timeline_has_command_output")
            for package in timeline.get("packages") or []
        ),
        "journal_has_shell_function_call": any(
            package.get("journal_has_shell_function_call")
            for package in timeline.get("packages") or []
        ),
        "journal_has_function_call_output": any(
            package.get("journal_has_function_call_output")
            for package in timeline.get("packages") or []
        ),
        "journal_contains_decline_rejection": any(
            package.get("journal_contains_decline_rejection")
            for package in timeline.get("packages") or []
        ),
        "timeline_or_journal_contains_decline_command_output": DECLINE_OUTPUT_MARKER
        in serialized,
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

    with ApprovalCancelTuiResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        approval_tui = run_cli_approval_cancel_tui(
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
        "approval_tui": approval_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["chat_package_observation"] = chat_package_observation(chat_root)
    else:
        result["original_rollout_summary"] = summarize_original_rollouts(codex_home)
    return result


def original_has_cancel_command_call_without_output(result: dict[str, Any]) -> bool:
    rollouts = result["original_rollout_summary"].get("rollouts") or []
    return (
        any("shell_command" in rollout.get("function_call_names", []) for rollout in rollouts)
        and not any(rollout.get("function_call_output_call_ids") for rollout in rollouts)
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-command-approval-cancel-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_lines = original_result["final_line_counts"]
    chat_lines = chat_result["final_line_counts"]
    chat_package = chat_result["chat_package_observation"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-command-approval-cancel-smoke",
        "matrix_slice": ["T06-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_reached_approval": original_result["approval_tui"][
            "approval_prompt_visible"
        ],
        "chat_backend_tui_reached_approval": chat_result["approval_tui"][
            "approval_prompt_visible"
        ],
        "original_tui_sent_cancel": original_result["approval_tui"]["sent_cancel"],
        "chat_backend_tui_sent_cancel": chat_result["approval_tui"]["sent_cancel"],
        "original_tui_final_visible": original_result["approval_tui"]["final_answer_visible"],
        "chat_backend_tui_final_visible": chat_result["approval_tui"]["final_answer_visible"],
        "original_tui_cancel_message_visible": original_result["approval_tui"][
            "cancel_message_visible"
        ],
        "chat_backend_tui_cancel_message_visible": chat_result["approval_tui"][
            "cancel_message_visible"
        ],
        "original_tui_no_output_visible": original_result["approval_tui"]["no_output_visible"],
        "chat_backend_tui_no_output_visible": chat_result["approval_tui"]["no_output_visible"],
        "original_tui_interrupted_visible": original_result["approval_tui"][
            "interrupted_visible"
        ],
        "chat_backend_tui_interrupted_visible": chat_result["approval_tui"][
            "interrupted_visible"
        ],
        "tui_response_request_counts_equal_after_cancel": (
            original_result["approval_tui"]["response_request_count_after_tui"]
            == chat_result["approval_tui"]["response_request_count_after_tui"]
            == 1
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "followup_context_preserved_after_cancel": (
            original_mock["second_body_contains_original_user_text"]
            and chat_mock["second_body_contains_original_user_text"]
            and original_mock["second_body_contains_followup_user_text"]
            and chat_mock["second_body_contains_followup_user_text"]
        ),
        "original_has_cancel_command_call_without_output": (
            original_has_cancel_command_call_without_output(original_result)
        ),
        "chat_backend_has_command_call_without_output": (
            chat_package["journal_has_shell_function_call"]
            and chat_package["timeline_has_command_call"]
            and not chat_package["timeline_has_command_output"]
            and not chat_package["journal_has_function_call_output"]
        ),
        "chat_backend_did_not_persist_declined_command_stdout": not chat_package[
            "timeline_or_journal_contains_decline_command_output"
        ],
        "original_final_line_counts": original_lines,
        "chat_backend_final_line_counts": chat_lines,
        "final_durable_line_counts_equal": original_lines == chat_lines and bool(original_lines),
        "original": {
            "approval_tui": original_result["approval_tui"],
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "final_line_counts": original_lines,
        },
        "chat_backend": {
            "approval_tui": chat_result["approval_tui"],
            "followup_exec": {
                "command": chat_followup["command"],
                "exit_code": chat_followup["exit_code"],
                "normalized_events": normalize_exec_events(chat_followup["events"]),
                "stderr_tail": chat_followup["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "final_line_counts": chat_lines,
            "chat_package_observation": chat_package,
        },
        "not_yet_proven": [
            "network/file-change/additional-permission approval variants through TUI",
            "ordinary CLI/TUI Decline path if exposed by another approval surface",
            "approval process-kill or crash recovery",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_approval"],
            summary["chat_backend_tui_reached_approval"],
            summary["original_tui_sent_cancel"],
            summary["chat_backend_tui_sent_cancel"],
            not summary["original_tui_final_visible"],
            not summary["chat_backend_tui_final_visible"],
            summary["original_tui_cancel_message_visible"],
            summary["chat_backend_tui_cancel_message_visible"],
            summary["original_tui_no_output_visible"],
            summary["chat_backend_tui_no_output_visible"],
            summary["original_tui_interrupted_visible"],
            summary["chat_backend_tui_interrupted_visible"],
            summary["tui_response_request_counts_equal_after_cancel"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["followup_context_preserved_after_cancel"],
            summary["original_has_cancel_command_call_without_output"],
            summary["chat_backend_has_command_call_without_output"],
            summary["chat_backend_did_not_persist_declined_command_stdout"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI command approval Cancel "
        "slice: both backends show the approval path, reject the shell command "
        "through the TUI cancel shortcut, abort the current turn without a final "
        "assistant answer, preserve the canceled command call without fabricating "
        "a command output, preserve follow-up resume behavior, and keep durable "
        "original rollout line counts equal to `.chat` journal line counts. It "
        "is not full command approval parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(
        output_dir / "original/cli-command-approval-cancel-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/cli-command-approval-cancel-response.json",
        chat_result,
    )

    if not passed:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
