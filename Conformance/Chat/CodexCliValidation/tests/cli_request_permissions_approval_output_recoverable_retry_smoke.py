#!/usr/bin/env python3
"""Run real CLI/TUI request_permissions approval-output recoverable retry smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a standalone request_permissions tool call
    approve the request in the real TUI
    inject one recoverable .chat append error after the approval output is
    canonical and before standard projections are rebuilt
    wait for the first turn to complete
    codex exec --json resume --last ...

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06, H05, crash-recovery, or user-indistinguishability
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
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from app_server_h04_projection_failpoint_crash_smoke import (  # noqa: E402
    all_projections_repaired,
)
from app_server_request_permissions_approval_output_failpoint_smoke import (  # noqa: E402
    chat_journal_signatures,
    package_contains_approval_output,
)
from app_server_request_permissions_smoke import (  # noqa: E402
    CALL_ID,
    FIRST_FINAL_TEXT,
    REQUEST_REASON,
    USER_TEXT,
    RequestPermissionsResponsesServer,
    ev_final_message,
    ev_request_permissions_call,
    summarize_chat_timeline,
    write_request_permissions_config,
)
from app_server_stale_projection_repair_smoke import observe_package  # noqa: E402
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


FOLLOWUP_USER_TEXT = "CLI request permissions approval-output retry follow-up."
FOLLOWUP_ASSISTANT_TEXT = (
    "CLI request permissions approval-output retry follow-up answer from mock model."
)
APPROVAL_IDLE_SECONDS = 1.8

RECOVERABLE_FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT"
RECOVERABLE_MARKER_ENV = "CODEX_CHAT_BACKEND_VALIDATION_RECOVERABLE_FAILPOINT_MARKER"
FAILPOINT_NEEDLE_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT_NEEDLE"
FAILPOINT_NAME = "after-canonical-before-projections"
FAILPOINT_NEEDLE = "function_call_output"

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
    "Conformance/Chat/CodexCliValidation/tests/app_server_request_permissions_approval_output_recoverable_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_session_grant_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_crash_pending_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_h05_recoverable_append_retry_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/live_writer.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "tests/app_server_request_permissions_approval_output_recoverable_retry_smoke.py",
        "finding": (
            "The app-server slice already proves the recoverable failpoint after "
            "approval function_call_output is canonical and before projections rebuild."
        ),
    },
    {
        "file": "tests/cli_request_permissions_session_grant_smoke.py",
        "finding": (
            "The real TUI reaches the standalone permissions modal and uses the "
            "`a` shortcut for a session grant."
        ),
    },
    {
        "file": "tests/cli_h05_recoverable_append_retry_smoke.py",
        "finding": (
            "`codex exec --json` follow-up plus line-count and source-signature "
            "checks are the accepted CLI recoverable retry evidence pattern."
        ),
    },
]


class ApprovalOutputRetryResponsesServer(RequestPermissionsResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_request_permissions_call(
                "resp-cli-request-permissions-approval-retry-call",
                CALL_ID,
            ),
            ev_final_message(
                "resp-cli-request-permissions-approval-retry-final",
                "msg-cli-request-permissions-approval-retry-final",
                FIRST_FINAL_TEXT,
            ),
            ev_final_message(
                "resp-cli-request-permissions-approval-retry-followup",
                "msg-cli-request-permissions-approval-retry-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]


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
        "third_body_contains_first_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_first_final_text": body_contains(
            third_body,
            FIRST_FINAL_TEXT,
        ),
        "third_body_contains_followup_user_text": body_contains(
            third_body,
            FOLLOWUP_USER_TEXT,
        ),
        "third_body_contains_permission_function_output": (
            serialized_contains(third_body, CALL_ID)
            and serialized_contains(third_body, "function_call_output")
        ),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def approval_output_signature_count(signatures: list[dict[str, Any]]) -> int:
    return sum(
        1
        for signature in signatures
        if signature.get("payload_type") == "function_call_output"
        and signature.get("call_id") == CALL_ID
    )


def single_chat_package(chat_root: pathlib.Path) -> pathlib.Path:
    packages = sorted(chat_root.glob("*.chat"))
    if len(packages) != 1:
        raise RuntimeError(f"expected one .chat package, found {len(packages)}")
    return packages[0]


def chat_thread_id(chat_root: pathlib.Path) -> str:
    package = single_chat_package(chat_root)
    return package.name.removesuffix(".chat")


def source_signatures_for_chat(chat_root: pathlib.Path) -> list[dict[str, Any]]:
    return chat_journal_signatures(single_chat_package(chat_root))


def rollout_payload_signature(value: dict[str, Any]) -> dict[str, Any]:
    payload = value.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    return {
        "type": value.get("type"),
        "payload_type": payload.get("type"),
        "role": payload.get("role"),
        "name": payload.get("name"),
        "call_id": payload.get("call_id"),
    }


def original_session_rollout_signatures(codex_home: pathlib.Path) -> list[dict[str, Any]]:
    rollout_paths = []
    for path in sorted(codex_home.rglob("*.jsonl")):
        relative = path.relative_to(codex_home).as_posix()
        if relative.startswith("sessions/") or relative.startswith("archived_sessions/"):
            rollout_paths.append(path)
    if len(rollout_paths) != 1:
        raise RuntimeError(f"expected one session rollout, found {len(rollout_paths)}")
    return [rollout_payload_signature(line) for line in read_json_lines(rollout_paths[0])]


def package_contains_text(chat_root: pathlib.Path, text: str) -> bool:
    package = single_chat_package(chat_root)
    for name in ["timeline.ndjson", "journal.ndjson"]:
        path = package / name
        if path.exists() and text in path.read_text():
            return True
    return False


def valid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("valid_line_count") or 0)


def invalid_line_count(observation: dict[str, Any], file_kind: str) -> int:
    return int((observation.get(file_kind) or {}).get("invalid_line_count") or 0)


def run_cli_request_permissions_approval_retry_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: ApprovalOutputRetryResponsesServer,
    extra_env: dict[str, str] | None = None,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")
    if extra_env:
        env.update(extra_env)

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
    sent_session_grant = False
    final_visible_at: float | None = None
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 90:
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
                and not sent_session_grant
                and time.time() - permissions_prompt_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"a")
                sent_session_grant = True

            if FIRST_FINAL_TEXT in decoded_output and final_visible_at is None:
                final_visible_at = time.time()

            if (
                final_visible_at is not None
                and time.time() - final_visible_at > 1.5
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
        "permissions_prompt_visible": permissions_prompt_visible_at is not None,
        "sent_session_grant": sent_session_grant,
        "final_visible": final_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-4200:],
        "raw_output_bytes": len(output),
    }


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    first_tui_extra_env: dict[str, str] | None = None,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with ApprovalOutputRetryResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        approval_tui = run_cli_request_permissions_approval_retry_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
            extra_env=first_tui_extra_env,
        )
        after_tui_storage = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

        if tree_name == "chat-backend":
            thread_id = chat_thread_id(chat_root)
            after_tui_source_signatures = source_signatures_for_chat(chat_root)
            after_tui_observation = observe_package(chat_root, thread_id, "plain")
            after_tui_timeline_summary = summarize_chat_timeline(chat_root)
        else:
            thread_id = None
            after_tui_source_signatures = original_session_rollout_signatures(codex_home)
            after_tui_observation = None
            after_tui_timeline_summary = None

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

        if tree_name == "chat-backend":
            final_source_signatures = source_signatures_for_chat(chat_root)
            final_observation = observe_package(chat_root, thread_id, "plain")
            final_timeline_summary = summarize_chat_timeline(chat_root)
        else:
            final_source_signatures = original_session_rollout_signatures(codex_home)
            final_observation = None
            final_timeline_summary = None

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "thread_id": thread_id,
        "approval_tui": approval_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
        "after_tui_source_signatures": after_tui_source_signatures,
        "final_source_signatures": final_source_signatures,
        "after_tui_observation": after_tui_observation,
        "final_observation": final_observation,
        "after_tui_timeline_summary": after_tui_timeline_summary,
        "final_timeline_summary": final_timeline_summary,
    }


def build_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> str:
    source_lines = "\n".join(
        f"- `{finding['file']}`: {finding['finding']}"
        for finding in SOURCE_FINDINGS
    )
    return f"""# CLI Request Permissions Approval-Output Recoverable Retry Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI, approves a standalone
