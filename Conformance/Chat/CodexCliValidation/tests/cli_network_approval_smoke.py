#!/usr/bin/env python3
"""Run real CLI/TUI managed-network approval parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that should trigger an exec_command managed-network approval
    press the TUI shortcut for "Yes, just this once" if the prompt appears
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06 approval or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import base64
import contextlib
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
    CALL_ID,
    FINAL_TEXT,
    NETWORK_HOST,
    NetworkApprovalResponsesServer,
    ev_completed,
    ev_exec_command_call,
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
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


FOLLOWUP_USER_TEXT = "CLI network approval follow-up after accepted network request."
FOLLOWUP_ASSISTANT_TEXT = "CLI network approval follow-up answer from mock model."
NETWORK_APPROVAL_IDLE_SECONDS = 1.8
MANAGED_PREFS_DOMAIN = "com.openai.codex"
MANAGED_PREFS_REQUIREMENTS_KEY = "requirements_toml_base64"

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
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_network_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/config/src/state.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/config/src/loader/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/config/src/loader/layer_io.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/config/src/loader/macos.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/approval_events.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

FAILURE_SOURCE_EVIDENCE = [
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/main.rs",
        "lines": "58-62",
        "finding": "The real TUI entry point uses LoaderOverrides::default().",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/app-server/src/main.rs",
        "lines": "14-16,74-79,122-130",
        "finding": "CODEX_APP_SERVER_MANAGED_CONFIG_PATH is an app-server debug hook.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/session/session.rs",
        "lines": "940-982",
        "finding": "The network policy decider is installed only when managed network requirements are configured.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/orchestrator.rs",
        "lines": "301-308",
        "finding": "A denied sandbox result only becomes a network approval path when it has an ask-from-decider payload.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/network_policy_decision.rs",
        "lines": "26-31",
        "finding": "networkApprovalContext is not created for baseline policy deny payloads.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
        "lines": "180-185",
        "finding": "Network approval flow also requires a Managed permission profile.",
    },
]


def run_defaults_command(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["defaults", *args],
        check=check,
        capture_output=True,
        text=True,
    )


def read_macos_managed_preference(key: str) -> tuple[bool, str | None]:
    result = run_defaults_command(["read", MANAGED_PREFS_DOMAIN, key], check=False)
    if result.returncode == 0:
        return True, result.stdout.strip()
    missing_markers = [
        "does not exist",
        "does not exist in domain",
        "Domain",
    ]
    if any(marker in result.stderr for marker in missing_markers):
        return False, None
    raise RuntimeError(
        "failed to read macOS managed preference "
        f"{MANAGED_PREFS_DOMAIN}:{key}: {result.stderr.strip()}"
    )


@contextlib.contextmanager
def temporary_macos_managed_requirements(requirements_path: pathlib.Path) -> Any:
    """Inject managed requirements for the real macOS CLI, then restore them."""

    summary: dict[str, Any] = {
        "domain": MANAGED_PREFS_DOMAIN,
        "key": MANAGED_PREFS_REQUIREMENTS_KEY,
        "requirements_path": str(requirements_path),
        "platform": sys.platform,
        "applied": False,
        "previous_value_existed": None,
        "restored": False,
    }
    if sys.platform != "darwin":
        summary["skip_reason"] = "macOS CFPreferences are required for this CLI smoke"
        yield summary
        return

    previous_exists, previous_value = read_macos_managed_preference(
        MANAGED_PREFS_REQUIREMENTS_KEY
    )
    encoded = base64.b64encode(requirements_path.read_bytes()).decode()
    summary.update(
        {
            "applied": True,
            "previous_value_existed": previous_exists,
            "encoded_length": len(encoded),
        }
    )
    run_defaults_command(
        ["write", MANAGED_PREFS_DOMAIN, MANAGED_PREFS_REQUIREMENTS_KEY, "-string", encoded]
    )
    try:
        yield summary
    finally:
        if previous_exists and previous_value is not None:
            run_defaults_command(
                [
                    "write",
                    MANAGED_PREFS_DOMAIN,
                    MANAGED_PREFS_REQUIREMENTS_KEY,
                    "-string",
                    previous_value,
                ]
            )
        else:
            run_defaults_command(
                ["delete", MANAGED_PREFS_DOMAIN, MANAGED_PREFS_REQUIREMENTS_KEY],
                check=False,
            )
        summary["restored"] = True


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


class CliNetworkApprovalResponsesServer(NetworkApprovalResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_exec_command_call("resp-cli-network-approval-1"),
            ev_final_message_text(
                "resp-cli-network-approval-2",
                "msg-cli-network-approval-final",
                FINAL_TEXT,
            ),
            ev_final_message_text(
                "resp-cli-network-approval-3",
                "msg-cli-network-approval-followup",
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
            f"resp-cli-network-approval-extra-{index}",
            f"msg-cli-network-approval-extra-{index}",
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
        "first_body_contains_user_text": body_contains(first_body, "Run the managed network approval smoke."),
        "first_body_contains_network_host": serialized_contains(first_body, NETWORK_HOST),
        "second_body_contains_function_output": (
            serialized_contains(second_body, CALL_ID)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_network_host": serialized_contains(second_body, NETWORK_HOST),
        "second_body_contains_final_text": body_contains(second_body, FINAL_TEXT),
        "third_body_contains_followup_user_text": body_contains(third_body, FOLLOWUP_USER_TEXT),
        "third_body_contains_original_user_text": body_contains(
            third_body,
            "Run the managed network approval smoke.",
        ),
        "third_body_contains_network_host": serialized_contains(third_body, NETWORK_HOST),
        "third_body_contains_first_final_text": body_contains(third_body, FINAL_TEXT),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_network_approval_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: CliNetworkApprovalResponsesServer,
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
    sent_network_accept = False
    final_answer_visible_at: float | None = None
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 110:
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
                type_prompt_and_enter(master, "Run the managed network approval smoke.")
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
                and not sent_network_accept
                and time.time() - network_approval_visible_at >= NETWORK_APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"y")
                sent_network_accept = True

            if FINAL_TEXT in decoded_output and final_answer_visible_at is None:
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
        "sent_network_accept": sent_network_accept,
        "final_answer_visible": final_answer_visible_at is not None,
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


def observed_baseline_policy_deny(result: dict[str, Any]) -> bool:
    tail = result.get("network_tui", {}).get("output_tail_stripped", "")
    return (
        NETWORK_HOST in tail
        and "baseline_policy" in tail
        and '"decision":"deny"' in tail
    )


def build_network_approval_analysis(
    original_result: dict[str, Any],
    chat_result: dict[str, Any],
) -> dict[str, Any]:
    original_prompt = original_result["network_tui"]["network_approval_prompt_visible"]
    chat_prompt = chat_result["network_tui"]["network_approval_prompt_visible"]
    original_accept = original_result["network_tui"]["sent_network_accept"]
    chat_accept = chat_result["network_tui"]["sent_network_accept"]
    original_final = original_result["network_tui"]["final_answer_visible"]
    chat_final = chat_result["network_tui"]["final_answer_visible"]
    original_baseline_deny = observed_baseline_policy_deny(original_result)
    chat_baseline_deny = observed_baseline_policy_deny(chat_result)
    negative_diagnostic = (
        not original_prompt
        and not chat_prompt
        and original_baseline_deny
        and chat_baseline_deny
    )
    passing_slice = (
        original_prompt
        and chat_prompt
        and original_accept
        and chat_accept
        and original_final
        and chat_final
        and not original_baseline_deny
        and not chat_baseline_deny
    )
    if passing_slice:
        classified_as = "passing-slice/managed-network-one-time-accept"
        evidence_status = "passing narrow parity evidence; not final parity claim"
        interpretation = (
            "Both CLI runs reached the real TUI managed-network approval prompt, "
            "accepted the network request once through the visible shortcut, "
            "showed the final answer, and preserved follow-up resume context. "
            "This proves only the one-time accept path; session-wide, "
            "persistent allow, cancel/block, additional-permission, and crash "
            "variants remain open."
        )
    elif negative_diagnostic:
        classified_as = "failed-diagnostic/no-cli-managed-network-approval-prompt"
        evidence_status = "negative diagnostic; not passing parity evidence"
        interpretation = (
            "Both CLI runs completed without a TUI network approval prompt and "
            "instead surfaced a baseline_policy deny. The real TUI CLI requires "
            "managed network requirements via the normal config loader; if the "
            "temporary managed-preferences override was not applied, this run "
            "does not prove CLI network approval parity."
        )
    else:
        classified_as = "failed-diagnostic/unclassified"
        evidence_status = "negative diagnostic; not passing parity evidence"
        interpretation = (
            "The run did not satisfy the managed-network approval parity checks. "
            "Inspect the TUI prompt, acceptance, final answer, follow-up context, "
            "and storage summaries before using this result as evidence."
        )
    return {
        "classified_as": classified_as,
        "evidence_status": evidence_status,
        "observed_baseline_policy_deny_original": original_baseline_deny,
        "observed_baseline_policy_deny_chat_backend": chat_baseline_deny,
        "interpretation": interpretation,
        "source_evidence": FAILURE_SOURCE_EVIDENCE,
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

    with CliNetworkApprovalResponsesServer() as mock_server:
        write_network_config(codex_home, mock_server.url)
        managed_config_path = write_managed_network_requirements(managed_dir)
        managed_requirements_path = managed_config_path.with_name("requirements.toml")
        with temporary_macos_managed_requirements(managed_requirements_path) as managed_preferences:
            network_tui = run_cli_network_approval_tui(
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
    analysis = (
        summary.get("network_approval_analysis")
        or summary.get("failure_analysis")
        or {}
    )
    lines = [
        "# CLI Network Approval Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow CLI/TUI managed-network approval smoke. It attempts to",
        "drive the real interactive Codex CLI in both vendored trees, accept a",
        "visible network approval prompt once, and then resume through",
        "`codex exec --json`.",
        "",
        "On macOS this script temporarily injects the managed network",
        "`requirements.toml` through `com.openai.codex:requirements_toml_base64`",
        "because the real CLI uses `LoaderOverrides::default()` rather than the",
        "app-server-only managed-config debug hook.",
        "",
        "It does not prove every network approval decision, file-change approval,",
        "additional-permission approval, crash recovery, or final user",
        "indistinguishability.",
        "",
        "## Result",
        "",
        f"- passed: `{summary['passed']}`",
        f"- original managed preferences applied/restored: `{summary['original_managed_preferences_applied']}` / `{summary['original_managed_preferences_restored']}`",
        f"- `.chat` managed preferences applied/restored: `{summary['chat_backend_managed_preferences_applied']}` / `{summary['chat_backend_managed_preferences_restored']}`",
        f"- original TUI reached network approval: `{summary['original_tui_reached_network_approval']}`",
        f"- `.chat` TUI reached network approval: `{summary['chat_backend_tui_reached_network_approval']}`",
        f"- normalized follow-up CLI output equal: `{summary['normalized_followup_exec_equal']}`",
        f"- mock request summaries equal: `{summary['mock_request_summaries_equal']}`",
        f"- durable line counts equal: `{summary['final_durable_line_counts_equal']}`",
        f"- `.chat` package has network timeline/source transport: `{summary['chat_backend_has_network_timeline']}`",
        "",
        "## Evidence Analysis",
        "",
        f"- classification: `{analysis.get('classified_as', 'not-applicable')}`",
        f"- evidence status: `{analysis.get('evidence_status', 'not-applicable')}`",
        f"- original observed baseline policy deny: `{analysis.get('observed_baseline_policy_deny_original')}`",
        f"- `.chat` observed baseline policy deny: `{analysis.get('observed_baseline_policy_deny_chat_backend')}`",
        "",
        analysis.get("interpretation", "No evidence analysis recorded."),
        "",
        "## Evidence",
        "",
        "- `summary.json`",
        "",
    ]
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-network-approval-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        "scope": "cli-network-approval-smoke",
        "matrix_slice": ["T06-network-cli-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
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
        "original_tui_sent_network_accept": original_result["network_tui"][
            "sent_network_accept"
        ],
        "chat_backend_tui_sent_network_accept": chat_result["network_tui"][
            "sent_network_accept"
        ],
        "original_tui_final_visible": original_result["network_tui"]["final_answer_visible"],
        "chat_backend_tui_final_visible": chat_result["network_tui"]["final_answer_visible"],
        "tui_response_request_counts_equal_after_network_approval": (
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
        "network_function_output_round_trip": (
            original_mock["second_body_contains_function_output"]
            and chat_mock["second_body_contains_function_output"]
            and original_mock["second_body_contains_network_host"]
            and chat_mock["second_body_contains_network_host"]
        ),
        "followup_context_preserved_after_network_approval": (
            original_mock["third_body_contains_original_user_text"]
            and chat_mock["third_body_contains_original_user_text"]
            and original_mock["third_body_contains_network_host"]
            and chat_mock["third_body_contains_network_host"]
            and original_mock["third_body_contains_first_final_text"]
            and chat_mock["third_body_contains_first_final_text"]
        ),
        "original_has_network_persisted": original_has_network_persisted(original_result),
        "chat_backend_has_network_timeline": chat_backend_has_network_timeline(chat_result),
        "network_approval_analysis": build_network_approval_analysis(
            original_result,
            chat_result,
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
            "CLI network approval accept-for-session and allow-in-future decisions",
            "CLI network approval cancel/block variants",
            "CLI file-change and additional-permission approval variants",
            "approval process-kill or crash recovery",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    summary["passed"] = all(
        [
            summary["original_tui_reached_network_approval"],
            summary["chat_backend_tui_reached_network_approval"],
            summary["original_tui_sent_network_accept"],
            summary["chat_backend_tui_sent_network_accept"],
            summary["original_managed_preferences_applied"],
            summary["chat_backend_managed_preferences_applied"],
            summary["original_managed_preferences_restored"],
            summary["chat_backend_managed_preferences_restored"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_network_approval"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["network_function_output_round_trip"],
            summary["followup_context_preserved_after_network_approval"],
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
