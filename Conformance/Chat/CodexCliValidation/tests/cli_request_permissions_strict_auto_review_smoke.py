#!/usr/bin/env python3
"""Run real CLI/TUI request_permissions strict-auto-review parity smoke."""

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
from cli_request_permissions_continue_without_smoke import (  # noqa: E402
    extract_journal_payloads,
    find_function_call_output,
    parse_output_json,
    permissions_empty,
)
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


USER_TEXT = "Run the request_permissions strict auto review smoke."
STRICT_FINAL_TEXT = "Request permissions strict auto review turn complete."
FOLLOWUP_USER_TEXT = "CLI request permissions strict auto review follow-up."
FOLLOWUP_ASSISTANT_TEXT = (
    "CLI request permissions strict auto review follow-up answer from mock model."
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
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_session_grant_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_continue_without_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/app_server_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/tests/guardian_tests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
        "lines": "389-435,1058-1087",
        "finding": "The standalone strict-auto-review option is bound to `r` and sends scope=turn, requested permissions, and strict_auto_review=true.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/app/app_server_requests.rs",
        "lines": "220-236",
        "finding": "The TUI forwards request_permissions responses to the app server and includes strict_auto_review only when it is true.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
        "lines": "2567-2592,2596-2614",
        "finding": "Core normalization preserves strict_auto_review for turn-scoped non-empty permission grants and records strict auto review in turn state.",
    },
]


class RequestPermissionsStrictResponsesServer(RequestPermissionsResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_request_permissions_call(
                "resp-cli-request-permissions-strict-call",
                CALL_ID,
            ),
            ev_final_message(
                "resp-cli-request-permissions-strict-final",
                "msg-cli-request-permissions-strict-final",
                STRICT_FINAL_TEXT,
            ),
            ev_final_message(
                "resp-cli-request-permissions-strict-followup",
                "msg-cli-request-permissions-strict-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]


def walk_json(value: Any) -> list[Any]:
    items = [value]
    if isinstance(value, dict):
        for child in value.values():
            items.extend(walk_json(child))
    elif isinstance(value, list):
        for child in value:
            items.extend(walk_json(child))
    return items


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def permission_output_is_strict_turn_grant(parsed: dict[str, Any]) -> bool:
    permissions = parsed.get("permissions")
    serialized_permissions = json.dumps(permissions, ensure_ascii=False)
    return (
        parsed.get("scope") == "turn"
        and parsed.get("strict_auto_review") is True
        and parsed.get("strictAutoReview") in (None, True)
        and not permissions_empty(permissions)
        and "file_system" in serialized_permissions
        and "write" in serialized_permissions
    )


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    second_output = parse_output_json(find_function_call_output(second_body, CALL_ID))
    third_output = parse_output_json(find_function_call_output(third_body, CALL_ID))
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
            find_function_call_output(second_body, CALL_ID) is not None
        ),
        "second_permission_output": second_output,
        "second_permission_output_is_strict_turn_grant": (
            permission_output_is_strict_turn_grant(second_output)
        ),
        "second_body_contains_strict_final_text": body_contains(
            second_body,
            STRICT_FINAL_TEXT,
        ),
        "third_body_contains_user_text": body_contains(third_body, USER_TEXT),
        "third_body_contains_strict_final_text": body_contains(
            third_body,
            STRICT_FINAL_TEXT,
        ),
        "third_body_contains_followup_user_text": body_contains(
            third_body,
            FOLLOWUP_USER_TEXT,
        ),
        "third_body_contains_permission_function_output": (
            find_function_call_output(third_body, CALL_ID) is not None
        ),
        "third_permission_output": third_output,
        "third_permission_output_is_strict_turn_grant": (
            permission_output_is_strict_turn_grant(third_output)
        ),
        "third_body_contains_shell_command": serialized_contains(
            third_body,
            "shell_command",
        ),
    }