`request_permissions` prompt, injects a one-shot recoverable append error after
the approval `function_call_output` reaches canonical `.chat` storage and
before projection rebuild, then verifies a normal `codex exec --json
resume --last` follow-up.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
Codex request-permissions/TUI/retry source files were read. The unmodified
original source tree was used only as the oracle.

## Scope

This smoke covers a narrow T06/H05/R01-adjacent user-visible slice:
standalone `request_permissions` approval output with a recoverable `.chat`
projection-boundary append error in the real CLI/TUI path.

The adapted backend uses:

```text
{RECOVERABLE_FAILPOINT_ENV}={FAILPOINT_NAME}
{RECOVERABLE_MARKER_ENV}={summary['failpoint']['marker_path']}
{FAILPOINT_NEEDLE_ENV}={FAILPOINT_NEEDLE}
```

It verifies:

- both real TUIs show the standalone permissions modal;
- both real TUIs send the session-grant approval shortcut;
- the `.chat` backend consumes the one-shot recoverable marker;
- both TUIs show the same first final answer;
- follow-up `codex exec --json resume --last` exits successfully on both backends;
- normalized follow-up CLI JSONL output matches;
- mock model request summaries match;
- the `.chat` backend does not duplicate the approval `function_call_output`;
- `.chat` source signatures and durable line counts match the original rollout;
- standard projections remain valid after the TUI turn and after follow-up resume.

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

