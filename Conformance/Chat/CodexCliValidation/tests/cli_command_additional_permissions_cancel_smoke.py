#!/usr/bin/env python3
"""Run real CLI/TUI command additional-permissions cancel parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a shell_command with additional permissions
    choose the TUI "No" / cancel path
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
import shlex
import struct
import subprocess
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_command_additional_permissions_smoke import (  # noqa: E402
    CALL_ID,
    FIXTURE_MARKER,
    FIXTURE_NAME,
    USER_TEXT,
    AdditionalPermissionsResponsesServer,
    ev_final_message,
    ev_shell_command_call,
    summarize_chat_timeline,
    summarize_original_rollouts,
    write_additional_permissions_config,
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


FOLLOWUP_USER_TEXT = "CLI additional permissions cancel follow-up after rejected command."
FOLLOWUP_ASSISTANT_TEXT = "CLI additional permissions cancel follow-up answer from mock model."
CANCEL_IDLE_SECONDS = 1.8

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_additional_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_additional_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_cancel_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/unified_exec.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/shell.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/approval_events.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/approval_events.rs",
        "lines": "69-95",
        "finding": "Default exec approval decisions for additional_permissions are Accept and Cancel only.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
        "lines": "2112-2188",
        "finding": "request_command_approval computes available decisions from the default helper when shell runtimes pass None.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/unified_exec.rs",
        "lines": "214-229",
        "finding": "The normal unified exec shell-command path passes available_decisions = None.",
    },
]


class AdditionalPermissionsCancelResponsesServer(AdditionalPermissionsResponsesServer):
    def __init__(self, command: str, fixture_path: pathlib.Path) -> None:
        super().__init__(command, fixture_path)
        self.responses = [
            ev_shell_command_call(
                "resp-cli-additional-permissions-cancel-call",
                CALL_ID,
                command,
                fixture_path,
            ),
            ev_final_message(
                "resp-cli-additional-permissions-cancel-followup",
                "msg-cli-additional-permissions-cancel-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def summarize_mock_requests(
    requests: list[dict[str, Any]],
    fixture_path: pathlib.Path,
) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "first_body_contains_additional_permissions": serialized_contains(
            first_body,
            "additional_permissions",
        ),
        "first_body_contains_with_additional_permissions": serialized_contains(
            first_body,
            "with_additional_permissions",
        ),
        "first_body_contains_fixture_name": serialized_contains(first_body, FIXTURE_NAME),
        "first_body_contains_fixture_path": serialized_contains(first_body, str(fixture_path)),
        "second_body_contains_followup_user_text": body_contains(
            second_body,
            FOLLOWUP_USER_TEXT,
        ),
        "second_body_contains_original_user_text": body_contains(second_body, USER_TEXT),
        "second_body_contains_function_output": (
            serialized_contains(second_body, CALL_ID)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_fixture_marker": serialized_contains(
            second_body,
            FIXTURE_MARKER,
        ),
        "second_body_contains_interrupted": serialized_contains(
            second_body,
            "Conversation interrupted",
        ),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_additional_permissions_cancel_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: AdditionalPermissionsCancelResponsesServer,
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

        winsize = struct.pack("HHHH", 30, 120, 0, 0)
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
    permission_prompt_visible_at: float | None = None
    sent_cancel = False
    cancel_message_visible_at: float | None = None
    no_output_visible_at: float | None = None
    interrupted_visible_at: float | None = None
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 85:
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
            visible_tail = decoded_output[-3200:]
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

            permission_prompt_visible = (
                "Wouldyouliketorunthefollowingcommand?" in compact_tail
                and (
                    "Permissionrule:" in stripped_tail
                    or "Permissionrule" in compact_tail
                    or FIXTURE_NAME in stripped_tail
                )
            )
            if permission_prompt_visible and permission_prompt_visible_at is None:
                permission_prompt_visible_at = time.time()

            if (
                permission_prompt_visible_at is not None
                and not sent_cancel
                and time.time() - permission_prompt_visible_at >= CANCEL_IDLE_SECONDS
            ):
                os.write(master, b"n")
                sent_cancel = True

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
        "permission_prompt_visible": permission_prompt_visible_at is not None,
        "sent_cancel": sent_cancel,
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
        "output_tail_stripped": stripped_output[-3600:],
        "raw_output_bytes": len(output),
    }


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    timeline = summarize_chat_timeline(chat_root)
    summary = summarize_chat_packages(chat_root)
    serialized = json.dumps(timeline, ensure_ascii=False)
    packages = timeline.get("packages") or []
    return {
        "summary": summary,
        "timeline": timeline,
        "package_count": summary.get("package_count"),
        "timeline_has_command_call": any(
            package.get("timeline_has_command_call") for package in packages
        ),
        "timeline_has_command_output": any(
            package.get("timeline_has_command_output") for package in packages
        ),
        "journal_has_shell_function_call": any(
            package.get("journal_has_shell_function_call") for package in packages
        ),
        "journal_has_function_call_output": any(
            package.get("journal_has_function_call_output") for package in packages
        ),
        "journal_contains_additional_permissions": any(
            package.get("journal_contains_additional_permissions") for package in packages
        ),
        "journal_contains_with_additional_permissions": any(
            package.get("journal_contains_with_additional_permissions") for package in packages
        ),
        "timeline_or_journal_contains_fixture_marker": FIXTURE_MARKER in serialized,
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    fixture_path: pathlib.Path,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    shell_command = f"cat {shlex.quote(str(fixture_path))}"

    with AdditionalPermissionsCancelResponsesServer(shell_command, fixture_path) as mock_server:
        write_additional_permissions_config(codex_home, mock_server.url)
        approval_tui = run_cli_additional_permissions_cancel_tui(
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
        "fixture_path": str(fixture_path),
        "shell_command": shell_command,
        "approval_tui": approval_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests, fixture_path),
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


def original_has_additional_permissions_call_without_output(result: dict[str, Any]) -> bool:
    rollouts = result["original_rollout_summary"].get("rollouts") or []
    return (
        any(
            "shell_command" in rollout.get("function_call_names", [])
            and rollout.get("contains_additional_permissions")
            and rollout.get("contains_with_additional_permissions")
            for rollout in rollouts
        )
        and not any(rollout.get("function_call_output_call_ids") for rollout in rollouts)
        and not any(rollout.get("contains_fixture_marker") for rollout in rollouts)
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-command-additional-permissions-cancel-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    fixture_dir = output_dir / "fixtures"
    fixture_dir.mkdir(parents=True)
    fixture_path = fixture_dir / FIXTURE_NAME
    fixture_path.write_text(FIXTURE_MARKER + "\n")

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

    run_root = output_dir / "run"
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [], fixture_path)
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
        fixture_path,
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
        "scope": "cli-command-additional-permissions-cancel-smoke",
        "matrix_slice": ["T06-additional-permissions-cancel-TUI", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "fixture_path": str(fixture_path),
        "binary_checks": binary_checks,
        "original_tui_reached_permission_prompt": original_result["approval_tui"][
            "permission_prompt_visible"
        ],
        "chat_backend_tui_reached_permission_prompt": chat_result["approval_tui"][
            "permission_prompt_visible"
        ],
        "original_tui_sent_cancel": original_result["approval_tui"]["sent_cancel"],
        "chat_backend_tui_sent_cancel": chat_result["approval_tui"]["sent_cancel"],
        "original_tui_cancel_message_visible": original_result["approval_tui"][
            "cancel_message_visible"
        ],
        "chat_backend_tui_cancel_message_visible": chat_result["approval_tui"][
            "cancel_message_visible"
        ],
        "original_tui_no_output_visible": original_result["approval_tui"][
            "no_output_visible"
        ],
        "chat_backend_tui_no_output_visible": chat_result["approval_tui"][
            "no_output_visible"
        ],
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
        "mock_additional_permissions_arguments_sent": (
            original_mock["first_body_contains_additional_permissions"]
            and chat_mock["first_body_contains_additional_permissions"]
            and original_mock["first_body_contains_with_additional_permissions"]
            and chat_mock["first_body_contains_with_additional_permissions"]
        ),
        "mock_rejection_output_round_trip_after_cancel": (
            original_mock["second_body_contains_function_output"]
            and chat_mock["second_body_contains_function_output"]
        ),
        "mock_no_fixture_marker_after_cancel": (
            not original_mock["second_body_contains_fixture_marker"]
            and not chat_mock["second_body_contains_fixture_marker"]
        ),
        "followup_context_preserved_after_cancel": (
            original_mock["second_body_contains_original_user_text"]
            and chat_mock["second_body_contains_original_user_text"]
            and original_mock["second_body_contains_followup_user_text"]
            and chat_mock["second_body_contains_followup_user_text"]
        ),
        "original_has_additional_permissions_call_without_output": (
            original_has_additional_permissions_call_without_output(original_result)
        ),
        "chat_backend_has_command_call_without_output": (
            chat_package["journal_has_shell_function_call"]
            and chat_package["timeline_has_command_call"]
            and not chat_package["timeline_has_command_output"]
            and not chat_package["journal_has_function_call_output"]
        ),
        "chat_backend_has_additional_permissions_source_transport": (
            chat_package["journal_contains_additional_permissions"]
            and chat_package["journal_contains_with_additional_permissions"]
        ),
        "chat_backend_did_not_persist_declined_command_stdout": not chat_package[
            "timeline_or_journal_contains_fixture_marker"
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
            "request_permissions approval crash recovery",
            "network approval cross-turn/new-environment AcceptForSession",
            "persistent network allow/block",
            "approval process-kill or crash recovery",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_permission_prompt"],
            summary["chat_backend_tui_reached_permission_prompt"],
            summary["original_tui_sent_cancel"],
            summary["chat_backend_tui_sent_cancel"],
            summary["original_tui_cancel_message_visible"],
            summary["chat_backend_tui_cancel_message_visible"],
            summary["original_tui_interrupted_visible"],
            summary["chat_backend_tui_interrupted_visible"],
            summary["tui_response_request_counts_equal_after_cancel"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_additional_permissions_arguments_sent"],
            summary["mock_rejection_output_round_trip_after_cancel"],
            summary["mock_no_fixture_marker_after_cancel"],
            summary["followup_context_preserved_after_cancel"],
            summary["original_has_additional_permissions_call_without_output"],
            summary["chat_backend_has_command_call_without_output"],
            summary["chat_backend_has_additional_permissions_source_transport"],
            summary["chat_backend_did_not_persist_declined_command_stdout"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI additional-permissions cancel "
        "slice: both backends show the real permissions prompt, take the visible "
        "cancel path, do not execute the command, feed the same rejection output "
        "back to the model, do not persist real command stdout, preserve follow-up resume "
        "context, and keep durable original rollout line counts equal to `.chat` "
        "journal line counts. Source inspection confirms normal shell_command "
        "additional-permissions approvals default to Accept/Cancel; session and "
        "strict grants belong to the separate request_permissions flow unless a "
        "non-default available_decisions transport is introduced."
    )

    write_json(
        output_dir / "original" / "cli-command-additional-permissions-cancel-response.json",
        original_result,
    )
    write_json(
        output_dir
        / "chat-backend"
        / "cli-command-additional-permissions-cancel-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# CLI Command Additional Permissions Cancel Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real Codex TUI and a local mock Responses API that returns a
`shell_command` with `sandbox_permissions = "with_additional_permissions"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
Codex additional-permissions TUI source files were read. The unmodified
original source tree was used only as the oracle.

## Scope

This smoke covers a narrow T06 user-visible slice: shell command approval with
inline additional filesystem read permission, where the user rejects/cancels the
approval in the TUI.

It verifies:

- both real TUIs show the additional-permissions command prompt;
- pressing the visible cancel/deny shortcut rejects the command;
- the fixture read does not run and fixture stdout is not persisted;
- both backends feed the same rejection `function_call_output` shape back to the
  follow-up model request;
- follow-up `codex exec --json resume --last` preserves the user-visible
  interrupted context equally;
- normalized follow-up CLI output matches;
- the `.chat` backend records the original shell source transport and neutral
  `command_call`, but does not fabricate `command_output` or persisted fixture
  stdout.

Source inspection also confirms that the normal shell-command
additional-permissions path defaults to Accept/Cancel. Session and strict grants
are separate request-permissions behavior unless a non-default
`available_decisions` transport is introduced.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-command-additional-permissions-cancel-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-command-additional-permissions-cancel-response.json
```

## Not Yet Proven

This smoke does not prove request-permissions approval crash recovery,
network cross-turn/new-environment `AcceptForSession`, persistent network
allow/block, approval process-kill recovery, complete T06 data fidelity, or
final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
