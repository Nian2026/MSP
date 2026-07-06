#!/usr/bin/env python3
"""Run real CLI/TUI request_permissions session-grant parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a request_permissions tool call
    press the TUI shortcut for "grant these permissions for this session"
    type a second prompt that uses the granted session permission
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
from app_server_request_permissions_smoke import (  # noqa: E402
    CALL_ID,
    COMMAND_CALL_ID,
    COMMAND_OUTPUT_TEXT,
    FIRST_FINAL_TEXT,
    REQUEST_REASON,
    SECOND_FINAL_TEXT,
    SECOND_USER_TEXT,
    USER_TEXT,
    RequestPermissionsResponsesServer,
    ev_final_message,
    summarize_chat_timeline,
    summarize_original_rollouts,
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


FOLLOWUP_USER_TEXT = "CLI request permissions session grant follow-up."
FOLLOWUP_ASSISTANT_TEXT = (
    "CLI request permissions session grant follow-up answer from mock model."
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
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_cache_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_additional_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/protocol_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/snapshots/codex_tui__bottom_pane__approval_overlay__tests__approval_overlay_permissions_prompt.snap",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
        "lines": "263-265,1038-1086",
        "finding": "Standalone request_permissions approvals render the permissions modal with turn, strict-auto-review, session, and continue-without-permissions choices.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
        "lines": "401-433",
        "finding": "The session choice sends RequestPermissionsResponse with scope=session; denied permissions send an empty profile.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
        "lines": "319-337",
        "finding": "App-server permissions requests are routed into ApprovalRequest::Permissions, distinct from Exec additional_permissions approval.",
    },
]


class RequestPermissionsTuiResponsesServer(RequestPermissionsResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses.append(
            ev_final_message(
                "resp-cli-request-permissions-followup",
                "msg-cli-request-permissions-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            )
        )


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def serialized_contains_scope(body: dict[str, Any], scope: str) -> bool:
    serialized = json.dumps(body, ensure_ascii=False)
    patterns = [
        f'"scope":"{scope}"',
        f'"scope": "{scope}"',
        f'\\"scope\\":\\"{scope}\\"',
        f'\\"scope\\": \\"{scope}\\"',
    ]
    return any(pattern in serialized for pattern in patterns)


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
        "first_body_contains_user_text": body_contains(first_body, USER_TEXT),
        "first_body_contains_request_permissions": serialized_contains(
            first_body,
            "request_permissions",
        ),
        "first_body_contains_request_reason": serialized_contains(
            first_body,
            REQUEST_REASON,
        ),
        "second_body_contains_permission_function_output": (
            serialized_contains(second_body, CALL_ID)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_session_scope": serialized_contains_scope(
            second_body,
            "session",
        ),
        "second_body_contains_granted_write": (
            serialized_contains(second_body, "file_system")
            and serialized_contains(second_body, "write")
        ),
        "second_body_contains_first_final_text": body_contains(
            second_body,
            FIRST_FINAL_TEXT,
        ),
        "third_body_contains_second_user_text": body_contains(
            third_body,
            SECOND_USER_TEXT,
        ),
        "third_body_contains_first_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_first_final_text": body_contains(
            third_body,
            FIRST_FINAL_TEXT,
        ),
        "fourth_body_contains_command_function_output": (
            serialized_contains(fourth_body, COMMAND_CALL_ID)
            and serialized_contains(fourth_body, "function_call_output")
        ),
        "fourth_body_contains_command_output": serialized_contains(
            fourth_body,
            COMMAND_OUTPUT_TEXT,
        ),
        "fourth_body_contains_second_final_text": body_contains(
            fourth_body,
            SECOND_FINAL_TEXT,
        ),
        "fifth_body_contains_first_user_text": body_contains(fifth_body, USER_TEXT),
        "fifth_body_contains_second_user_text": body_contains(
            fifth_body,
            SECOND_USER_TEXT,
        ),
        "fifth_body_contains_first_final_text": body_contains(
            fifth_body,
            FIRST_FINAL_TEXT,
        ),
        "fifth_body_contains_second_final_text": body_contains(
            fifth_body,
            SECOND_FINAL_TEXT,
        ),
        "fifth_body_contains_followup_user_text": body_contains(
            fifth_body,
            FOLLOWUP_USER_TEXT,
        ),
        "fifth_body_contains_command_output": serialized_contains(
            fifth_body,
            COMMAND_OUTPUT_TEXT,
        ),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_request_permissions_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: RequestPermissionsTuiResponsesServer,
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
    sent_first_prompt = False
    first_prompt_sent_at: float | None = None
    first_prompt_enter_retry_sent = False
    permissions_prompt_visible_at: float | None = None
    sent_session_grant = False
    first_final_visible_at: float | None = None
    sent_second_prompt = False
    second_prompt_sent_at: float | None = None
    second_prompt_output_offset: int | None = None
    second_prompt_enter_retry_sent = False
    unexpected_approval_after_second_prompt_at: float | None = None
    second_final_visible_at: float | None = None
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 105:
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
            if ready_for_prompt and not sent_first_prompt:
                type_prompt_and_enter(master, USER_TEXT)
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

            permissions_prompt_visible = (
                "Wouldyouliketograntthesepermissions?" in compact_tail
                or "Yes,grantthesepermissionsforthissession" in compact_tail
            )
            if permissions_prompt_visible and permissions_prompt_visible_at is None:
                permissions_prompt_visible_at = time.time()

            if (
                permissions_prompt_visible_at is not None
                and not sent_session_grant
                and time.time() - permissions_prompt_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"a")
                sent_session_grant = True

            if FIRST_FINAL_TEXT in decoded_output and first_final_visible_at is None:
                first_final_visible_at = time.time()

            if (
                first_final_visible_at is not None
                and time.time() - first_final_visible_at > 1.0
                and not sent_second_prompt
            ):
                second_prompt_output_offset = len(output)
                type_prompt_and_enter(master, SECOND_USER_TEXT)
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

            if second_prompt_output_offset is not None:
                after_second_prompt = strip_ansi(
                    output[second_prompt_output_offset:].decode(errors="replace")
                )
                after_second_prompt_compact = re.sub(r"\s+", "", after_second_prompt)
                unexpected_approval = (
                    "Wouldyouliketorunthefollowingcommand?"
                    in after_second_prompt_compact
                    or "Wouldyouliketograntthesepermissions?"
                    in after_second_prompt_compact
                )
                if (
                    unexpected_approval
                    and unexpected_approval_after_second_prompt_at is None
                ):
                    unexpected_approval_after_second_prompt_at = time.time()

            if SECOND_FINAL_TEXT in decoded_output and second_final_visible_at is None:
                second_final_visible_at = time.time()

            if (
                unexpected_approval_after_second_prompt_at is not None
                and time.time() - unexpected_approval_after_second_prompt_at > 1.5
                and not sent_ctrl_c
            ):
                os.write(master, b"\x03")
                sent_ctrl_c = True

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
    after_second_prompt_text = ""
    if second_prompt_output_offset is not None:
        after_second_prompt_text = strip_ansi(
            output[second_prompt_output_offset:].decode(errors="replace")
        )
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
        "permissions_prompt_visible": permissions_prompt_visible_at is not None,
        "sent_session_grant": sent_session_grant,
        "first_final_visible": first_final_visible_at is not None,
        "sent_second_prompt": sent_second_prompt,
        "second_prompt_enter_retry_sent": second_prompt_enter_retry_sent,
        "unexpected_approval_after_second_prompt": (
            unexpected_approval_after_second_prompt_at is not None
        ),
        "second_final_visible": second_final_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_after_second_prompt_stripped_tail": after_second_prompt_text[-2600:],
        "output_tail_stripped": stripped_output[-4200:],
        "raw_output_bytes": len(output),
    }


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    timeline = summarize_chat_timeline(chat_root)
    summary = summarize_chat_packages(chat_root)
    packages = timeline.get("packages") or []
    return {
        "summary": summary,
        "timeline": timeline,
        "package_count": summary.get("package_count"),
        "timeline_has_tool_call": any(
            package.get("timeline_has_tool_call") for package in packages
        ),
        "timeline_has_tool_output": any(
            package.get("timeline_has_tool_output") for package in packages
        ),
        "timeline_has_command_call": any(
            package.get("timeline_has_command_call") for package in packages
        ),
        "timeline_has_command_output": any(
            package.get("timeline_has_command_output") for package in packages
        ),
        "journal_has_request_permissions_call": any(
            package.get("journal_has_request_permissions_call") for package in packages
        ),
        "journal_has_permission_function_output": any(
            package.get("journal_has_function_call_output") for package in packages
        ),
        "journal_has_command_function_call": any(
            package.get("journal_has_command_function_call") for package in packages
        ),
        "journal_has_command_function_output": any(
            package.get("journal_has_command_function_call_output") for package in packages
        ),
        "journal_contains_request_reason": any(
            package.get("journal_contains_request_reason") for package in packages
        ),
        "journal_contains_granted_write": any(
            package.get("journal_contains_granted_write") for package in packages
        ),
        "journal_contains_session_scope": any(
            package.get("journal_contains_session_scope") for package in packages
        ),
        "journal_contains_command_output": any(
            package.get("journal_contains_command_output") for package in packages
        ),
    }


def original_rollout_observation(codex_home: pathlib.Path) -> dict[str, Any]:
    summary = summarize_original_rollouts(codex_home)
    rollouts = summary.get("rollouts") or []
    return {
        "summary": summary,
        "has_request_permissions_call": any(
            "request_permissions" in (rollout.get("function_call_names") or [])
            for rollout in rollouts
        ),
        "has_permission_function_output": any(
            CALL_ID in (rollout.get("function_call_output_call_ids") or [])
            for rollout in rollouts
        ),
        "has_command_function_call": any(
            "shell_command" in (rollout.get("function_call_names") or [])
            for rollout in rollouts
        ),
        "has_command_function_output": any(
            COMMAND_CALL_ID in (rollout.get("function_call_output_call_ids") or [])
            for rollout in rollouts
        ),
        "contains_request_reason": any(
            rollout.get("contains_request_reason") for rollout in rollouts
        ),
        "contains_granted_write": any(
            rollout.get("contains_granted_write") for rollout in rollouts
        ),
        "contains_session_scope": any(
            rollout.get("contains_session_scope") for rollout in rollouts
        ),
        "contains_command_output": any(
            rollout.get("contains_command_output") for rollout in rollouts
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

    with RequestPermissionsTuiResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        approval_tui = run_cli_request_permissions_tui(
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
        "workspace_effect": {
            "session_grant_file_exists": (workspace / "session-grant.txt").exists(),
            "session_grant_file_text": (workspace / "session-grant.txt").read_text()
            if (workspace / "session-grant.txt").exists()
            else None,
        },
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["chat_package_observation"] = chat_package_observation(chat_root)
    else:
        result["original_rollout_observation"] = original_rollout_observation(
            codex_home,
        )
    return result


def build_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> str:
    source_lines = "\n".join(
        f"- `{finding['file']}:{finding['lines']}`: {finding['finding']}"
        for finding in SOURCE_FINDINGS
    )
    return f"""# CLI Request Permissions Session Grant Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI and a local mock Responses API that