This smoke does not prove later-batch approval crash boundaries, arbitrary real
filesystem I/O failures outside the validation failpoint, broader approval
crash variants, command-execution crash recovery, complete global T06 data
fidelity, final crash recovery parity, or final user-indistinguishability.
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-request-permissions-approval-output-recoverable-retry-smoke-"
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
    marker_path = run_root / "chat-backend" / "recoverable-approval-output.marker"
    marker_path.parent.mkdir(parents=True, exist_ok=True)
    marker_path.write_text("fire-once\n")
    failpoint_env = {
        RECOVERABLE_FAILPOINT_ENV: FAILPOINT_NAME,
        RECOVERABLE_MARKER_ENV: str(marker_path),
        FAILPOINT_NEEDLE_ENV: FAILPOINT_NEEDLE,
    }

    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
        first_tui_extra_env=failpoint_env,
    )

    original_followup = original_result["followup_exec"]
    chat_followup = chat_result["followup_exec"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    after_tui_observation = chat_result["after_tui_observation"] or {}
    final_observation = chat_result["final_observation"] or {}
    original_after_tui_signatures = original_result["after_tui_source_signatures"]
    chat_after_tui_signatures = chat_result["after_tui_source_signatures"]
    original_final_signatures = original_result["final_source_signatures"]
    chat_final_signatures = chat_result["final_source_signatures"]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "cli-request-permissions-approval-output-recoverable-retry-smoke",
        "matrix_slice": [
            "T06-request-permissions-approval-output",
            "H05-recoverable-retry",
            "R01-followup-resume",
        ],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "failpoint": {
            "env": RECOVERABLE_FAILPOINT_ENV,
            "value": FAILPOINT_NAME,
            "marker_env": RECOVERABLE_MARKER_ENV,
            "marker_path": str(marker_path),
            "needle_env": FAILPOINT_NEEDLE_ENV,
            "needle": FAILPOINT_NEEDLE,
            "boundary": (
                "return one recoverable append error after approval "
                "function_call_output is canonical and before projection rebuild"
            ),
        },
        "binary_checks": binary_checks,
        "chat_backend_marker_consumed_once": not marker_path.exists(),
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
            "final_visible"
        ],
        "chat_backend_tui_first_final_visible": chat_result["approval_tui"][
            "final_visible"
        ],
        "tui_response_request_counts_equal_after_approval": (
            original_result["approval_tui"]["response_request_count_after_tui"]
            == chat_result["approval_tui"]["response_request_count_after_tui"]
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
        "mock_permission_output_contains_session_grant": (
            original_mock["second_body_contains_permission_function_output"]
            and chat_mock["second_body_contains_permission_function_output"]
            and original_mock["second_body_contains_session_scope"]
            and chat_mock["second_body_contains_session_scope"]
            and original_mock["second_body_contains_granted_write"]
            and chat_mock["second_body_contains_granted_write"]
        ),
        "followup_context_preserved_after_approval": (
            original_mock["third_body_contains_first_user_text"]
            and chat_mock["third_body_contains_first_user_text"]
            and original_mock["third_body_contains_first_final_text"]
            and chat_mock["third_body_contains_first_final_text"]
            and original_mock["third_body_contains_followup_user_text"]
            and chat_mock["third_body_contains_followup_user_text"]
            and original_mock["third_body_contains_permission_function_output"]
            and chat_mock["third_body_contains_permission_function_output"]
        ),
        "after_tui_durable_line_counts_equal": (
            original_result["after_tui_line_counts"]
            == chat_result["after_tui_line_counts"]
            and bool(original_result["after_tui_line_counts"])
        ),
        "final_durable_line_counts_equal": (
            original_result["final_line_counts"]
            == chat_result["final_line_counts"]
            and bool(original_result["final_line_counts"])
        ),
        "after_tui_source_signatures_match_original": (
            chat_after_tui_signatures == original_after_tui_signatures
        ),
        "final_source_signatures_match_original": (
            chat_final_signatures == original_final_signatures
        ),
        "chat_backend_approval_output_not_duplicated_after_tui": (
            approval_output_signature_count(chat_after_tui_signatures) == 1
        ),
        "chat_backend_approval_output_not_duplicated_after_resume": (
            approval_output_signature_count(chat_final_signatures) == 1
        ),
        "chat_backend_retains_approval_output_after_tui": package_contains_approval_output(
            chat_result["after_tui_timeline_summary"] or {},
        ),
        "chat_backend_retains_first_final_answer_after_tui": package_contains_text(
            chat_store_root,
            FIRST_FINAL_TEXT,
        ),
        "chat_backend_retains_followup_answer_after_resume": package_contains_text(
            chat_store_root,
            FOLLOWUP_ASSISTANT_TEXT,
        ),
        "chat_backend_projections_ok_after_tui": all_projections_repaired(
            after_tui_observation,
        ),
        "chat_backend_projections_ok_after_resume": all_projections_repaired(
            final_observation,
        ),
        "chat_backend_no_invalid_canonical_lines": (
            invalid_line_count(after_tui_observation, "timeline") == 0
            and invalid_line_count(after_tui_observation, "journal") == 0
            and invalid_line_count(final_observation, "timeline") == 0
            and invalid_line_count(final_observation, "journal") == 0
        ),
        "chat_backend_timeline_line_count_after_tui": valid_line_count(
            after_tui_observation,
            "timeline",
        ),
        "chat_backend_timeline_line_count_after_resume": valid_line_count(
            final_observation,
            "timeline",
        ),
        "original_after_tui_line_counts": original_result["after_tui_line_counts"],
        "chat_backend_after_tui_line_counts": chat_result["after_tui_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "original_after_tui_source_signatures": original_after_tui_signatures,
        "chat_backend_after_tui_source_signatures": chat_after_tui_signatures,
        "original_final_source_signatures": original_final_signatures,
        "chat_backend_final_source_signatures": chat_final_signatures,
        "original": {
            "approval_tui": original_result["approval_tui"],
            "followup_exec": {
                "command": original_followup["command"],
                "exit_code": original_followup["exit_code"],
                "normalized_events": normalize_exec_events(original_followup["events"]),
                "stderr_tail": original_followup["stderr_tail"],
            },
            "mock_server_summary": original_mock,
            "after_tui_storage": original_result["after_tui_storage"],
            "final_storage": original_result["final_storage"],
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
            "after_tui_storage": chat_result["after_tui_storage"],
            "final_storage": chat_result["final_storage"],
            "after_tui_observation": after_tui_observation,
            "final_observation": final_observation,
            "after_tui_timeline_summary": chat_result["after_tui_timeline_summary"],
            "final_timeline_summary": chat_result["final_timeline_summary"],
        },
        "not_yet_proven": [
            "later-batch approval crash boundaries after approval output",
            "broader approval crash variants across network, file-change, freeform apply_patch, and additional-permissions flows",
            "arbitrary transient filesystem I/O failures outside this validation failpoint",
            "command-execution crash recovery",
            "complete global T06 data fidelity",
            "final crash recovery parity",
            "final user-indistinguishability",
        ],
    }
    summary["passed"] = all(
        [
            summary["chat_backend_marker_consumed_once"],
            summary["original_tui_reached_permissions_prompt"],
            summary["chat_backend_tui_reached_permissions_prompt"],
            summary["original_tui_sent_session_grant"],
            summary["chat_backend_tui_sent_session_grant"],
            summary["original_tui_first_final_visible"],
            summary["chat_backend_tui_first_final_visible"],
            summary["tui_response_request_counts_equal_after_approval"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_permission_output_contains_session_grant"],
            summary["followup_context_preserved_after_approval"],
            summary["after_tui_durable_line_counts_equal"],
            summary["final_durable_line_counts_equal"],
            summary["after_tui_source_signatures_match_original"],
            summary["final_source_signatures_match_original"],
            summary["chat_backend_approval_output_not_duplicated_after_tui"],
            summary["chat_backend_approval_output_not_duplicated_after_resume"],
            summary["chat_backend_retains_approval_output_after_tui"],
            summary["chat_backend_retains_first_final_answer_after_tui"],
            summary["chat_backend_retains_followup_answer_after_resume"],
            summary["chat_backend_projections_ok_after_tui"],
            summary["chat_backend_projections_ok_after_resume"],
            summary["chat_backend_no_invalid_canonical_lines"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI request_permissions "
        "approval-output recoverable retry slice: both backends reach the real "
        "standalone permissions modal, send the approval decision, complete the "
        "turn, and preserve follow-up resume behavior; the adapted .chat "
        "backend consumes one recoverable failpoint after approval "
        "function_call_output reaches canonical storage, avoids duplicating it, "
        "keeps projections valid, and matches original durable line counts and "
        "source signatures. It is not final approval or crash parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
