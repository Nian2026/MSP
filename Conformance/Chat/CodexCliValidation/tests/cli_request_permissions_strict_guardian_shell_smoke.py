#!/usr/bin/env python3
"""Run real CLI/TUI strict-auto-review later shell guardian parity smoke."""

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
    COMMAND_CALL_ID,
    REQUEST_REASON,
    RequestPermissionsResponsesServer,
    ev_completed,
    ev_request_permissions_call,
    ev_response_created,
    ev_shell_command_call,
    sse,
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
from cli_request_permissions_strict_auto_review_smoke import (  # noqa: E402
    normalize_mock_summary_paths,
    payload_permission_output,
)
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


USER_TEXT = "Run the request_permissions later shell command smoke."
COMMAND_TEXT = "printf 'STRICT_GUARDIAN_WRITE_OK\\n' > strict-guardian.txt; cat strict-guardian.txt"
COMMAND_OUTPUT_TEXT = "STRICT_GUARDIAN_WRITE_OK"
FINAL_TEXT = "Request permissions strict guardian shell command complete."
FOLLOWUP_USER_TEXT = "CLI strict guardian shell follow-up."
FOLLOWUP_ASSISTANT_TEXT = "CLI strict guardian shell follow-up answer from mock model."
GUARDIAN_RATIONALE = "The later shell command stays within the strict turn permission grant."
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
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_strict_auto_review_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_request_permissions_session_grant_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/app_server_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/tests/guardian_tests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/orchestrator.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/handlers/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/handlers/shell.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/runtimes/shell.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/guardian/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/guardian/review.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/guardian/review_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
        "lines": "1058-1087,1953-1975",
        "finding": "The standalone permissions prompt exposes the `r` shortcut and sends a turn-scoped response with strict_auto_review=true.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
        "lines": "2567-2596,2596-2614,2645-2651",
        "finding": "Core normalization preserves strict_auto_review only for non-empty turn grants, records it in turn state, and exposes it to tool execution.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/orchestrator.rs",
        "lines": "145-181",
        "finding": "When strict auto review is enabled, even an ExecApprovalRequirement::Skip command creates a guardian review id and must be approved before execution.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/session/tests/guardian_tests.rs",
        "lines": "369-465",
        "finding": "The source-level oracle asserts a strict turn grant forces guardian review for a later shell command that would otherwise skip policy approval.",
    },
]