def normalize_mock_summary_paths(
    summary: dict[str, Any],
    workspace: pathlib.Path,
) -> dict[str, Any]:
    """Normalize expected per-backend fixture roots without hiding behavior diffs."""

    replacements = {
        str(workspace): "<workspace>",
        str(workspace.parent / "shared"): "<workspace-parent-shared>",
    }

    def normalize(value: Any) -> Any:
        if isinstance(value, str):
            normalized = value
            for concrete, placeholder in replacements.items():
                normalized = normalized.replace(concrete, placeholder)
            return normalized
        if isinstance(value, list):
            return [normalize(item) for item in value]
        if isinstance(value, dict):
            return {key: normalize(child) for key, child in value.items()}
        return value

    normalized_summary = normalize(summary)
    assert isinstance(normalized_summary, dict)
    return normalized_summary


def run_cli_request_permissions_strict_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: RequestPermissionsStrictResponsesServer,
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
    sent_strict_auto_review = False
    strict_history_visible_at: float | None = None
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
                or "grantforthisturnwithstrictautoreview" in compact_tail.lower()
                or "strict auto review" in stripped_tail.lower()
            )
            if permissions_prompt_visible and permissions_prompt_visible_at is None:
                permissions_prompt_visible_at = time.time()

            if (
                permissions_prompt_visible_at is not None
                and not sent_strict_auto_review
                and time.time() - permissions_prompt_visible_at >= APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"r")
                sent_strict_auto_review = True

            if (
                "Yougrantedadditionalpermissionswithstrictautoreview" in compact_tail
                and strict_history_visible_at is None
            ):
                strict_history_visible_at = time.time()

            if STRICT_FINAL_TEXT in decoded_output and final_visible_at is None:
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
        "sent_first_prompt": sent_first_prompt,
        "first_prompt_enter_retry_sent": first_prompt_enter_retry_sent,
        "permissions_prompt_visible": permissions_prompt_visible_at is not None,
        "sent_strict_auto_review": sent_strict_auto_review,
        "strict_history_visible": strict_history_visible_at is not None,
        "final_visible": final_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-4200:],
        "raw_output_bytes": len(output),
    }


def payload_permission_output(payloads: list[dict[str, Any]]) -> dict[str, Any]:
    for payload in payloads:
        if payload.get("type") == "function_call_output" and payload.get("call_id") == CALL_ID:
            output = payload.get("output")
            if not isinstance(output, str):
                return {}
            try:
                parsed = json.loads(output)
            except json.JSONDecodeError:
                return {"_raw_output": output}
            return parsed if isinstance(parsed, dict) else {"_parsed_output": parsed}
    return {}


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = extract_journal_payloads(journal_lines)
        permission_output = payload_permission_output(journal_payloads)
        packages.append(
            {
                "package": str(package),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_has_tool_call": any(
                    line.get("type") == "tool_call" for line in timeline_lines
                ),
                "timeline_has_tool_output": any(
                    line.get("type") == "tool_output" for line in timeline_lines
                ),
                "timeline_has_command_call": any(
                    line.get("type") == "command_call" for line in timeline_lines
                ),
                "timeline_has_command_output": any(
                    line.get("type") == "command_output" for line in timeline_lines
                ),
                "journal_has_request_permissions_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "request_permissions"
                    for payload in journal_payloads
                ),
                "journal_has_permission_function_output": any(
                    payload.get("type") == "function_call_output"
                    and payload.get("call_id") == CALL_ID
                    for payload in journal_payloads
                ),
                "journal_permission_output": permission_output,
                "journal_permission_output_is_strict_turn_grant": (
                    permission_output_is_strict_turn_grant(permission_output)
                ),
                "journal_contains_request_reason": REQUEST_REASON
                in json.dumps(journal_payloads, ensure_ascii=False),
            }
        )
    return {
        "summary": summarize_chat_packages(chat_root),
        "package_count": len(packages),
        "packages": packages,
        "timeline_has_tool_call": any(
            package["timeline_has_tool_call"] for package in packages
        ),
        "timeline_has_tool_output": any(
            package["timeline_has_tool_output"] for package in packages
        ),
        "timeline_has_command_call": any(
            package["timeline_has_command_call"] for package in packages
        ),
        "timeline_has_command_output": any(
            package["timeline_has_command_output"] for package in packages
        ),
        "journal_has_request_permissions_call": any(
            package["journal_has_request_permissions_call"] for package in packages
        ),
        "journal_has_permission_function_output": any(
            package["journal_has_permission_function_output"] for package in packages
        ),
        "journal_permission_output_is_strict_turn_grant": any(
            package["journal_permission_output_is_strict_turn_grant"]
            for package in packages
        ),
    }