returns a model-side `request_permissions` function call followed by a
session-grant-dependent `shell_command`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
Codex request-permissions TUI source files were read. The unmodified original
source tree was used only as the oracle.

## Scope

This smoke covers a narrow T06 user-visible slice: standalone
`request_permissions` approval with the session-grant choice in the real TUI.

It verifies:

- both real TUIs show the standalone permissions modal;
- pressing `a` grants the requested permission for the session;
- a second prompt in the same TUI session can run the write command without a
  second approval modal;
- follow-up `codex exec --json resume --last` preserves the original user
  texts, both final answers, and command output in context;
- normalized follow-up CLI output matches;
- the `.chat` backend records `tool_call` / `tool_output` for
  `request_permissions`;
- the `.chat` backend records `command_call` / `command_output` for the later
  command;
- the `.chat` journal retains the source transport for request permissions,
  session scope, granted write permissions, command call, and command output.

This smoke does not claim complete T06 conformance.

## Source Basis

{source_lines}

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-request-permissions-session-grant-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-request-permissions-session-grant-response.json
```

## Not Yet Proven

This smoke does not prove strict auto-review grant, continue-without-permissions,
network approval variants, approval crash recovery, complete T06 data fidelity,
or final user-indistinguishability.
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-request-permissions-session-grant-smoke-"
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

    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_lines = original_result["final_line_counts"]
    chat_lines = chat_result["final_line_counts"]
    original_rollout = original_result["original_rollout_observation"]
    chat_package = chat_result["chat_package_observation"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-request-permissions-session-grant-smoke",
        "matrix_slice": ["T06-request-permissions-session-TUI", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "binary_checks": binary_checks,
        "original_tui_reached_permissions_prompt": original_result["approval_tui"][
            "permissions_prompt_visible"
        ],
        "chat_backend_tui_reached_permissions_prompt": chat_result["approval_tui"][
            "permissions_prompt_visible"
        ],
        "original_tui_sent_session_grant": original_result["approval_tui"][
            "sent_session_grant"
        ],
        "chat_backend_tui_sent_session_grant": chat_result["approval_tui"][
            "sent_session_grant"
        ],
        "original_tui_first_final_visible": original_result["approval_tui"][
            "first_final_visible"
        ],
        "chat_backend_tui_first_final_visible": chat_result["approval_tui"][
            "first_final_visible"
        ],
        "original_tui_sent_second_prompt": original_result["approval_tui"][
            "sent_second_prompt"
        ],
        "chat_backend_tui_sent_second_prompt": chat_result["approval_tui"][
            "sent_second_prompt"
        ],
        "original_tui_unexpected_approval_after_second_prompt": original_result[
            "approval_tui"
        ]["unexpected_approval_after_second_prompt"],
        "chat_backend_tui_unexpected_approval_after_second_prompt": chat_result[
            "approval_tui"
        ]["unexpected_approval_after_second_prompt"],
        "original_tui_second_final_visible": original_result["approval_tui"][
            "second_final_visible"
        ],
        "chat_backend_tui_second_final_visible": chat_result["approval_tui"][
            "second_final_visible"
        ],
        "tui_response_request_counts_equal_after_session_grant": (
            original_result["approval_tui"]["response_request_count_after_tui"]
            == chat_result["approval_tui"]["response_request_count_after_tui"]
            == 4
        ),
        "second_command_completed_without_second_approval": (
            original_result["approval_tui"]["sent_second_prompt"]
            and chat_result["approval_tui"]["sent_second_prompt"]
            and not original_result["approval_tui"][
                "unexpected_approval_after_second_prompt"
            ]
            and not chat_result["approval_tui"][
                "unexpected_approval_after_second_prompt"
            ]
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
        "mock_permission_output_contains_session_grant": (
            original_mock["second_body_contains_permission_function_output"]
            and chat_mock["second_body_contains_permission_function_output"]
            and original_mock["second_body_contains_session_scope"]
            and chat_mock["second_body_contains_session_scope"]
            and original_mock["second_body_contains_granted_write"]
            and chat_mock["second_body_contains_granted_write"]
        ),
        "mock_command_output_round_trip": (
            original_mock["fourth_body_contains_command_function_output"]
            and chat_mock["fourth_body_contains_command_function_output"]
            and original_mock["fourth_body_contains_command_output"]
            and chat_mock["fourth_body_contains_command_output"]
        ),
        "followup_context_preserved_after_session_grant": (
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
            and original_mock["fifth_body_contains_command_output"]
            and chat_mock["fifth_body_contains_command_output"]
        ),
        "workspace_effect_equal": (
            original_result["workspace_effect"] == chat_result["workspace_effect"]
        ),
        "workspace_file_written_after_session_grant": (
            original_result["workspace_effect"]["session_grant_file_exists"]
            and chat_result["workspace_effect"]["session_grant_file_exists"]
            and COMMAND_OUTPUT_TEXT
            in (original_result["workspace_effect"]["session_grant_file_text"] or "")
            and COMMAND_OUTPUT_TEXT
            in (chat_result["workspace_effect"]["session_grant_file_text"] or "")
        ),
        "original_persisted_request_permissions_flow": (
            original_rollout["has_request_permissions_call"]
            and original_rollout["has_permission_function_output"]
            and original_rollout["has_command_function_call"]
            and original_rollout["has_command_function_output"]
            and original_rollout["contains_request_reason"]
            and original_rollout["contains_granted_write"]
            and original_rollout["contains_session_scope"]
            and original_rollout["contains_command_output"]
        ),
        "chat_backend_has_tool_and_command_timeline": (
            chat_package["timeline_has_tool_call"]
            and chat_package["timeline_has_tool_output"]
            and chat_package["timeline_has_command_call"]
            and chat_package["timeline_has_command_output"]
        ),
        "chat_backend_has_request_permissions_source_transport": (
            chat_package["journal_has_request_permissions_call"]
            and chat_package["journal_has_permission_function_output"]
            and chat_package["journal_has_command_function_call"]
            and chat_package["journal_has_command_function_output"]
            and chat_package["journal_contains_request_reason"]
            and chat_package["journal_contains_granted_write"]
            and chat_package["journal_contains_session_scope"]
            and chat_package["journal_contains_command_output"]
        ),
        "original_final_line_counts": original_lines,
        "chat_backend_final_line_counts": chat_lines,
        "final_durable_line_counts_equal": original_lines == chat_lines
        and bool(original_lines),
        "original": {
            "approval_tui": original_result["approval_tui"],
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "workspace_effect": original_result["workspace_effect"],
            "final_line_counts": original_lines,
            "original_rollout_observation": original_rollout,
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
            "workspace_effect": chat_result["workspace_effect"],
            "final_line_counts": chat_lines,
            "chat_package_observation": chat_package,
        },
        "not_yet_proven": [
            "request_permissions strict auto-review through CLI/TUI",
            "request_permissions continue-without-permissions through CLI/TUI",
            "request_permissions crash recovery during approval flow",
            "network approval variants beyond existing accepted slices",
            "complete T06 approval data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_permissions_prompt"],
            summary["chat_backend_tui_reached_permissions_prompt"],
            summary["original_tui_sent_session_grant"],
            summary["chat_backend_tui_sent_session_grant"],
            summary["original_tui_first_final_visible"],
            summary["chat_backend_tui_first_final_visible"],
            summary["original_tui_second_final_visible"],
            summary["chat_backend_tui_second_final_visible"],
            summary["tui_response_request_counts_equal_after_session_grant"],
            summary["second_command_completed_without_second_approval"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_permission_output_contains_session_grant"],
            summary["mock_command_output_round_trip"],
            summary["followup_context_preserved_after_session_grant"],
            summary["workspace_effect_equal"],
            summary["workspace_file_written_after_session_grant"],
            summary["original_persisted_request_permissions_flow"],
            summary["chat_backend_has_tool_and_command_timeline"],
            summary["chat_backend_has_request_permissions_source_transport"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI request_permissions session "
        "grant slice: both backends show the real standalone permissions modal, "
        "grant the requested write permission for the session through the TUI "
        "shortcut, run a later write command without a second approval prompt, "
        "preserve follow-up resume context, and keep durable original rollout "
        "line counts equal to `.chat` journal line counts. It is not full "
        "approval parity."
    )

    write_json(
        output_dir / "original" / "cli-request-permissions-session-grant-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend" / "cli-request-permissions-session-grant-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