def ev_guardian_allow(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": f"msg-{response_id}",
                    "content": [
                        {
                            "type": "output_text",
                            "text": json.dumps(
                                {
                                    "risk_level": "low",
                                    "user_authorization": "high",
                                    "outcome": "allow",
                                    "rationale": GUARDIAN_RATIONALE,
                                },
                                separators=(",", ":"),
                            ),
                        }
                    ],
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message(response_id: str, message_id: str, text: str) -> bytes:
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


def serialized(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def serialized_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body, ensure_ascii=False)


def body_input_text(body: dict[str, Any]) -> str:
    return json.dumps(body.get("input"), ensure_ascii=False)


def guardian_request_classifier_details(body: dict[str, Any]) -> dict[str, bool]:
    input_text = body_input_text(body)
    whole_text = serialized(body)
    return {
        "has_approval_request_start": ">>> APPROVAL REQUEST START" in input_text,
        "has_approval_request_end": ">>> APPROVAL REQUEST END" in input_text,
        "has_planned_action_json": "Planned action JSON:" in input_text,
        "has_network_access_json": "Network access JSON:" in input_text,
        "has_guardian_output_schema": (
            '"risk_level"' in whole_text
            and '"user_authorization"' in whole_text
            and '"outcome"' in whole_text
        ),
    }


def is_guardian_request_body(body: dict[str, Any]) -> bool:
    details = guardian_request_classifier_details(body)
    return (
        details["has_approval_request_start"]
        and details["has_approval_request_end"]
        and (
            details["has_planned_action_json"]
            or details["has_network_access_json"]
        )
        and details["has_guardian_output_schema"]
    )


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


class StrictGuardianResponsesServer(RequestPermissionsResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_request_permissions_call(
                "resp-cli-request-permissions-strict-guardian-call",
                CALL_ID,
            ),
            ev_shell_command_call(
                "resp-cli-request-permissions-strict-guardian-command",
                COMMAND_CALL_ID,
                COMMAND_TEXT,
            ),
            ev_final_message(
                "resp-cli-request-permissions-strict-guardian-final",
                "msg-cli-request-permissions-strict-guardian-final",
                FINAL_TEXT,
            ),
            ev_final_message(
                "resp-cli-request-permissions-strict-guardian-followup",
                "msg-cli-request-permissions-strict-guardian-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            ),
        ]

    def _response_requests(self) -> list[dict[str, Any]]:
        return [
            request
            for request in self.requests
            if request.get("path", "").endswith("/responses")
        ]

    def _main_response_requests(self) -> list[dict[str, Any]]:
        return [
            request
            for request in self._response_requests()
            if not is_guardian_request_body(request.get("json") or {})
        ]

    def _guardian_response_requests(self) -> list[dict[str, Any]]:
        return [
            request
            for request in self._response_requests()
            if is_guardian_request_body(request.get("json") or {})
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            response_requests = self._response_requests()
            current = response_requests[-1] if response_requests else {}
            current_body = current.get("json") or {}
            if is_guardian_request_body(current_body):
                return ev_guardian_allow(
                    f"resp-cli-request-permissions-strict-guardian-review-{len(self._guardian_response_requests())}"
                )
            index = len(self._main_response_requests())
        if index < 1 or index > len(self.responses):
            return ev_final_message(
                "resp-cli-request-permissions-strict-guardian-extra",
                "msg-cli-request-permissions-strict-guardian-extra",
                "extra strict guardian shell response",
            )
        return self.responses[index - 1]


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def split_response_bodies(requests: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    bodies = response_request_bodies(requests)
    main_bodies = [body for body in bodies if not is_guardian_request_body(body)]
    guardian_bodies = [body for body in bodies if is_guardian_request_body(body)]
    return main_bodies, guardian_bodies


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    main_bodies, guardian_bodies = split_response_bodies(requests)
    first_body = main_bodies[0] if len(main_bodies) > 0 else {}
    second_body = main_bodies[1] if len(main_bodies) > 1 else {}
    third_body = main_bodies[2] if len(main_bodies) > 2 else {}
    fourth_body = main_bodies[3] if len(main_bodies) > 3 else {}
    guardian_body = guardian_bodies[0] if guardian_bodies else {}
    second_output = parse_output_json(find_function_call_output(second_body, CALL_ID))
    third_command_output = find_function_call_output(third_body, COMMAND_CALL_ID)
    fourth_permission_output = parse_output_json(find_function_call_output(fourth_body, CALL_ID))
    return {
        "request_count": len(requests),
        "response_request_count": response_request_count(requests),
        "main_response_request_count": len(main_bodies),
        "guardian_response_request_count": len(guardian_bodies),
        "paths": [request.get("path") for request in requests],
        "first_body_guardian_classifier": guardian_request_classifier_details(
            first_body,
        ),
        "guardian_body_classifier": guardian_request_classifier_details(
            guardian_body,
        ),
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
        "second_body_contains_shell_command": serialized_contains(
            second_body,
            COMMAND_CALL_ID,
        )
        or serialized_contains(second_body, "shell_command"),
        "guardian_body_contains_command": serialized_contains(guardian_body, COMMAND_TEXT)
        or serialized_contains(guardian_body, COMMAND_CALL_ID)
        or serialized_contains(guardian_body, "strict-guardian.txt"),
        "guardian_body_contains_approval_review": is_guardian_request_body(guardian_body),
        "third_body_contains_command_function_output": third_command_output is not None,
        "third_body_contains_command_output": (
            isinstance(third_command_output, str)
            and COMMAND_OUTPUT_TEXT in third_command_output
        )
        or serialized_contains(third_body, COMMAND_OUTPUT_TEXT),
        "third_body_contains_final_text": body_contains(third_body, FINAL_TEXT),
        "fourth_body_contains_followup_user_text": body_contains(
            fourth_body,
            FOLLOWUP_USER_TEXT,
        ),
        "fourth_body_contains_original_user_text": body_contains(fourth_body, USER_TEXT),
        "fourth_body_contains_final_text": body_contains(fourth_body, FINAL_TEXT),
        "fourth_body_contains_command_output": serialized_contains(
            fourth_body,
            COMMAND_OUTPUT_TEXT,
        ),
        "fourth_permission_output": fourth_permission_output,
        "fourth_permission_output_is_strict_turn_grant": (
            permission_output_is_strict_turn_grant(fourth_permission_output)
        ),
    }


def run_cli_strict_guardian_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: StrictGuardianResponsesServer,
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

        winsize = struct.pack("HHHH", 34, 120, 0, 0)
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
    unexpected_command_approval_visible_at: float | None = None
    command_output_visible_at: float | None = None
    final_visible_at: float | None = None
    sent_ctrl_c = False

    try:
        while time.time() - started_at < 120:
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
            visible_tail = decoded_output[-5000:]
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

            command_approval_visible = (
                "Doyouwanttoexec" in compact_tail
                or "approvecommand" in compact_tail.lower()
                or "Yes,proceed" in compact_tail
            )
            if (
                command_approval_visible
                and sent_strict_auto_review
                and unexpected_command_approval_visible_at is None
            ):
                unexpected_command_approval_visible_at = time.time()

            if COMMAND_OUTPUT_TEXT in decoded_output and command_output_visible_at is None:
                command_output_visible_at = time.time()

            if FINAL_TEXT in decoded_output and final_visible_at is None:
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
        "unexpected_command_approval_visible": unexpected_command_approval_visible_at
        is not None,
        "command_output_visible": command_output_visible_at is not None,
        "final_visible": final_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-5000:],
        "raw_output_bytes": len(output),
    }


def command_output_payload(payloads: list[dict[str, Any]]) -> str | None:
    for payload in payloads:
        if (
            payload.get("type") == "function_call_output"
            and payload.get("call_id") == COMMAND_CALL_ID
        ):
            output = payload.get("output")
            return output if isinstance(output, str) else None
    return None


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = extract_journal_payloads(journal_lines)
        permission_output = payload_permission_output(journal_payloads)
        command_output = command_output_payload(journal_payloads)
        serialized_timeline = serialized(timeline_lines)
        serialized_journal = serialized(journal_lines)
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
                "timeline_contains_command_output": COMMAND_OUTPUT_TEXT
                in serialized_timeline,
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
                "journal_has_shell_function_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                    for payload in journal_payloads
                ),
                "journal_has_shell_function_output": command_output is not None,
                "journal_permission_output": permission_output,
                "journal_permission_output_is_strict_turn_grant": (
                    permission_output_is_strict_turn_grant(permission_output)
                ),
                "journal_contains_command_output": COMMAND_OUTPUT_TEXT in serialized_journal,
                "journal_contains_guardian_rationale": GUARDIAN_RATIONALE
                in serialized_journal,
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
        "timeline_contains_command_output": any(
            package["timeline_contains_command_output"] for package in packages
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
        "journal_has_shell_function_call": any(
            package["journal_has_shell_function_call"] for package in packages
        ),
        "journal_has_shell_function_output": any(
            package["journal_has_shell_function_output"] for package in packages
        ),
        "journal_contains_command_output": any(
            package["journal_contains_command_output"] for package in packages
        ),
        "journal_contains_guardian_rationale": any(
            package["journal_contains_guardian_rationale"] for package in packages
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
        serialized_payloads = serialized(payloads)
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
                    and payload.get("call_id") == COMMAND_CALL_ID
                    for payload in payloads
                ),
                "permission_output": permission_output,
                "permission_output_is_strict_turn_grant": (
                    permission_output_is_strict_turn_grant(permission_output)
                ),
                "contains_command_output": COMMAND_OUTPUT_TEXT in serialized_payloads,
                "contains_guardian_rationale": GUARDIAN_RATIONALE in serialized_payloads,
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
        "contains_command_output": any(
            rollout["contains_command_output"] for rollout in rollouts
        ),
        "contains_guardian_rationale": any(
            rollout["contains_guardian_rationale"] for rollout in rollouts
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
    (workspace.parent / "shared").mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with StrictGuardianResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        approval_tui = run_cli_strict_guardian_tui(
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
            "strict_guardian_file_exists": (workspace / "strict-guardian.txt").exists(),
            "strict_guardian_file_text": (workspace / "strict-guardian.txt").read_text()
            if (workspace / "strict-guardian.txt").exists()
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
    return f"""# CLI Request Permissions Strict Guardian Shell Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI and a local mock Responses API that
returns a model-side `request_permissions` function call, receives the user's
strict-auto-review turn grant, then returns a later `shell_command` in the same
turn. The later shell command must be reviewed by the guardian auto-review path
before it is executed.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current reports, and relevant
Codex request-permissions, strict-auto-review, guardian, and shell-runtime
source files were read. The unmodified original source tree was used only as
the oracle.

## Scope

This smoke covers a narrow T06 user-visible/runtime slice: standalone
`request_permissions` strict-auto-review grant followed by a same-turn shell
command that must pass guardian review without showing an ordinary command
approval prompt.

It verifies:

- both real TUIs show the standalone permissions modal;
- pressing `r` selects the strict-auto-review turn grant;
- the same turn later receives a `shell_command`;
- both backends send exactly one guardian review request for the later command;
- no ordinary command approval modal is shown after the strict grant;
- the command executes and writes the same workspace file;
- follow-up `codex exec --json resume --last` preserves the strict grant,
  command output, final answer, and follow-up prompt;
- normalized follow-up CLI output and mock request summaries match;
- the `.chat` backend records request_permissions as `tool_call` /
  `tool_output` and the later shell command as `command_call` /
  `command_output`;
- source transport retains request permissions, command call/output, and
  guardian review data where the adapted backend persists it.

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
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-request-permissions-strict-guardian-shell-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-request-permissions-strict-guardian-shell-response.json
```

## Not Yet Proven

This smoke does not prove request-permissions approval crash recovery, network
approval variants, complete T06 data fidelity, or final
user-indistinguishability.
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-request-permissions-strict-guardian-shell-smoke-"
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
        "scope": "cli-request-permissions-strict-guardian-shell-smoke",
        "matrix_slice": [
            "T06-request-permissions-strict-auto-review-later-shell-guardian",
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
        "original_no_unexpected_command_approval_prompt": not original_result["approval_tui"][
            "unexpected_command_approval_visible"
        ],
        "chat_backend_no_unexpected_command_approval_prompt": not chat_result["approval_tui"][
            "unexpected_command_approval_visible"
        ],
        "original_tui_command_output_visible": original_result["approval_tui"][
            "command_output_visible"
        ],
        "chat_backend_tui_command_output_visible": chat_result["approval_tui"][
            "command_output_visible"
        ],
        "original_tui_final_visible": original_result["approval_tui"]["final_visible"],
        "chat_backend_tui_final_visible": chat_result["approval_tui"]["final_visible"],
        "workspace_effects_equal": original_result["workspace_effect"]
        == chat_result["workspace_effect"],
        "workspace_command_effect_ok": (
            original_result["workspace_effect"]["strict_guardian_file_text"]
            == chat_result["workspace_effect"]["strict_guardian_file_text"]
            == f"{COMMAND_OUTPUT_TEXT}\n"
        ),
        "guardian_review_requests_equal": (
            original_mock["guardian_response_request_count"]
            == chat_mock["guardian_response_request_count"]
            == 1
        ),
        "guardian_requests_contain_later_command": (
            original_mock["guardian_body_contains_command"]
            and chat_mock["guardian_body_contains_command"]
        ),
        "main_response_request_counts_equal": (
            original_mock["main_response_request_count"]
            == chat_mock["main_response_request_count"]
            == 4
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
        "mock_command_output_round_trip": (
            original_mock["third_body_contains_command_function_output"]
            and chat_mock["third_body_contains_command_function_output"]
            and original_mock["third_body_contains_command_output"]
            and chat_mock["third_body_contains_command_output"]
        ),
        "followup_context_preserved_after_guardian_command": (
            original_mock["fourth_body_contains_original_user_text"]
            and chat_mock["fourth_body_contains_original_user_text"]
            and original_mock["fourth_body_contains_final_text"]
            and chat_mock["fourth_body_contains_final_text"]
            and original_mock["fourth_body_contains_followup_user_text"]
            and chat_mock["fourth_body_contains_followup_user_text"]
            and original_mock["fourth_body_contains_command_output"]
            and chat_mock["fourth_body_contains_command_output"]
            and original_mock["fourth_permission_output_is_strict_turn_grant"]
            and chat_mock["fourth_permission_output_is_strict_turn_grant"]
        ),
        "original_persisted_strict_guardian_command_flow": (
            original_rollout["has_request_permissions_call"]
            and original_rollout["has_permission_function_output"]
            and original_rollout["permission_output_is_strict_turn_grant"]
            and original_rollout["has_command_function_call"]
            and original_rollout["has_command_function_output"]
            and original_rollout["contains_command_output"]
        ),
        "original_persisted_guardian_review": original_rollout[
            "contains_guardian_rationale"
        ],
        "chat_backend_has_tool_and_command_timeline": (
            chat_package["timeline_has_tool_call"]
            and chat_package["timeline_has_tool_output"]
            and chat_package["timeline_has_command_call"]
            and chat_package["timeline_has_command_output"]
        ),
        "chat_backend_has_request_permissions_source_transport": (
            chat_package["journal_has_request_permissions_call"]
            and chat_package["journal_has_permission_function_output"]
            and chat_package["journal_permission_output_is_strict_turn_grant"]
        ),
        "chat_backend_has_command_source_transport": (
            chat_package["journal_has_shell_function_call"]
            and chat_package["journal_has_shell_function_output"]
            and chat_package["journal_contains_command_output"]
        ),
        "chat_backend_retains_guardian_review_where_persisted": chat_package[
            "journal_contains_guardian_rationale"
        ],
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
            summary["original_no_unexpected_command_approval_prompt"],
            summary["chat_backend_no_unexpected_command_approval_prompt"],
            summary["original_tui_command_output_visible"],
            summary["chat_backend_tui_command_output_visible"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["workspace_effects_equal"],
            summary["workspace_command_effect_ok"],
            summary["guardian_review_requests_equal"],
            summary["guardian_requests_contain_later_command"],
            summary["main_response_request_counts_equal"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_permission_output_is_strict_turn_grant"],
            summary["mock_command_output_round_trip"],
            summary["followup_context_preserved_after_guardian_command"],
            summary["original_persisted_strict_guardian_command_flow"],
            summary["chat_backend_has_tool_and_command_timeline"],
            summary["chat_backend_has_request_permissions_source_transport"],
            summary["chat_backend_has_command_source_transport"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing/runtime CLI/TUI request_permissions "
        "strict-auto-review guardian slice: both backends show the standalone "
        "permissions modal, accept the strict turn grant through `r`, route a "
        "later same-turn shell command through guardian review without showing "
        "an ordinary command approval prompt, execute the command, preserve "
        "follow-up context, map request_permissions as tool timeline and the "
        "later shell command as command timeline in `.chat`, retain source "
        "transport, and keep durable original rollout line counts equal to "
        "`.chat` journal line counts. It is not full approval parity."
    )

    write_json(
        output_dir
        / "original"
        / "cli-request-permissions-strict-guardian-shell-response.json",
        original_result,
    )
    write_json(
        output_dir
        / "chat-backend"
        / "cli-request-permissions-strict-guardian-shell-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
