#!/usr/bin/env python3
"""Run real CLI/TUI command additional-permissions parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers a shell_command with additional permissions
    press the TUI shortcut for "grant these permissions for this turn"
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
    FINAL_TEXT,
    FIXTURE_MARKER,
    FIXTURE_NAME,
    USER_TEXT,
    AdditionalPermissionsResponsesServer,
    ev_final_message,
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


FOLLOWUP_USER_TEXT = "CLI additional permissions follow-up after granted command."
FOLLOWUP_ASSISTANT_TEXT = "CLI additional permissions follow-up answer from mock model."
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
    "Conformance/Chat/CodexCliValidation/tests/app_server_command_additional_permissions_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_cache_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/approval_events.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/snapshots/codex_tui__bottom_pane__approval_overlay__tests__approval_overlay_additional_permissions_prompt.snap",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/snapshots/codex_tui__bottom_pane__approval_overlay__tests__approval_overlay_permissions_prompt.snap",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class AdditionalPermissionsTuiResponsesServer(AdditionalPermissionsResponsesServer):
    def __init__(self, command: str, fixture_path: pathlib.Path) -> None:
        super().__init__(command, fixture_path)
        self.responses.append(
            ev_final_message(
                "resp-cli-additional-permissions-followup",
                "msg-cli-additional-permissions-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            )
        )


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
    third_body = bodies[2] if len(bodies) > 2 else {}
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
        "second_body_contains_function_output": (
            serialized_contains(second_body, CALL_ID)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_fixture_marker": serialized_contains(
            second_body,
            FIXTURE_MARKER,
        ),
        "second_body_contains_final_text": body_contains(second_body, FINAL_TEXT),
        "third_body_contains_followup_user_text": body_contains(
            third_body,
            FOLLOWUP_USER_TEXT,
        ),
        "third_body_contains_original_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_fixture_marker": serialized_contains(
            third_body,
            FIXTURE_MARKER,
        ),
        "third_body_contains_first_final_text": body_contains(third_body, FINAL_TEXT),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_additional_permissions_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: AdditionalPermissionsTuiResponsesServer,
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
    sent_permission_grant = False
    final_answer_visible_at: float | None = None
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
            visible_tail = decoded_output[-3000:]
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
                "Wouldyouliketograntthesepermissions?" in compact_tail
                or "Yes,grantthesepermissionsforthisturn" in compact_tail
                or (
                    "Wouldyouliketorunthefollowingcommand?" in compact_tail
                    and "Permissionrule:" in compact_tail
                )
            )
            if permission_prompt_visible and permission_prompt_visible_at is None:
                permission_prompt_visible_at = time.time()

            if (
                permission_prompt_visible_at is not None
                and not sent_permission_grant
                and time.time() - permission_prompt_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"y")
                sent_permission_grant = True

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
        "permission_prompt_visible": permission_prompt_visible_at is not None,
        "sent_permission_grant": sent_permission_grant,
        "final_answer_visible": final_answer_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-3600:],
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
        "journal_contains_fixture_marker": any(
            package.get("journal_contains_fixture_marker") for package in packages
        ),
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

    with AdditionalPermissionsTuiResponsesServer(shell_command, fixture_path) as mock_server:
        write_additional_permissions_config(codex_home, mock_server.url)
        approval_tui = run_cli_additional_permissions_tui(
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


def original_has_additional_permissions_persisted(result: dict[str, Any]) -> bool:
    rollouts = result["original_rollout_summary"].get("rollouts") or []
    return any(
        "shell_command" in rollout.get("function_call_names", [])
        and rollout.get("function_call_output_call_ids")
        and rollout.get("contains_additional_permissions")
        and rollout.get("contains_with_additional_permissions")
        and rollout.get("contains_fixture_marker")
        for rollout in rollouts
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-command-additional-permissions-smoke-"
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
        "scope": "cli-command-additional-permissions-smoke",
        "matrix_slice": ["T06-additional-permissions-TUI", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "fixture_path": str(fixture_path),
        "binary_checks": binary_checks,
        "original_tui_reached_permission_prompt": original_result["approval_tui"][
            "permission_prompt_visible"
        ],
        "chat_backend_tui_reached_permission_prompt": chat_result["approval_tui"][
            "permission_prompt_visible"
        ],
        "original_tui_sent_permission_grant": original_result["approval_tui"][
            "sent_permission_grant"
        ],
        "chat_backend_tui_sent_permission_grant": chat_result["approval_tui"][
            "sent_permission_grant"
        ],
        "original_tui_final_visible": original_result["approval_tui"]["final_answer_visible"],
        "chat_backend_tui_final_visible": chat_result["approval_tui"][
            "final_answer_visible"
        ],
        "tui_response_request_counts_equal_after_permission_grant": (
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
        "mock_additional_permissions_arguments_sent": (
            original_mock["first_body_contains_additional_permissions"]
            and chat_mock["first_body_contains_additional_permissions"]
            and original_mock["first_body_contains_with_additional_permissions"]
            and chat_mock["first_body_contains_with_additional_permissions"]
        ),
        "mock_permission_output_round_trip": (
            original_mock["second_body_contains_function_output"]
            and chat_mock["second_body_contains_function_output"]
            and original_mock["second_body_contains_fixture_marker"]
            and chat_mock["second_body_contains_fixture_marker"]
        ),
        "followup_context_preserved_after_permission_grant": (
            original_mock["third_body_contains_original_user_text"]
            and chat_mock["third_body_contains_original_user_text"]
            and original_mock["third_body_contains_fixture_marker"]
            and chat_mock["third_body_contains_fixture_marker"]
            and original_mock["third_body_contains_first_final_text"]
            and chat_mock["third_body_contains_first_final_text"]
        ),
        "original_has_additional_permissions_persisted": (
            original_has_additional_permissions_persisted(original_result)
        ),
        "chat_backend_has_command_timeline": (
            chat_package["timeline_has_command_call"]
            and chat_package["timeline_has_command_output"]
        ),
        "chat_backend_has_source_transport": (
            chat_package["journal_has_shell_function_call"]
            and chat_package["journal_has_function_call_output"]
            and chat_package["journal_contains_additional_permissions"]
            and chat_package["journal_contains_with_additional_permissions"]
            and chat_package["journal_contains_fixture_marker"]
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
            "additional-permission strict auto-review grant through CLI/TUI",
            "additional-permission session grant through CLI/TUI",
            "additional-permission continue-without-permissions path through CLI/TUI",
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
            summary["original_tui_sent_permission_grant"],
            summary["chat_backend_tui_sent_permission_grant"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_permission_grant"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_additional_permissions_arguments_sent"],
            summary["mock_permission_output_round_trip"],
            summary["followup_context_preserved_after_permission_grant"],
            summary["original_has_additional_permissions_persisted"],
            summary["chat_backend_has_command_timeline"],
            summary["chat_backend_has_source_transport"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI additional-permissions "
        "approval accept slice: both backends show the real permissions prompt, "
        "grant the requested filesystem read permission through the TUI shortcut, "
        "round-trip the command output to the model, preserve follow-up resume "
        "context, and keep durable original rollout line counts equal to `.chat` "
        "journal line counts. It is not full approval parity."
    )

    write_json(
        output_dir / "original" / "cli-command-additional-permissions-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend" / "cli-command-additional-permissions-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# CLI Command Additional Permissions Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real Codex TUI and a local mock Responses API that returns a
`shell_command` with `sandbox_permissions = "with_additional_permissions"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
Codex additional-permissions TUI source files were read. The unmodified original
source tree was used only as the oracle.

## Scope

This smoke covers a narrow T06 user-visible slice: shell command approval with
inline additional filesystem read permission under `approval_policy =
"on-request"`.

It verifies:

- both real TUIs show the permissions prompt;
- pressing `y` grants the permission for this turn;
- the command can read the shared fixture and return stdout;
- follow-up `codex exec --json resume --last` preserves the original user text,
  fixture marker, and first assistant final answer in context;
- normalized follow-up CLI output matches;
- the `.chat` backend records `command_call` and `command_output`;
- the `.chat` journal retains the original shell source transport, including
  `additional_permissions`, `with_additional_permissions`, and the fixture
  marker.

This smoke does not claim complete T06 conformance.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-command-additional-permissions-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-command-additional-permissions-response.json
```

## Not Yet Proven

This smoke does not prove strict auto-review grant, session grant,
continue-without-permissions, cross-turn/new-environment network session
allow, persistent network allow/block, approval crash recovery, complete T06
data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
