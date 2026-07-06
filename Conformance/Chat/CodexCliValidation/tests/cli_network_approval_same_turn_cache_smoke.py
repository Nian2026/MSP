#!/usr/bin/env python3
"""Run real CLI/TUI managed-network same-turn session-cache parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type one prompt that triggers two same-host exec_command calls in one turn
    press the TUI shortcut for "Yes, and allow this host for this conversation"
    verify the second same-turn command does not show another network prompt
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
    NETWORK_HOST,
    NetworkApprovalResponsesServer,
    write_managed_network_requirements,
    write_network_config,
)
from cli_command_approval_smoke import durable_line_counts  # noqa: E402
from cli_exec_resume_smoke import (  # noqa: E402
    normalize_exec_events,
    response_request_bodies,
    run_cli_command,
)
from cli_network_approval_cache_smoke import (  # noqa: E402
    CALL_ID_1,
    CALL_ID_2,
    NETWORK_APPROVAL_IDLE_SECONDS,
    SOURCE_FINDINGS,
    ev_exec_command_call,
    ev_final_message_text,
    serialized_contains,
    summarize_chat_network_cache,
    summarize_original_network_cache,
)
from cli_network_approval_smoke import temporary_macos_managed_requirements  # noqa: E402
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


USER_TEXT = "Run two same-turn managed network session approval commands."
FINAL_TEXT = "Same-turn network session approval answer from mock model."
FOLLOWUP_USER_TEXT = "CLI same-turn network approval cache follow-up."
FOLLOWUP_ASSISTANT_TEXT = "CLI same-turn network approval cache follow-up answer."

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
    "Conformance/Chat/CodexCliValidation/tests/cli_network_approval_cache_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_network_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_network_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/unified_exec.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/handlers/shell/shell_command.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SAME_TURN_SOURCE_FINDINGS = [
    *SOURCE_FINDINGS,
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/unified_exec.rs",
        "lines": "326-338,536-550",
        "finding": "Managed network proxy preparation and approval keys use the turn environment id; a same-turn multi-command flow is a better cache-bypass shape than a second user turn.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/handlers/shell/shell_command.rs",
        "lines": "112-117",
        "finding": "exec_command passes the selected turn environment id into the network-enabled execution params.",
    },
]


class SameTurnNetworkCacheResponsesServer(NetworkApprovalResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_exec_command_call("resp-cli-network-same-turn-cache-1", CALL_ID_1),
            ev_exec_command_call("resp-cli-network-same-turn-cache-2", CALL_ID_2),
            ev_final_message_text(
                "resp-cli-network-same-turn-cache-3",
                "msg-cli-network-same-turn-cache-final",
                FINAL_TEXT,
            ),
            ev_final_message_text(
                "resp-cli-network-same-turn-cache-4",
                "msg-cli-network-same-turn-cache-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_same_turn_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    fourth_body = bodies[3] if len(bodies) > 3 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "second_body_contains_first_call_output": (
            serialized_contains(second_body, CALL_ID_1)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_network_host": serialized_contains(second_body, NETWORK_HOST),
        "third_body_contains_second_call_output": (
            serialized_contains(third_body, CALL_ID_2)
            and serialized_contains(third_body, "function_call_output")
        ),
        "third_body_contains_network_host": serialized_contains(third_body, NETWORK_HOST),
        "fourth_body_contains_user_text": body_contains(fourth_body, USER_TEXT),
        "fourth_body_contains_final_text": body_contains(fourth_body, FINAL_TEXT),
        "fourth_body_contains_followup_user_text": body_contains(
            fourth_body, FOLLOWUP_USER_TEXT
        ),
        "fourth_body_contains_network_host": serialized_contains(fourth_body, NETWORK_HOST),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_same_turn_network_cache_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SameTurnNetworkCacheResponsesServer,
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
    sent_user_prompt = False
    user_prompt_sent_at: float | None = None
    prompt_enter_retry_sent = False
    first_network_approval_visible_at: float | None = None
    sent_network_session_accept = False
    session_accept_keypress_count = 0
    second_call_output_offset: int | None = None
    second_network_approval_visible_at: float | None = None
    final_visible_at: float | None = None
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
            if ready_for_prompt and not sent_user_prompt:
                type_prompt_and_enter(master, USER_TEXT)
                sent_user_prompt = True
                user_prompt_sent_at = time.time()

            if (
                sent_user_prompt
                and request_count < 1
                and user_prompt_sent_at is not None
                and time.time() - user_prompt_sent_at > 2.0
                and not prompt_enter_retry_sent
            ):
                os.write(master, b"\r")
                prompt_enter_retry_sent = True

            first_network_approval_visible = (
                not sent_network_session_accept
                and "Doyouwanttoapprovenetworkaccessto" in compact_tail
                and NETWORK_HOST in compact_tail
            )
            if (
                first_network_approval_visible
                and first_network_approval_visible_at is None
            ):
                first_network_approval_visible_at = time.time()

            if (
                first_network_approval_visible_at is not None
                and not sent_network_session_accept
                and time.time() - first_network_approval_visible_at
                >= NETWORK_APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"a")
                sent_network_session_accept = True
                session_accept_keypress_count += 1

            if request_count >= 2 and second_call_output_offset is None:
                second_call_output_offset = len(output)

            if second_call_output_offset is not None:
                after_second_call = strip_ansi(
                    output[second_call_output_offset:].decode(errors="replace")
                )
                if (
                    "Do you want to approve network access to" in after_second_call
                    and NETWORK_HOST in after_second_call
                    and second_network_approval_visible_at is None
                ):
                    second_network_approval_visible_at = time.time()

            if FINAL_TEXT in decoded_output and final_visible_at is None:
                final_visible_at = time.time()

            if (
                second_network_approval_visible_at is not None
                and time.time() - second_network_approval_visible_at > 1.5
                and not sent_ctrl_c
            ):
                os.write(master, b"\x03")
                sent_ctrl_c = True

            if final_visible_at is not None and time.time() - final_visible_at > 1.5:
                if not sent_ctrl_c:
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
    after_second_call_text = ""
    if second_call_output_offset is not None:
        after_second_call_text = strip_ansi(
            output[second_call_output_offset:].decode(errors="replace")
        )
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_user_prompt": sent_user_prompt,
        "prompt_enter_retry_sent": prompt_enter_retry_sent,
        "first_network_approval_prompt_visible": first_network_approval_visible_at
        is not None,
        "sent_network_session_accept": sent_network_session_accept,
        "session_accept_keypress_count": session_accept_keypress_count,
        "second_call_model_request_seen": second_call_output_offset is not None,
        "second_network_approval_prompt_visible_after_second_call": (
            second_network_approval_visible_at is not None
        ),
        "final_visible": final_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_after_second_call_stripped_tail": after_second_call_text[-2200:],
        "output_tail_stripped": stripped_output[-4200:],
        "raw_output_bytes": len(output),
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
    managed_dir = run_root / tree_name / "managed"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with SameTurnNetworkCacheResponsesServer() as mock_server:
        write_network_config(codex_home, mock_server.url)
        managed_config_path = write_managed_network_requirements(managed_dir)
        managed_requirements_path = managed_config_path.with_name("requirements.toml")
        with temporary_macos_managed_requirements(
            managed_requirements_path
        ) as managed_preferences:
            approval_tui = run_cli_same_turn_network_cache_tui(
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
        "approval_tui": approval_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_same_turn_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["chat_network_cache_summary"] = summarize_chat_network_cache(chat_root)
    else:
        result["original_network_cache_summary"] = summarize_original_network_cache(
            codex_home
        )
    return result


def build_analysis(summary: dict[str, Any]) -> dict[str, Any]:
    if summary["passed"]:
        return {
            "classified_as": "passing-slice/managed-network-same-turn-accept-for-session",
            "evidence_status": "passing narrow parity evidence; not final parity claim",
            "interpretation": (
                "Both CLI runs reached the first managed-network approval prompt, "
                "accepted the host with the approve_for_session shortcut, completed "
                "a second same-host command in the same user turn without another "
                "approval prompt, preserved follow-up resume context, and retained "
                "`.chat` command timeline plus source transport. This proves only "
                "the same-turn session-allow slice."
            ),
        }
    return {
        "classified_as": "failed-diagnostic/network-same-turn-cache",
        "evidence_status": "negative diagnostic; not passing parity evidence",
        "interpretation": (
            "The run did not satisfy the same-turn managed-network "
            "AcceptForSession cache checks. Inspect second-prompt visibility, "
            "shortcut delivery, mock requests, source transport, and durable line "
            "counts before using this result as evidence."
        ),
    }


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    analysis = summary.get("network_same_turn_cache_analysis") or {}
    lines = [
        "# CLI Same-Turn Network Approval Cache Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow CLI/TUI managed-network approval same-turn cache smoke.",
        "It drives the real interactive Codex CLI in both vendored trees, sends",
        "one user prompt, has the mock model emit two same-host network",
        "`exec_command` calls in that same turn, accepts the first network prompt",
        "with the `approve_for_session` shortcut, and then resumes through",
        "`codex exec --json`.",
        "",
        "It does not prove cross-turn network cache behavior, persistent",
        "allow/block, cancel/block variants, additional-permission approval,",
        "crash recovery, or final user indistinguishability.",
        "",
        "## Result",
        "",
        f"- passed: `{summary['passed']}`",
        f"- original managed preferences applied/restored: `{summary['original_managed_preferences_applied']}` / `{summary['original_managed_preferences_restored']}`",
        f"- `.chat` managed preferences applied/restored: `{summary['chat_backend_managed_preferences_applied']}` / `{summary['chat_backend_managed_preferences_restored']}`",
        f"- original reached first network approval: `{summary['original_tui_reached_first_network_approval']}`",
        f"- `.chat` reached first network approval: `{summary['chat_backend_tui_reached_first_network_approval']}`",
        f"- original sent session allow once: `{summary['original_tui_sent_network_session_accept']}`",
        f"- `.chat` sent session allow once: `{summary['chat_backend_tui_sent_network_session_accept']}`",
        f"- original saw second approval prompt after second same-turn call: `{summary['original_tui_saw_second_network_approval_after_second_call']}`",
        f"- `.chat` saw second approval prompt after second same-turn call: `{summary['chat_backend_tui_saw_second_network_approval_after_second_call']}`",
        f"- second same-turn network command completed without second approval input: `{summary['second_network_command_completed_without_second_approval_input']}`",
        f"- normalized follow-up CLI output equal: `{summary['normalized_followup_exec_equal']}`",
        f"- mock request summaries equal: `{summary['mock_request_summaries_equal']}`",
        f"- durable line counts equal: `{summary['final_durable_line_counts_equal']}`",
        f"- `.chat` package has two network command timeline/source transport pairs: `{summary['chat_backend_has_two_network_timeline_pairs']}` / `{summary['chat_backend_has_source_transport_for_both_calls']}`",
        "",
        "## Evidence Analysis",
        "",
        f"- classification: `{analysis.get('classified_as', 'not-recorded')}`",
        f"- evidence status: `{analysis.get('evidence_status', 'not-recorded')}`",
        "",
        analysis.get("interpretation", "No analysis recorded."),
        "",
        "## Source Basis",
        "",
    ]
    for finding in SAME_TURN_SOURCE_FINDINGS:
        lines.append(
            f"- `{finding['file']}:{finding['lines']}`: {finding['finding']}"
        )
    lines.extend(
        [
            "",
            "## Evidence",
            "",
            "- `summary.json`",
            "- `original/cli-network-approval-same-turn-cache-response.json`",
            "- `chat-backend/cli-network-approval-same-turn-cache-response.json`",
            "",
        ]
    )
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-network-approval-same-turn-cache-smoke-"
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

    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_lines = original_result["final_line_counts"]
    chat_lines = chat_result["final_line_counts"]
    original_network = original_result["original_network_cache_summary"]
    chat_network = chat_result["chat_network_cache_summary"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-network-approval-same-turn-cache-smoke",
        "matrix_slice": ["T06-network-accept-for-session-same-turn", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SAME_TURN_SOURCE_FINDINGS,
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
        "original_tui_reached_first_network_approval": original_result["approval_tui"][
            "first_network_approval_prompt_visible"
        ],
        "chat_backend_tui_reached_first_network_approval": chat_result["approval_tui"][
            "first_network_approval_prompt_visible"
        ],
        "original_tui_sent_network_session_accept": original_result["approval_tui"][
            "sent_network_session_accept"
        ],
        "chat_backend_tui_sent_network_session_accept": chat_result["approval_tui"][
            "sent_network_session_accept"
        ],
        "original_tui_session_accept_keypress_count": original_result["approval_tui"][
            "session_accept_keypress_count"
        ],
        "chat_backend_tui_session_accept_keypress_count": chat_result["approval_tui"][
            "session_accept_keypress_count"
        ],
        "original_tui_final_visible": original_result["approval_tui"]["final_visible"],
        "chat_backend_tui_final_visible": chat_result["approval_tui"]["final_visible"],
        "original_tui_saw_second_network_approval_after_second_call": original_result[
            "approval_tui"
        ]["second_network_approval_prompt_visible_after_second_call"],
        "chat_backend_tui_saw_second_network_approval_after_second_call": chat_result[
            "approval_tui"
        ]["second_network_approval_prompt_visible_after_second_call"],
        "tui_response_request_counts_equal_after_same_turn_cache": (
            original_result["approval_tui"]["response_request_count_after_tui"]
            == chat_result["approval_tui"]["response_request_count_after_tui"]
            == 3
        ),
        "second_network_command_completed_without_second_approval_input": (
            original_result["approval_tui"]["session_accept_keypress_count"]
            == chat_result["approval_tui"]["session_accept_keypress_count"]
            == 1
            and not original_result["approval_tui"][
                "second_network_approval_prompt_visible_after_second_call"
            ]
            and not chat_result["approval_tui"][
                "second_network_approval_prompt_visible_after_second_call"
            ]
            and original_result["approval_tui"]["final_visible"]
            and chat_result["approval_tui"]["final_visible"]
            and original_result["approval_tui"]["response_request_count_after_tui"]
            == chat_result["approval_tui"]["response_request_count_after_tui"]
            == 3
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "mock_network_outputs_round_trip": (
            original_mock["second_body_contains_first_call_output"]
            and chat_mock["second_body_contains_first_call_output"]
            and original_mock["second_body_contains_network_host"]
            and chat_mock["second_body_contains_network_host"]
            and original_mock["third_body_contains_second_call_output"]
            and chat_mock["third_body_contains_second_call_output"]
            and original_mock["third_body_contains_network_host"]
            and chat_mock["third_body_contains_network_host"]
        ),
        "followup_context_preserved_after_network_cache": (
            original_mock["fourth_body_contains_user_text"]
            and chat_mock["fourth_body_contains_user_text"]
            and original_mock["fourth_body_contains_final_text"]
            and chat_mock["fourth_body_contains_final_text"]
            and original_mock["fourth_body_contains_followup_user_text"]
            and chat_mock["fourth_body_contains_followup_user_text"]
            and original_mock["fourth_body_contains_network_host"]
            and chat_mock["fourth_body_contains_network_host"]
        ),
        "original_has_two_network_calls_persisted": original_network[
            "has_two_network_calls"
        ],
        "chat_backend_has_two_network_timeline_pairs": chat_network[
            "has_two_command_timeline_pairs"
        ],
        "chat_backend_has_source_transport_for_both_calls": chat_network[
            "has_source_transport_for_both_calls"
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
            "managed_preferences_override": original_result[
                "managed_preferences_override"
            ],
            "final_line_counts": original_lines,
            "original_network_cache_summary": original_network,
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
            "managed_preferences_override": chat_result[
                "managed_preferences_override"
            ],
            "final_line_counts": chat_lines,
            "chat_network_cache_summary": chat_network,
        },
        "not_yet_proven": [
            "cross-turn CLI network approval AcceptForSession semantics",
            "CLI network approval persistent allow and persistent block decisions",
            "CLI network approval cancel/block variants",
            "CLI file-change and additional-permission approval variants",
            "approval process-kill or crash recovery",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_managed_preferences_applied"],
            summary["chat_backend_managed_preferences_applied"],
            summary["original_managed_preferences_restored"],
            summary["chat_backend_managed_preferences_restored"],
            summary["original_tui_reached_first_network_approval"],
            summary["chat_backend_tui_reached_first_network_approval"],
            summary["original_tui_sent_network_session_accept"],
            summary["chat_backend_tui_sent_network_session_accept"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_same_turn_cache"],
            summary["second_network_command_completed_without_second_approval_input"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_network_outputs_round_trip"],
            summary["followup_context_preserved_after_network_cache"],
            summary["original_has_two_network_calls_persisted"],
            summary["chat_backend_has_two_network_timeline_pairs"],
            summary["chat_backend_has_source_transport_for_both_calls"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["network_same_turn_cache_analysis"] = build_analysis(summary)
    if passed:
        summary["claim"] = (
            "This proves a narrow user-facing CLI/TUI managed-network "
            "same-turn AcceptForSession slice: both backends show the first "
            "network approval path, accept the host for the current conversation "
            "through the TUI approve_for_session shortcut, complete a second "
            "same-host network command in the same user turn without another "
            "approval prompt, preserve follow-up resume context, and keep "
            "durable original rollout line counts equal to `.chat` journal line "
            "counts. It is not full approval parity."
        )
    else:
        summary["claim"] = (
            "This is negative diagnostic evidence, not passing parity evidence. "
            "The same-turn managed-network AcceptForSession cache run did not "
            "satisfy all required checks."
        )

    write_json(output_dir / "summary.json", summary)
    original_dir = output_dir / "original"
    chat_dir = output_dir / "chat-backend"
    original_dir.mkdir()
    chat_dir.mkdir()
    write_json(
        original_dir / "cli-network-approval-same-turn-cache-response.json",
        original_result,
    )
    write_json(
        chat_dir / "cli-network-approval-same-turn-cache-response.json",
        chat_result,
    )
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
