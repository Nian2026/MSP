#!/usr/bin/env python3
"""Run real CLI/TUI command approval session-cache parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a shell_command approval
    press the TUI shortcut for "yes, and do not ask again this session"
    type a second prompt that triggers the same command
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

from app_server_command_approval_cache_smoke import (  # noqa: E402
    CALL_ID_1,
    CALL_ID_2,
    COMMAND,
    FINAL_TEXT_1,
    FINAL_TEXT_2,
    STDOUT_MARKER,
    USER_TEXT_1,
    USER_TEXT_2,
    ApprovalCacheResponsesServer,
    summarize_cache_chat_timeline,
    summarize_cache_original_rollouts,
)
from app_server_command_approval_smoke import (  # noqa: E402
    ev_final_message,
    write_approval_config,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
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


FOLLOWUP_USER_TEXT = "CLI approval cache follow-up after session approval."
FOLLOWUP_ASSISTANT_TEXT = "CLI approval cache follow-up answer from mock model."
APPROVAL_IDLE_SECONDS = 1.8

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_approval_cache_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/shell.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/tests/approval_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class ApprovalCacheTuiResponsesServer(ApprovalCacheResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses.append(
            ev_final_message(
                "resp-cli-approval-cache-followup",
                "msg-cli-approval-cache-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            )
        )


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    fourth_body = bodies[3] if len(bodies) > 3 else {}
    fifth_body = bodies[4] if len(bodies) > 4 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_first_user_text": body_contains(first_body, USER_TEXT_1),
        "second_body_contains_first_call_output": (
            serialized_contains(second_body, CALL_ID_1)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_stdout": serialized_contains(second_body, STDOUT_MARKER),
        "third_body_contains_second_user_text": body_contains(third_body, USER_TEXT_2),
        "third_body_contains_first_final_text": body_contains(third_body, FINAL_TEXT_1),
        "fourth_body_contains_second_call_output": (
            serialized_contains(fourth_body, CALL_ID_2)
            and serialized_contains(fourth_body, "function_call_output")
        ),
        "fourth_body_contains_stdout": serialized_contains(fourth_body, STDOUT_MARKER),
        "fifth_body_contains_first_user_text": body_contains(fifth_body, USER_TEXT_1),
        "fifth_body_contains_second_user_text": body_contains(fifth_body, USER_TEXT_2),
        "fifth_body_contains_first_final_text": body_contains(fifth_body, FINAL_TEXT_1),
        "fifth_body_contains_second_final_text": body_contains(fifth_body, FINAL_TEXT_2),
        "fifth_body_contains_followup_user_text": body_contains(fifth_body, FOLLOWUP_USER_TEXT),
        "fifth_body_contains_stdout": serialized_contains(fifth_body, STDOUT_MARKER),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_approval_cache_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: ApprovalCacheTuiResponsesServer,
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
    sent_first_prompt = False
    first_prompt_sent_at: float | None = None
    first_prompt_enter_retry_sent = False
    first_approval_visible_at: float | None = None
    sent_session_accept = False
    first_final_visible_at: float | None = None
    sent_second_prompt = False
    second_prompt_sent_at: float | None = None
    second_prompt_enter_retry_sent = False
    second_final_visible_at: float | None = None
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

            decoded_output = output.decode(errors="replace")
            visible_tail = decoded_output[-2600:]
            stripped_tail = strip_ansi(visible_tail)
            compact_tail = re.sub(r"\s+", "", stripped_tail)
            request_count = response_request_count(mock_server.requests)

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
            if ready_for_prompt and not sent_first_prompt:
                type_prompt_and_enter(master, USER_TEXT_1)
                sent_first_prompt = True
                first_prompt_sent_at = time.time()

            if (
                sent_first_prompt
                and request_count < 1
                and first_prompt_sent_at is not None
                and time.time() - first_prompt_sent_at > 2.0
                and not first_prompt_enter_retry_sent
            ):
                os.write(master, b"\r")
                first_prompt_enter_retry_sent = True

            first_approval_visible = (
                "Wouldyouliketorunthefollowingcommand?" in compact_tail
                and STDOUT_MARKER in compact_tail
            )
            if first_approval_visible and first_approval_visible_at is None:
                first_approval_visible_at = time.time()

            if (
                first_approval_visible_at is not None
                and not sent_session_accept
                and time.time() - first_approval_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"p")
                sent_session_accept = True

            if FINAL_TEXT_1 in decoded_output and first_final_visible_at is None:
                first_final_visible_at = time.time()

            if (
                first_final_visible_at is not None
                and time.time() - first_final_visible_at > 1.0
                and not sent_second_prompt
            ):
                type_prompt_and_enter(master, USER_TEXT_2)
                sent_second_prompt = True
                second_prompt_sent_at = time.time()

            if (
                sent_second_prompt
                and request_count < 3
                and second_prompt_sent_at is not None
                and time.time() - second_prompt_sent_at > 2.0
                and not second_prompt_enter_retry_sent
            ):
                os.write(master, b"\r")
                second_prompt_enter_retry_sent = True

            if FINAL_TEXT_2 in decoded_output and second_final_visible_at is None:
                second_final_visible_at = time.time()

            if (
                second_final_visible_at is not None
                and time.time() - second_final_visible_at > 1.5
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
        "sent_first_prompt": sent_first_prompt,
        "first_prompt_enter_retry_sent": first_prompt_enter_retry_sent,
        "first_approval_prompt_visible": first_approval_visible_at is not None,
        "sent_session_accept": sent_session_accept,
        "first_final_visible": first_final_visible_at is not None,
        "sent_second_prompt": sent_second_prompt,
        "second_prompt_enter_retry_sent": second_prompt_enter_retry_sent,
        "second_final_visible": second_final_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-3500:],
        "raw_output_bytes": len(output),
    }


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    timeline = summarize_cache_chat_timeline(chat_root)
    summary = summarize_chat_packages(chat_root)
    return {
        "summary": summary,
        "timeline": timeline,
        "package_count": summary.get("package_count"),
        "timeline_command_call_count": sum(
            package.get("timeline_command_call_count") or 0
            for package in timeline.get("packages") or []
        ),
        "timeline_command_output_count": sum(
            package.get("timeline_command_output_count") or 0
            for package in timeline.get("packages") or []
        ),
        "journal_shell_function_call_count": sum(
            package.get("journal_shell_function_call_count") or 0
            for package in timeline.get("packages") or []
        ),
        "journal_function_call_output_count": sum(
            package.get("journal_function_call_output_count") or 0
            for package in timeline.get("packages") or []
        ),
        "journal_contains_first_call": any(
            package.get("journal_contains_first_call")
            for package in timeline.get("packages") or []
        ),
        "journal_contains_second_call": any(
            package.get("journal_contains_second_call")
            for package in timeline.get("packages") or []
        ),
    }


def original_rollout_observation(codex_home: pathlib.Path) -> dict[str, Any]:
    summary = summarize_cache_original_rollouts(codex_home)
    return {
        "summary": summary,
        "has_two_shell_calls": any(
            rollout.get("function_call_names", []).count("shell_command") >= 2
            for rollout in summary.get("rollouts") or []
        ),
        "has_first_call_output": any(
            CALL_ID_1 in (rollout.get("function_call_output_call_ids") or [])
            for rollout in summary.get("rollouts") or []
        ),
        "has_second_call_output": any(
            CALL_ID_2 in (rollout.get("function_call_output_call_ids") or [])
            for rollout in summary.get("rollouts") or []
        ),
        "contains_stdout": any(
            rollout.get("contains_stdout") for rollout in summary.get("rollouts") or []
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

    with ApprovalCacheTuiResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        approval_tui = run_cli_approval_cache_tui(
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
        result["original_rollout_observation"] = original_rollout_observation(codex_home)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-command-approval-cache-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_rollout = original_result["original_rollout_observation"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-command-approval-cache-smoke",
        "matrix_slice": ["T06-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_reached_first_approval": original_result["approval_tui"][
            "first_approval_prompt_visible"
        ],
        "chat_backend_tui_reached_first_approval": chat_result["approval_tui"][
            "first_approval_prompt_visible"
        ],
        "original_tui_sent_session_accept": original_result["approval_tui"][
            "sent_session_accept"
        ],
        "chat_backend_tui_sent_session_accept": chat_result["approval_tui"][
            "sent_session_accept"
        ],
        "original_tui_first_final_visible": original_result["approval_tui"][
            "first_final_visible"
        ],
        "chat_backend_tui_first_final_visible": chat_result["approval_tui"][
            "first_final_visible"
        ],
        "original_tui_second_final_visible": original_result["approval_tui"][
            "second_final_visible"
        ],
        "chat_backend_tui_second_final_visible": chat_result["approval_tui"][
            "second_final_visible"
        ],
        "tui_response_request_counts_equal_after_cache": (
            original_result["approval_tui"]["response_request_count_after_tui"]
            == chat_result["approval_tui"]["response_request_count_after_tui"]
            == 4
        ),
        "second_command_completed_without_second_approval_input": (
            original_result["approval_tui"]["sent_session_accept"]
            and chat_result["approval_tui"]["sent_session_accept"]
            and original_result["approval_tui"]["second_final_visible"]
            and chat_result["approval_tui"]["second_final_visible"]
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "mock_cache_outputs_round_trip": (
            original_mock["second_body_contains_first_call_output"]
            and chat_mock["second_body_contains_first_call_output"]
            and original_mock["second_body_contains_stdout"]
            and chat_mock["second_body_contains_stdout"]
            and original_mock["fourth_body_contains_second_call_output"]
            and chat_mock["fourth_body_contains_second_call_output"]
            and original_mock["fourth_body_contains_stdout"]
            and chat_mock["fourth_body_contains_stdout"]
        ),
        "followup_context_preserved_after_cache": (
            original_mock["fifth_body_contains_first_user_text"]
            and chat_mock["fifth_body_contains_first_user_text"]
            and original_mock["fifth_body_contains_second_user_text"]
            and chat_mock["fifth_body_contains_second_user_text"]
            and original_mock["fifth_body_contains_first_final_text"]
            and chat_mock["fifth_body_contains_first_final_text"]
            and original_mock["fifth_body_contains_second_final_text"]
            and chat_mock["fifth_body_contains_second_final_text"]
            and original_mock["fifth_body_contains_followup_user_text"]
            and chat_mock["fifth_body_contains_followup_user_text"]
            and original_mock["fifth_body_contains_stdout"]
            and chat_mock["fifth_body_contains_stdout"]
        ),
        "original_has_session_cache_persisted": (
            original_rollout["has_two_shell_calls"]
            and original_rollout["has_first_call_output"]
            and original_rollout["has_second_call_output"]
            and original_rollout["contains_stdout"]
        ),
        "chat_backend_has_two_command_timeline_pairs": (
            chat_package["timeline_command_call_count"] >= 2
            and chat_package["timeline_command_output_count"] >= 2
        ),
        "chat_backend_has_source_transport": (
            chat_package["journal_shell_function_call_count"] >= 2
            and chat_package["journal_function_call_output_count"] >= 2
            and chat_package["journal_contains_first_call"]
            and chat_package["journal_contains_second_call"]
        ),
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
            "CLI approval decline/cancel paths",
            "network/file-change/additional-permission approval variants through TUI",
            "approval process-kill or crash recovery",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_first_approval"],
            summary["chat_backend_tui_reached_first_approval"],
            summary["original_tui_sent_session_accept"],
            summary["chat_backend_tui_sent_session_accept"],
            summary["original_tui_first_final_visible"],
            summary["chat_backend_tui_first_final_visible"],
            summary["original_tui_second_final_visible"],
            summary["chat_backend_tui_second_final_visible"],
            summary["tui_response_request_counts_equal_after_cache"],
            summary["second_command_completed_without_second_approval_input"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_cache_outputs_round_trip"],
            summary["followup_context_preserved_after_cache"],
            summary["original_has_session_cache_persisted"],
            summary["chat_backend_has_two_command_timeline_pairs"],
            summary["chat_backend_has_source_transport"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI command approval "
        "AcceptForSession slice: both backends show the first approval path, "
        "accept the command for the session through the TUI shortcut, run a "
        "second same-command turn without additional approval input, preserve "
        "follow-up resume context, and keep durable original rollout line "
        "counts equal to `.chat` journal line counts. It is not full command "
        "approval parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/cli-command-approval-cache-response.json", original_result)
    write_json(output_dir / "chat-backend/cli-command-approval-cache-response.json", chat_result)

    if not passed:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