def original_rollout_observation(codex_home: pathlib.Path) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
        payloads = [
            line.get("payload") or {}
            for line in lines
            if line.get("type") == "response_item"
        ]
        permission_output = payload_permission_output(payloads)
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "has_request_permissions_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "request_permissions"
                    for payload in payloads
                ),
                "has_permission_function_output": any(
                    payload.get("type") == "function_call_output"
                    and payload.get("call_id") == CALL_ID
                    for payload in payloads
                ),
                "has_command_function_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                    for payload in payloads
                ),
                "has_command_function_output": any(
                    payload.get("type") == "function_call_output"
                    and payload.get("call_id") != CALL_ID
                    for payload in payloads
                ),
                "permission_output": permission_output,
                "permission_output_is_strict_turn_grant": (
                    permission_output_is_strict_turn_grant(permission_output)
                ),
            }
        )
    return {
        "rollout_count": len(rollouts),
        "rollouts": rollouts,
        "has_request_permissions_call": any(
            rollout["has_request_permissions_call"] for rollout in rollouts
        ),
        "has_permission_function_output": any(
            rollout["has_permission_function_output"] for rollout in rollouts
        ),
        "has_command_function_call": any(
            rollout["has_command_function_call"] for rollout in rollouts
        ),
        "has_command_function_output": any(
            rollout["has_command_function_output"] for rollout in rollouts
        ),
        "permission_output_is_strict_turn_grant": any(
            rollout["permission_output_is_strict_turn_grant"] for rollout in rollouts
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

    with RequestPermissionsStrictResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        approval_tui = run_cli_request_permissions_strict_tui(
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
        result["original_rollout_observation"] = original_rollout_observation(
            codex_home,
        )
    return result


def build_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> str:
    source_lines = "\n".join(
        f"- `{finding['file']}:{finding['lines']}`: {finding['finding']}"
        for finding in SOURCE_FINDINGS
    )
    return f"""# CLI Request Permissions Strict Auto Review Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI and a local mock Responses API that
returns a model-side `request_permissions` function call followed by a normal
assistant final response after the user grants the requested permissions for
this turn with strict auto review.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
Codex request-permissions TUI/core source files were read. The unmodified
original source tree was used only as the oracle.

## Scope

This smoke covers a narrow T06 user-visible slice: standalone
`request_permissions` approval with the strict-auto-review turn grant choice in
the real TUI.

It verifies:

- both real TUIs show the standalone permissions modal;
- pressing `r` selects `Yes, grant for this turn with strict auto review`;
- the turn continues and shows the final assistant answer;
- follow-up `codex exec --json resume --last` preserves the user prompt, final
  answer, and strict permission output in context;
- normalized follow-up CLI output matches;
- the `.chat` backend records `tool_call` / `tool_output` for
  `request_permissions`;
- the `.chat` backend does not fabricate `command_call` / `command_output`;
- the `.chat` journal retains source transport for the request and the
  turn-scoped permission response with `strict_auto_review=true`.

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
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-request-permissions-strict-auto-review-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-request-permissions-strict-auto-review-response.json
```

## Not Yet Proven

This smoke does not prove strict-auto-review guardian behavior for a later
shell command, request-permissions crash recovery, network approval variants,
complete T06 data fidelity, or final user-indistinguishability.
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-request-permissions-strict-auto-review-smoke-"
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
    original_mock_for_compare = normalize_mock_summary_paths(
        original_mock,
        pathlib.Path(original_result["workspace"]),
    )
    chat_mock_for_compare = normalize_mock_summary_paths(
        chat_mock,
        pathlib.Path(chat_result["workspace"]),
    )
    original_lines = original_result["final_line_counts"]
    chat_lines = chat_result["final_line_counts"]
    original_rollout = original_result["original_rollout_observation"]
    chat_package = chat_result["chat_package_observation"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-request-permissions-strict-auto-review-smoke",
        "matrix_slice": [
            "T06-request-permissions-strict-auto-review-TUI",
            "R01-adjacent",
        ],
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
        "original_tui_sent_strict_auto_review": original_result["approval_tui"][
            "sent_strict_auto_review"
        ],
        "chat_backend_tui_sent_strict_auto_review": chat_result["approval_tui"][
            "sent_strict_auto_review"
        ],
        "original_tui_strict_history_visible": original_result["approval_tui"][
            "strict_history_visible"
        ],
        "chat_backend_tui_strict_history_visible": chat_result["approval_tui"][
            "strict_history_visible"
        ],
        "original_tui_final_visible": original_result["approval_tui"]["final_visible"],
        "chat_backend_tui_final_visible": chat_result["approval_tui"]["final_visible"],
        "tui_response_request_counts_equal_after_strict_grant": (
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
        "mock_request_summaries_equal": original_mock_for_compare == chat_mock_for_compare,
        "mock_request_summaries_normalization": {
            "normalized_paths": [
                "workspace",
                "workspace-parent-shared",
            ],
            "reason": (
                "Original and .chat backend runs use separate fixture roots; "
                "the permission behavior is compared after replacing only the "
                "expected workspace and sibling shared paths with role labels."
            ),
        },
        "original_mock_server_summary_for_compare": original_mock_for_compare,
        "chat_backend_mock_server_summary_for_compare": chat_mock_for_compare,
        "mock_permission_output_is_strict_turn_grant": (
            original_mock["second_permission_output_is_strict_turn_grant"]
            and chat_mock["second_permission_output_is_strict_turn_grant"]
        ),
        "followup_context_preserved_after_strict_grant": (
            original_mock["third_body_contains_user_text"]
            and chat_mock["third_body_contains_user_text"]
            and original_mock["third_body_contains_strict_final_text"]
            and chat_mock["third_body_contains_strict_final_text"]
            and original_mock["third_body_contains_followup_user_text"]
            and chat_mock["third_body_contains_followup_user_text"]
            and original_mock["third_permission_output_is_strict_turn_grant"]
            and chat_mock["third_permission_output_is_strict_turn_grant"]
        ),
        "no_shell_command_requested_after_strict_grant": (
            not original_mock["third_body_contains_shell_command"]
            and not chat_mock["third_body_contains_shell_command"]
        ),
        "original_persisted_strict_grant_flow": (
            original_rollout["has_request_permissions_call"]
            and original_rollout["has_permission_function_output"]
            and original_rollout["permission_output_is_strict_turn_grant"]
            and not original_rollout["has_command_function_call"]
            and not original_rollout["has_command_function_output"]
        ),
        "chat_backend_has_tool_timeline_without_command_timeline": (
            chat_package["timeline_has_tool_call"]
            and chat_package["timeline_has_tool_output"]
            and not chat_package["timeline_has_command_call"]
            and not chat_package["timeline_has_command_output"]
        ),
        "chat_backend_has_strict_grant_source_transport": (
            chat_package["journal_has_request_permissions_call"]
            and chat_package["journal_has_permission_function_output"]
            and chat_package["journal_permission_output_is_strict_turn_grant"]
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
            "final_line_counts": chat_lines,
            "chat_package_observation": chat_package,
        },
        "not_yet_proven": [
            "strict-auto-review guardian behavior for a later shell command",
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
            summary["original_tui_sent_strict_auto_review"],
            summary["chat_backend_tui_sent_strict_auto_review"],
            summary["original_tui_strict_history_visible"],
            summary["chat_backend_tui_strict_history_visible"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_strict_grant"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_permission_output_is_strict_turn_grant"],
            summary["followup_context_preserved_after_strict_grant"],
            summary["no_shell_command_requested_after_strict_grant"],
            summary["original_persisted_strict_grant_flow"],
            summary["chat_backend_has_tool_timeline_without_command_timeline"],
            summary["chat_backend_has_strict_grant_source_transport"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI request_permissions "
        "strict-auto-review grant slice: both backends show the real standalone "
        "permissions modal, select the strict auto-review turn grant through "
        "the TUI `r` shortcut, continue the turn with a non-empty turn-scoped "
        "permission response carrying strict_auto_review=true, preserve "
        "follow-up resume context, avoid fabricating command timeline events, "
        "and keep durable original rollout line counts equal to `.chat` journal "
        "line counts. It is not full approval parity."
    )

    write_json(
        output_dir
        / "original"
        / "cli-request-permissions-strict-auto-review-response.json",
        original_result,
    )
    write_json(
        output_dir
        / "chat-backend"
        / "cli-request-permissions-strict-auto-review-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
