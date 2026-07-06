#!/usr/bin/env python3
"""Run real CLI/TUI request_permissions pending-crash parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a standalone request_permissions tool call
    wait until the TUI permissions modal is visible
    kill the TUI process before sending any approval decision
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06 approval, crash-recovery, or user-indistinguishability
claim.
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
from app_server_request_permissions_crash_pending_resume_smoke import (  # noqa: E402
    summarize_request_permissions_chat_timeline,
    summarize_request_permissions_original_rollouts,
)
from app_server_request_permissions_smoke import (  # noqa: E402
    CALL_ID,
    REQUEST_REASON,
    RequestPermissionsResponsesServer,
    ev_final_message,
    ev_request_permissions_call,
    write_request_permissions_config,
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


USER_TEXT = "Run request permissions and keep it pending during CLI crash."
FOLLOWUP_USER_TEXT = "CLI request permissions pending crash follow-up."
FOLLOWUP_ASSISTANT_TEXT = (
    "CLI request permissions pending crash follow-up answer from mock model."
)
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
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_session_grant_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_continue_without_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_crash_pending_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/protocol_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "tests/app_server_request_permissions_crash_pending_resume_smoke.py",
        "finding": (
            "The app-server pending-crash slice shows that a standalone "
            "request_permissions call is persisted as a neutral tool_call "
            "without fabricating a tool_output or command event after process death."
        ),
    },
    {
        "file": "tests/cli_request_permissions_session_grant_smoke.py",
        "finding": (
            "The real TUI reaches the standalone permissions modal and uses the "
            "`a` shortcut for session grant; this smoke reuses the same modal "
            "detection but intentionally sends no decision."
        ),
    },
    {
        "file": "tests/cli_exec_resume_smoke.py",
        "finding": (
            "`codex exec --json resume --last` is the existing CLI-level cold "
            "resume surface for comparing user-visible JSONL output and model "
            "request context."
        ),
    },
]


class PendingCrashRequestPermissionsTuiServer(RequestPermissionsResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_request_permissions_call(
                "resp-cli-request-permissions-pending-crash-call",
                CALL_ID,
            ),
            ev_final_message(
                "resp-cli-request-permissions-pending-crash-followup",
                "msg-cli-request-permissions-pending-crash-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]


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
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "first_body_contains_request_permissions": serialized_contains(
            first_body,
            "request_permissions",
        ),
        # The request reason is model output, not model input. It belongs in
        # canonical storage / source transport checks, not the first request body.
        "second_body_contains_original_user_text": body_contains(
            second_body,
            USER_TEXT,
        ),
        "second_body_contains_followup_user_text": body_contains(
            second_body,
            FOLLOWUP_USER_TEXT,
        ),
        "second_body_contains_request_permissions": serialized_contains(
            second_body,
            "request_permissions",
        ),
        "second_body_contains_call_id": serialized_contains(second_body, CALL_ID),
        "second_body_contains_permission_function_output": (
            serialized_contains(second_body, CALL_ID)
            and serialized_contains(second_body, "function_call_output")
        ),
    }


def session_rollouts(summary: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        rollout
        for rollout in (summary.get("rollouts") or [])
        if (rollout.get("path") or "").startswith("sessions/")
        or (rollout.get("path") or "").startswith("archived_sessions/")
    ]


def request_permissions_cli_pending_storage_equivalent(
    original_summary: dict[str, Any],
    chat_summary: dict[str, Any],
) -> bool:
    original_rollouts = session_rollouts(original_summary)
    chat_packages = chat_summary.get("packages") or []
    if len(original_rollouts) != 1 or len(chat_packages) != 1:
        return False
    original = original_rollouts[0]
    chat = chat_packages[0]
    original_has_call = "request_permissions" in original["function_call_names"]
    original_outputs = original["function_call_output_call_ids"]
    return (
        chat["journal_has_request_permissions_call"] == original_has_call
        and chat["timeline_tool_call_count"] == (1 if original_has_call else 0)
        and chat["timeline_tool_output_count"] == len(original_outputs)
        and chat["journal_function_call_output_call_ids"] == original_outputs
        and chat["journal_contains_request_reason"] == original["contains_request_reason"]
        and not chat["timeline_command_call_count"]
    )


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_request_permissions_pending_crash_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: PendingCrashRequestPermissionsTuiServer,
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
    permissions_prompt_visible_at: float | None = None
    killed_after_permissions_prompt = False

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
            if ready_for_prompt and not sent_prompt:
                type_prompt_and_enter(master, USER_TEXT)
                sent_prompt = True
                prompt_sent_at = time.time()

            if (
                sent_prompt
                and request_count < 1
                and prompt_sent_at is not None
                and time.time() - prompt_sent_at > 2.0
                and not prompt_enter_retry_sent
            ):
                os.write(master, b"\r")
                prompt_enter_retry_sent = True

            permissions_prompt_visible = (
                "Wouldyouliketograntthesepermissions?" in compact_tail
                or "Yes,grantthesepermissionsforthissession" in compact_tail
                or "Nocontinuewithoutpermissions" in compact_tail
            )
            if permissions_prompt_visible and permissions_prompt_visible_at is None:
                permissions_prompt_visible_at = time.time()

            if (
                permissions_prompt_visible_at is not None
                and time.time() - permissions_prompt_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                process.kill()
                killed_after_permissions_prompt = True
                break

            if process.poll() is not None:
                break

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
        "permissions_prompt_visible": permissions_prompt_visible_at is not None,
        "killed_after_permissions_prompt": killed_after_permissions_prompt,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
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
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with PendingCrashRequestPermissionsTuiServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        pending_tui = run_cli_request_permissions_pending_crash_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        after_crash_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        after_crash_request_permissions_summary = (
            summarize_request_permissions_chat_timeline(chat_root)
            if tree_name == "chat-backend"
            else summarize_request_permissions_original_rollouts(codex_home)
        )
        resume_exec = run_cli_command(
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
        final_request_permissions_summary = (
            summarize_request_permissions_chat_timeline(chat_root)
            if tree_name == "chat-backend"
            else summarize_request_permissions_original_rollouts(codex_home)
        )

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "pending_tui": pending_tui,
        "resume_exec": resume_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_crash_storage": after_crash_storage,
        "final_storage": final_storage,
        "after_crash_line_counts": durable_line_counts(after_crash_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
        "after_crash_request_permissions_summary": (
            after_crash_request_permissions_summary
        ),
        "final_request_permissions_summary": final_request_permissions_summary,
    }


def build_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> str:
    source_lines = "\n".join(
        f"- `{finding['file']}`: {finding['finding']}"
        for finding in SOURCE_FINDINGS
    )
    return f"""# CLI Request Permissions Pending Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI, waits for a standalone
