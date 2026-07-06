#!/usr/bin/env python3
"""Run real CLI/TUI managed-network approval cancel parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that should trigger an exec_command managed-network approval
    press the visible TUI shortcut for "No, and tell Codex what to do differently"
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

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from app_server_network_approval_smoke import (  # noqa: E402
    NETWORK_COMMAND,
    NETWORK_HOST,
    NetworkApprovalResponsesServer,
    ev_completed,
    ev_response_created,
    sse,
    summarize_chat_network_package,
    summarize_original_rollouts,
    write_managed_network_requirements,
    write_network_config,
)
from cli_command_approval_smoke import durable_line_counts  # noqa: E402
from cli_exec_resume_smoke import (  # noqa: E402
    normalize_exec_events,
    response_request_bodies,
    run_cli_command,
)
from cli_network_approval_smoke import (  # noqa: E402
    NETWORK_APPROVAL_IDLE_SECONDS,
    temporary_macos_managed_requirements,
)
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


CALL_ID = "call-network-approval-cancel"
USER_TEXT = "Run the managed network approval cancel smoke."
FOLLOWUP_USER_TEXT = "CLI network approval cancel follow-up after canceled network request."
CANCEL_FINAL_TEXT = "CLI network approval cancel turn answer from mock model."
FOLLOWUP_ASSISTANT_TEXT = "CLI network approval cancel follow-up answer from mock model."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_network_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_cancel_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_network_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/app.rs",
        "lines": "305-335",
        "finding": "The default network approval TUI decisions are Accept, AcceptForSession, optional persistent Allow, and Cancel.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
        "lines": "857-926,1640-1675,1722-1755",
        "finding": "Network prompts label the default negative option as Cancel; a persistent Deny shortcut is only bound when a Deny network-policy amendment is present.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
        "lines": "156-174,189-192,250-320",
        "finding": "Network decisions distinguish allow-once/session from policy deny and user denial; denied outcomes must not be recorded as successful command output.",
    },
]


def ev_exec_command_call(response_id: str) -> bytes:
    arguments = json.dumps(
        {
            "cmd": NETWORK_COMMAND,
            "shell": "/bin/sh",
            "timeout_ms": 10000,
            "yield_time_ms": 1000,
            "max_output_tokens": 20000,
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
                    "call_id": CALL_ID,
                    "name": "exec_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message_text(response_id: str, message_id: str, text: str) -> bytes:
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


class CliNetworkApprovalCancelResponsesServer(NetworkApprovalResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_exec_command_call("resp-cli-network-approval-cancel-1"),
            ev_final_message_text(
                "resp-cli-network-approval-cancel-2",
                "msg-cli-network-approval-cancel-final",
                CANCEL_FINAL_TEXT,
            ),
            ev_final_message_text(
                "resp-cli-network-approval-cancel-3",
                "msg-cli-network-approval-cancel-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            index = len(
                [request for request in self.requests if request["path"].endswith("/responses")]
            )
        if 1 <= index <= len(self.responses):
            return self.responses[index - 1]
        return ev_final_message_text(
            f"resp-cli-network-approval-cancel-extra-{index}",
            f"msg-cli-network-approval-cancel-extra-{index}",
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
    third_body = bodies[2] if len(bodies) > 2 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "second_body_contains_original_user_text": body_contains(second_body, USER_TEXT),
        "second_body_contains_call_id": serialized_contains(second_body, CALL_ID),
        "second_body_contains_function_call_output": serialized_contains(
            second_body,
            "function_call_output",
        ),
        "second_body_contains_network_host": serialized_contains(second_body, NETWORK_HOST),
        "second_body_contains_rejection_text": (
            serialized_contains(second_body, "rejected by user")
            or serialized_contains(second_body, "Conversation interrupted")
            or serialized_contains(second_body, "canceled")
        ),
        "third_body_contains_followup_user_text": body_contains(
            third_body,
            FOLLOWUP_USER_TEXT,
        ),
        "third_body_contains_original_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_network_host": serialized_contains(third_body, NETWORK_HOST),
        "third_body_contains_cancel_final_text": body_contains(third_body, CANCEL_FINAL_TEXT),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_network_approval_cancel_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: CliNetworkApprovalCancelResponsesServer,
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

        winsize = struct.pack("HHHH", 32, 120, 0, 0)
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
    network_approval_visible_at: float | None = None
    sent_network_cancel = False
    final_answer_visible_at: float | None = None
    canceled_visible_at: float | None = None
    interrupted_visible_at: float | None = None
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
            visible_tail = decoded_output[-3600:]
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

            network_approval_visible = (
                "Doyouwanttoapprovenetworkaccessto" in compact_tail
                and NETWORK_HOST in compact_tail
            )
            if network_approval_visible and network_approval_visible_at is None:
                network_approval_visible_at = time.time()

            if (
                network_approval_visible_at is not None
                and not sent_network_cancel
                and time.time() - network_approval_visible_at >= NETWORK_APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"\x1b")
                sent_network_cancel = True

            if CANCEL_FINAL_TEXT in decoded_output and final_answer_visible_at is None:
                final_answer_visible_at = time.time()

            if (
                "You canceled the request" in decoded_output
                or "rejected by user" in decoded_output
                or "not_allowed" in decoded_output
            ) and canceled_visible_at is None:
                canceled_visible_at = time.time()

            if "Conversation interrupted" in decoded_output and interrupted_visible_at is None:
                interrupted_visible_at = time.time()

            if (
                sent_network_cancel
                and (
                    interrupted_visible_at is not None
                    or canceled_visible_at is not None
                    or time.time() - network_approval_visible_at > 4.0
                )
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
        "network_approval_prompt_visible": network_approval_visible_at is not None,
        "sent_network_cancel": sent_network_cancel,
        "final_answer_visible": final_answer_visible_at is not None,
        "canceled_visible": canceled_visible_at is not None
        or "You canceled the request" in stripped_output
        or "rejected by user" in stripped_output
        or "not_allowed" in stripped_output,
        "interrupted_visible": interrupted_visible_at is not None
        or "Conversation interrupted" in stripped_output,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-3600:],
        "raw_output_bytes": len(output),
    }


def original_has_network_persisted(result: dict[str, Any]) -> bool:
    rollouts = result["original_network_rollout_summary"].get("rollouts") or []
    return any(
        rollout.get("contains_network_host")
        and rollout.get("contains_exec_function_call")
        and rollout.get("contains_function_call_output")
        for rollout in rollouts
    )


def chat_backend_has_network_timeline(result: dict[str, Any]) -> bool:
    packages = result["chat_network_summary"].get("packages") or []
    return any(
        package.get("timeline_has_command_call")
        and package.get("timeline_has_command_output")
        and package.get("journal_contains_network_host")
        and package.get("journal_contains_exec_function_call")
        and package.get("journal_contains_function_call_output")
        for package in packages
    )


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    managed_dir = run_root / tree_name / "managed"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with CliNetworkApprovalCancelResponsesServer() as mock_server:
        write_network_config(codex_home, mock_server.url)
        managed_config_path = write_managed_network_requirements(managed_dir)
        managed_requirements_path = managed_config_path.with_name("requirements.toml")
        with temporary_macos_managed_requirements(managed_requirements_path) as managed_preferences:
            network_tui = run_cli_network_approval_cancel_tui(
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
        managed_preferences_summary = dict(managed_preferences)

    result: dict[str, Any] = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "managed_config_path": str(managed_config_path),
        "managed_requirements_path": str(managed_requirements_path),
        "managed_preferences_override": managed_preferences_summary,
        "network_tui": network_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["chat_network_summary"] = summarize_chat_network_package(chat_root)
    else:
        result["original_network_rollout_summary"] = summarize_original_rollouts(codex_home)
    return result


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Network Approval Cancel Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow CLI/TUI managed-network approval cancel smoke. It",
        "drives the real interactive Codex CLI in both vendored trees, reaches",
        "the visible network approval prompt, chooses the default visible",
        "negative option, and then resumes through `codex exec --json`.",
        "",
        "This covers the default `Cancel` negative path for a network prompt. It",
        "does not prove a persistent host block, because the pinned TUI source",
        "only binds a persistent deny shortcut when a deny network-policy",
        "amendment is offered.",
        "",
        "In this pinned TUI behavior, the negative network decision is returned",
        "to the model as a command result; it is not a turn-abort shape with no",
        "function output.",
        "",
        "## Result",
        "",
        f"- passed: `{summary['passed']}`",
        f"- original managed preferences applied/restored: `{summary['original_managed_preferences_applied']}` / `{summary['original_managed_preferences_restored']}`",
        f"- `.chat` managed preferences applied/restored: `{summary['chat_backend_managed_preferences_applied']}` / `{summary['chat_backend_managed_preferences_restored']}`",
        f"- original TUI reached network approval: `{summary['original_tui_reached_network_approval']}`",
        f"- `.chat` TUI reached network approval: `{summary['chat_backend_tui_reached_network_approval']}`",
        f"- original TUI sent cancel: `{summary['original_tui_sent_network_cancel']}`",
        f"- `.chat` TUI sent cancel: `{summary['chat_backend_tui_sent_network_cancel']}`",
        f"- normalized follow-up CLI output equal: `{summary['normalized_followup_exec_equal']}`",
        f"- mock request summaries equal: `{summary['mock_request_summaries_equal']}`",
        f"- durable line counts equal: `{summary['final_durable_line_counts_equal']}`",
        f"- `.chat` package has network timeline/source transport: `{summary['chat_backend_has_network_timeline']}`",
        "",
        "## Evidence Boundary",
        "",
        "- `summary.json`",
        "- source-backed finding: default network prompt exposes Cancel, not",
        "  persistent Deny, unless a Deny amendment is explicitly offered.",
        "",
    ]
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-network-approval-cancel-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-network-approval-cancel-smoke",
        "matrix_slice": ["T06-network-cli-negative-path-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "binary_checks": binary_checks,
        "original_managed_preferences_applied": original_result[
            "managed_preferences_override"
        ].get("applied"),
        "chat_backend_managed_preferences_applied": chat_result[
            "managed_preferences_override"
        ].get("applied"),
        "original_managed_preferences_restored": original_result[
            "managed_preferences_override"
        ].get("restored"),
        "chat_backend_managed_preferences_restored": chat_result[
            "managed_preferences_override"
        ].get("restored"),
        "original_tui_reached_network_approval": original_result["network_tui"][
            "network_approval_prompt_visible"
        ],
        "chat_backend_tui_reached_network_approval": chat_result["network_tui"][
            "network_approval_prompt_visible"
        ],
        "original_tui_sent_network_cancel": original_result["network_tui"][
            "sent_network_cancel"
        ],
        "chat_backend_tui_sent_network_cancel": chat_result["network_tui"][
            "sent_network_cancel"
        ],
        "original_tui_cancel_visible": original_result["network_tui"]["canceled_visible"],
        "chat_backend_tui_cancel_visible": chat_result["network_tui"][
            "canceled_visible"
        ],
        "original_tui_interrupted_visible": original_result["network_tui"][
            "interrupted_visible"
        ],
        "chat_backend_tui_interrupted_visible": chat_result["network_tui"][
            "interrupted_visible"
        ],
        "original_tui_final_visible": original_result["network_tui"]["final_answer_visible"],
        "chat_backend_tui_final_visible": chat_result["network_tui"]["final_answer_visible"],
        "tui_response_request_counts_equal_after_cancel": (
            original_result["network_tui"]["response_request_count_after_tui"]
            == chat_result["network_tui"]["response_request_count_after_tui"]
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
        "followup_context_preserved_after_cancel": (
            original_mock["third_body_contains_original_user_text"]
            and chat_mock["third_body_contains_original_user_text"]
            and original_mock["third_body_contains_followup_user_text"]
            and chat_mock["third_body_contains_followup_user_text"]
            and original_mock["third_body_contains_network_host"]
            and chat_mock["third_body_contains_network_host"]
            and original_mock["third_body_contains_cancel_final_text"]
            and chat_mock["third_body_contains_cancel_final_text"]
        ),
        "cancel_function_output_round_trip": (
            original_mock["second_body_contains_call_id"]
            and chat_mock["second_body_contains_call_id"]
            and original_mock["second_body_contains_function_call_output"]
            and chat_mock["second_body_contains_function_call_output"]
            and original_mock["second_body_contains_network_host"]
            and chat_mock["second_body_contains_network_host"]
        ),
        "original_has_network_persisted": (
            original_has_network_persisted(original_result)
        ),
        "chat_backend_has_network_timeline": (
            chat_backend_has_network_timeline(chat_result)
        ),
        "original_final_line_counts": original_lines,
        "chat_backend_final_line_counts": chat_lines,
        "final_durable_line_counts_equal": original_lines == chat_lines and bool(original_lines),
        "original": {
            "network_tui": original_result["network_tui"],
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "managed_preferences_override": original_result["managed_preferences_override"],
            "final_line_counts": original_lines,
            "original_network_rollout_summary": original_result[
                "original_network_rollout_summary"
            ],
        },
        "chat_backend": {
            "network_tui": chat_result["network_tui"],
            "followup_exec": {
                "command": chat_followup["command"],
                "exit_code": chat_followup["exit_code"],
                "normalized_events": normalize_exec_events(chat_followup["events"]),
                "stderr_tail": chat_followup["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "managed_preferences_override": chat_result["managed_preferences_override"],
            "final_line_counts": chat_lines,
            "chat_network_summary": chat_result["chat_network_summary"],
        },
        "not_yet_proven": [
            "CLI network persistent allow and persistent block decisions",
            "CLI network cross-turn/new-environment AcceptForSession behavior",
            "CLI additional-permission approval variants",
            "approval process-kill or crash recovery",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    summary["passed"] = all(
        [
            summary["original_tui_reached_network_approval"],
            summary["chat_backend_tui_reached_network_approval"],
            summary["original_tui_sent_network_cancel"],
            summary["chat_backend_tui_sent_network_cancel"],
            summary["original_managed_preferences_applied"],
            summary["chat_backend_managed_preferences_applied"],
            summary["original_managed_preferences_restored"],
            summary["chat_backend_managed_preferences_restored"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_cancel"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["followup_context_preserved_after_cancel"],
            summary["cancel_function_output_round_trip"],
            summary["original_has_network_persisted"],
            summary["chat_backend_has_network_timeline"],
            summary["final_durable_line_counts_equal"],
        ]
    )

    write_json(output_dir / "summary.json", summary)
    write_report(output_dir, summary)

    if not summary["passed"]:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