`request_permissions` approval modal, kills the process before any decision is
sent, and then uses `codex exec --json resume --last` as the cold CLI resume
surface.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
request-permissions crash/TUI sources were read. The unmodified original source
tree was used only as the oracle.

## Scope

This smoke covers a narrow T06/R01/H05-adjacent user-visible slice:
standalone `request_permissions` pending approval followed by CLI/TUI process
death before approval.

It verifies:

- both real TUIs show the standalone permissions modal;
- both TUI processes are killed after the modal appears and before a decision;
- both backends make the same model requests before and after cold resume;
- both resume surfaces return matching normalized CLI JSONL output;
- the `.chat` backend records the persisted pending request as a neutral
  `tool_call`;
- the `.chat` backend does not fabricate a `tool_output` or command event for
  a request that never received an approval decision;
- durable line counts stay aligned with the original rollout.

This smoke does not claim complete T06 conformance or final crash recovery.

## Source Basis

{source_lines}

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original-result.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend-result.json
```

## Not Yet Proven

This smoke does not prove durable-write-boundary failpoints inside the approval
response path, broader approval crash variants, command-execution crash
recovery, complete T06 data fidelity, or final user-indistinguishability.
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-request-permissions-crash-pending-resume-smoke-"
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_resume = original_result["resume_exec"]
    chat_resume = chat_result["resume_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    pending_storage_equivalent_after_crash = (
        request_permissions_cli_pending_storage_equivalent(
            original_result["after_crash_request_permissions_summary"],
            chat_result["after_crash_request_permissions_summary"],
        )
    )
    pending_storage_equivalent_after_resume = (
        request_permissions_cli_pending_storage_equivalent(
            original_result["final_request_permissions_summary"],
            chat_result["final_request_permissions_summary"],
        )
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "cli-request-permissions-crash-pending-resume-smoke",
        "matrix_slice": [
            "T06-request-permissions-pending-approval",
            "R01-cold-resume-after-killed-tui",
            "H05-adjacent-process-kill-before-approval-decision",
        ],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "binary_checks": binary_checks,
        "original_tui_reached_permissions_prompt": original_result["pending_tui"][
            "permissions_prompt_visible"
        ],
        "chat_backend_tui_reached_permissions_prompt": chat_result["pending_tui"][
            "permissions_prompt_visible"
        ],
        "original_tui_killed_after_permissions_prompt": original_result["pending_tui"][
            "killed_after_permissions_prompt"
        ],
        "chat_backend_tui_killed_after_permissions_prompt": chat_result["pending_tui"][
            "killed_after_permissions_prompt"
        ],
        "original_tui_exit_code": original_result["pending_tui"]["exit_code"],
        "chat_backend_tui_exit_code": chat_result["pending_tui"]["exit_code"],
        "tui_exit_codes_equal": (
            original_result["pending_tui"]["exit_code"]
            == chat_result["pending_tui"]["exit_code"]
        ),
        "tui_response_request_counts_equal_after_pending": (
            original_result["pending_tui"]["response_request_count_after_tui"]
            == chat_result["pending_tui"]["response_request_count_after_tui"]
            == 1
        ),
        "resume_exec_exit_codes_equal": (
            original_resume["exit_code"] == chat_resume["exit_code"]
        ),
        "resume_exec_exit_ok": (
            original_resume["exit_code"] == chat_resume["exit_code"] == 0
        ),
        "normalized_resume_exec_equal": (
            normalize_exec_events(original_resume["events"])
            == normalize_exec_events(chat_resume["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "mock_pending_request_observed": (
            original_mock["first_body_contains_user_text"]
            and chat_mock["first_body_contains_user_text"]
            and original_mock["first_body_contains_request_permissions"]
            and chat_mock["first_body_contains_request_permissions"]
        ),
        "mock_resume_context_equal": original_mock == chat_mock,
        "mock_resume_contains_followup_user_text": (
            original_mock["second_body_contains_followup_user_text"]
            and chat_mock["second_body_contains_followup_user_text"]
        ),
        "resume_projection_function_output_behavior_equal": (
            original_mock["second_body_contains_permission_function_output"]
            == chat_mock["second_body_contains_permission_function_output"]
        ),
        "resume_projection_includes_balancing_function_output": original_mock[
            "second_body_contains_permission_function_output"
        ]
        and chat_mock["second_body_contains_permission_function_output"],
        "canonical_storage_does_not_fabricate_tool_output": (
            pending_storage_equivalent_after_crash
            and pending_storage_equivalent_after_resume
        ),
        "pending_storage_equivalent_after_crash": pending_storage_equivalent_after_crash,
        "pending_storage_equivalent_after_resume": pending_storage_equivalent_after_resume,
        "after_crash_durable_line_counts_equal": (
            original_result["after_crash_line_counts"]
            == chat_result["after_crash_line_counts"]
            and bool(original_result["after_crash_line_counts"])
        ),
        "final_durable_line_counts_equal": (
            original_result["final_line_counts"]
            == chat_result["final_line_counts"]
            and bool(original_result["final_line_counts"])
        ),
        "original_after_crash_line_counts": original_result["after_crash_line_counts"],
        "chat_backend_after_crash_line_counts": chat_result["after_crash_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "original": {
            "pending_tui": original_result["pending_tui"],
            "resume_exec": {
                "command": original_resume["command"],
                "exit_code": original_resume["exit_code"],
                "normalized_events": normalize_exec_events(original_resume["events"]),
                "stderr_tail": original_resume["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "after_crash_storage": original_result["after_crash_storage"],
            "final_storage": original_result["final_storage"],
            "after_crash_request_permissions_summary": original_result[
                "after_crash_request_permissions_summary"
            ],
            "final_request_permissions_summary": original_result[
                "final_request_permissions_summary"
            ],
        },
        "chat_backend": {
            "pending_tui": chat_result["pending_tui"],
            "resume_exec": {
                "command": chat_resume["command"],
                "exit_code": chat_resume["exit_code"],
                "normalized_events": normalize_exec_events(chat_resume["events"]),
                "stderr_tail": chat_resume["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "after_crash_storage": chat_result["after_crash_storage"],
            "final_storage": chat_result["final_storage"],
            "after_crash_request_permissions_summary": chat_result[
                "after_crash_request_permissions_summary"
            ],
            "final_request_permissions_summary": chat_result[
                "final_request_permissions_summary"
            ],
        },
        "not_yet_proven": [
            "durable-write-boundary failpoints inside request_permissions approval response handling",
            "broader approval crash variants beyond pending prompt process kill",
            "command-execution crash recovery",
            "complete global T06 data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_permissions_prompt"],
            summary["chat_backend_tui_reached_permissions_prompt"],
            summary["original_tui_killed_after_permissions_prompt"],
            summary["chat_backend_tui_killed_after_permissions_prompt"],
            summary["tui_exit_codes_equal"],
            summary["tui_response_request_counts_equal_after_pending"],
            summary["resume_exec_exit_codes_equal"],
            summary["normalized_resume_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_pending_request_observed"],
            summary["mock_resume_context_equal"],
            summary["mock_resume_contains_followup_user_text"],
            summary["resume_projection_function_output_behavior_equal"],
            summary["resume_projection_includes_balancing_function_output"],
            summary["canonical_storage_does_not_fabricate_tool_output"],
            summary["pending_storage_equivalent_after_crash"],
            summary["after_crash_durable_line_counts_equal"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow CLI/TUI pending request_permissions process-kill "
        "slice: both backends reach the real standalone permissions modal, are "
        "killed before approval, resume through the same CLI surface with "
        "matching normalized output and model request context, and keep the "
        "pending request persisted as a neutral tool_call without fabricated "
        "tool_output or command events. It is not complete approval crash "
        "recovery or final user-indistinguishability."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    if not passed:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
