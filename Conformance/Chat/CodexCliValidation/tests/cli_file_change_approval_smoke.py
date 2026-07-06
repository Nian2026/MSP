#!/usr/bin/env python3
"""Run real CLI/TUI file-change approval parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type a prompt that triggers an intercepted apply_patch file change
    press the TUI approval shortcut to accept the edits
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

from app_server_command_approval_smoke import ev_final_message  # noqa: E402
from app_server_command_approval_smoke import write_approval_config  # noqa: E402
from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS  # noqa: E402
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS  # noqa: E402
from app_server_durable_turn_smoke import ensure_binary  # noqa: E402
from app_server_durable_turn_smoke import summarize_chat_packages  # noqa: E402
from app_server_durable_turn_smoke import summarize_original_storage  # noqa: E402
from app_server_durable_turn_smoke import utc_now_iso  # noqa: E402
from app_server_durable_turn_smoke import write_json  # noqa: E402
from app_server_file_change_approval_smoke import SCENARIOS  # noqa: E402
from app_server_file_change_approval_smoke import FileChangeResponsesServer  # noqa: E402
from app_server_file_change_approval_smoke import summarize_file_change_chat_timeline  # noqa: E402
from app_server_file_change_approval_smoke import summarize_file_change_original_rollouts  # noqa: E402
from cli_command_approval_smoke import durable_line_counts  # noqa: E402
from cli_exec_resume_smoke import normalize_exec_events  # noqa: E402
from cli_exec_resume_smoke import response_request_bodies  # noqa: E402
from cli_exec_resume_smoke import run_cli_command  # noqa: E402
from cli_rollback_smoke import TERMINAL_PROBE_RESPONSE  # noqa: E402
from cli_rollback_smoke import strip_ansi  # noqa: E402
from cli_rollback_smoke import type_prompt_and_enter  # noqa: E402


ACCEPT_SCENARIO = next(scenario for scenario in SCENARIOS if scenario.name == "accept")
ACCEPT_TURN = ACCEPT_SCENARIO.turns[0]
FOLLOWUP_USER_TEXT = "CLI file change approval follow-up after accepted patch."
FOLLOWUP_ASSISTANT_TEXT = "CLI file change approval follow-up answer from mock model."
FILE_CHANGE_APPROVAL_IDLE_SECONDS = 1.8

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
    "Conformance/Chat/CodexCliValidation/tests/cli_command_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_file_change_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/bottom_pane/approval_overlay.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/protocol_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/tool_requests.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class CliFileChangeResponsesServer(FileChangeResponsesServer):
    def __init__(self) -> None:
        super().__init__(ACCEPT_SCENARIO)
        self.responses.append(
            ev_final_message(
                "resp-cli-file-change-followup",
                "msg-cli-file-change-followup",
                FOLLOWUP_ASSISTANT_TEXT,
            )
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
        "first_body_contains_user_text": body_contains(first_body, ACCEPT_TURN.user_text),
        "first_body_contains_patch_text": serialized_contains(first_body, "*** Add File: README.md"),
        "second_body_contains_function_output": (
            serialized_contains(second_body, ACCEPT_TURN.call_id)
            and serialized_contains(second_body, "function_call_output")
        ),
        "second_body_contains_patch_applied": serialized_contains(second_body, "new line"),
        "third_body_contains_followup_user_text": body_contains(third_body, FOLLOWUP_USER_TEXT),
        "third_body_contains_original_user_text": body_contains(third_body, ACCEPT_TURN.user_text),
        "third_body_contains_first_final_text": body_contains(third_body, ACCEPT_TURN.final_text),
        "third_body_contains_patch_output": serialized_contains(third_body, ACCEPT_TURN.call_id)
        and serialized_contains(third_body, "function_call_output"),
    }


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def run_cli_file_change_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: CliFileChangeResponsesServer,
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
    sent_prompt = False
    prompt_sent_at: float | None = None
    prompt_enter_retry_sent = False
    file_change_approval_visible_at: float | None = None
    sent_file_change_accept = False
    final_answer_visible_at: float | None = None
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
                type_prompt_and_enter(master, ACCEPT_TURN.user_text)
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

            file_change_approval_visible = (
                "Wouldyouliketomakethefollowingedits?" in compact_tail
                or ("README.md" in stripped_tail and "Yes, proceed" in stripped_tail)
            )
            if file_change_approval_visible and file_change_approval_visible_at is None:
                file_change_approval_visible_at = time.time()

            if (
                file_change_approval_visible_at is not None
                and not sent_file_change_accept
                and time.time() - file_change_approval_visible_at
                >= FILE_CHANGE_APPROVAL_IDLE_SECONDS
            ):
                os.write(master, b"y")
                sent_file_change_accept = True

            if ACCEPT_TURN.final_text in decoded_output and final_answer_visible_at is None:
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
        "file_change_approval_prompt_visible": file_change_approval_visible_at is not None,
        "sent_file_change_accept": sent_file_change_accept,
        "final_answer_visible": final_answer_visible_at is not None,
        "sent_ctrl_c": sent_ctrl_c,
        "response_request_count_after_tui": response_request_count(mock_server.requests),
        "output_tail_stripped": stripped_output[-3600:],
        "raw_output_bytes": len(output),
    }


def original_has_file_change_persisted(result: dict[str, Any]) -> bool:
    rollouts = result["original_file_change_rollout_summary"].get("rollouts") or []
    return any(
        ACCEPT_TURN.call_id in rollout.get("function_call_call_ids", [])
        and ACCEPT_TURN.call_id in rollout.get("function_call_output_call_ids", [])
        and rollout.get("contains_all_patch_calls")
        for rollout in rollouts
    )


def chat_backend_has_file_change_timeline(result: dict[str, Any]) -> bool:
    packages = result["chat_file_change_timeline_summary"].get("packages") or []
    return any(
        package.get("timeline_tool_call_count", 0) >= 1
        and package.get("timeline_tool_output_count", 0) >= 1
        and package.get("timeline_command_call_count") == 0
        and package.get("timeline_command_output_count") == 0
        and package.get("journal_shell_apply_patch_call_count", 0) >= 1
        and ACCEPT_TURN.call_id in package.get("journal_function_output_call_ids", [])
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
    chat_root = run_root / tree_name / "chat-store"
    readme_path = workspace / "README.md"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with CliFileChangeResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        file_change_tui = run_cli_file_change_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        readme_after_tui = readme_path.read_text() if readme_path.exists() else None
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
        "file_change_tui": file_change_tui,
        "readme_after_tui": readme_after_tui,
        "followup_exec": followup_exec,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "after_tui_storage": after_tui_storage,
        "final_storage": final_storage,
        "after_tui_line_counts": durable_line_counts(after_tui_storage, tree_name),
        "final_line_counts": durable_line_counts(final_storage, tree_name),
    }
    if tree_name == "chat-backend":
        result["chat_file_change_timeline_summary"] = summarize_file_change_chat_timeline(
            chat_root,
            [ACCEPT_TURN.call_id],
        )
    else:
        result["original_file_change_rollout_summary"] = summarize_file_change_original_rollouts(
            codex_home,
            [ACCEPT_TURN.call_id],
        )
    return result


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI File Change Approval Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow real CLI/TUI file-change approval smoke. It drives an",
        "intercepted `apply_patch` transport call, accepts the visible edit",
        "approval prompt, and then resumes the thread through `codex exec --json`.",
        "",
        "It does not prove decline, AcceptForSession, freeform apply_patch,",
        "network approval, additional-permission approval, crash recovery, or final",
        "user-indistinguishability.",
        "",
        "## Result",
        "",
        f"- passed: `{summary['passed']}`",
        f"- original TUI reached file-change approval: `{summary['original_tui_reached_file_change_approval']}`",
        f"- `.chat` TUI reached file-change approval: `{summary['chat_backend_tui_reached_file_change_approval']}`",
        f"- workspace patch contents equal: `{summary['workspace_patch_contents_equal']}`",
        f"- normalized follow-up CLI output equal: `{summary['normalized_followup_exec_equal']}`",
        f"- mock request summaries equal: `{summary['mock_request_summaries_equal']}`",
        f"- durable line counts equal: `{summary['final_durable_line_counts_equal']}`",
        f"- `.chat` package has file-change timeline/source transport: `{summary['chat_backend_has_file_change_timeline']}`",
        "",
        "## Evidence",
        "",
        "- `summary.json`",
        "- `original/cli-file-change-approval-response.json`",
        "- `chat-backend/cli-file-change-approval-response.json`",
        "",
    ]
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-file-change-approval-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        "scope": "cli-file-change-approval-smoke",
        "matrix_slice": ["T06-file-change-adjacent", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_reached_file_change_approval": original_result["file_change_tui"][
            "file_change_approval_prompt_visible"
        ],
        "chat_backend_tui_reached_file_change_approval": chat_result["file_change_tui"][
            "file_change_approval_prompt_visible"
        ],
        "original_tui_sent_file_change_accept": original_result["file_change_tui"][
            "sent_file_change_accept"
        ],
        "chat_backend_tui_sent_file_change_accept": chat_result["file_change_tui"][
            "sent_file_change_accept"
        ],
        "original_tui_final_visible": original_result["file_change_tui"][
            "final_answer_visible"
        ],
        "chat_backend_tui_final_visible": chat_result["file_change_tui"][
            "final_answer_visible"
        ],
        "tui_response_request_counts_equal_after_file_change": (
            original_result["file_change_tui"]["response_request_count_after_tui"]
            == chat_result["file_change_tui"]["response_request_count_after_tui"]
            == 2
        ),
        "workspace_patch_contents_equal": (
            original_result["readme_after_tui"]
            == chat_result["readme_after_tui"]
            == ACCEPT_SCENARIO.expected_readme_contents
        ),
        "followup_exec_exit_ok": (
            original_followup["exit_code"] == chat_followup["exit_code"] == 0
        ),
        "normalized_followup_exec_equal": (
            normalize_exec_events(original_followup["events"])
            == normalize_exec_events(chat_followup["events"])
        ),
        "mock_request_summaries_equal": original_mock == chat_mock,
        "mock_file_change_output_round_trip": (
            original_mock["second_body_contains_function_output"]
            and chat_mock["second_body_contains_function_output"]
            and original_mock["second_body_contains_patch_applied"]
            and chat_mock["second_body_contains_patch_applied"]
        ),
        "followup_context_preserved_after_file_change": (
            original_mock["third_body_contains_original_user_text"]
            and chat_mock["third_body_contains_original_user_text"]
            and original_mock["third_body_contains_patch_output"]
            and chat_mock["third_body_contains_patch_output"]
            and original_mock["third_body_contains_first_final_text"]
            and chat_mock["third_body_contains_first_final_text"]
        ),
        "original_has_file_change_persisted": original_has_file_change_persisted(
            original_result
        ),
        "chat_backend_has_file_change_timeline": chat_backend_has_file_change_timeline(
            chat_result
        ),
        "original_final_line_counts": original_lines,
        "chat_backend_final_line_counts": chat_lines,
        "final_durable_line_counts_equal": original_lines == chat_lines and bool(original_lines),
        "original": {
            "file_change_tui": original_result["file_change_tui"],
            "readme_after_tui": original_result["readme_after_tui"],
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
            "file_change_tui": chat_result["file_change_tui"],
            "readme_after_tui": chat_result["readme_after_tui"],
            "followup_exec": {
                "command": chat_followup["command"],
                "exit_code": chat_followup["exit_code"],
                "normalized_events": normalize_exec_events(chat_followup["events"]),
                "stderr_tail": chat_followup["stderr_tail"],
            },
            "mock_server_summary": chat_mock,
            "final_line_counts": chat_lines,
            "chat_file_change_timeline_summary": chat_result[
                "chat_file_change_timeline_summary"
            ],
        },
        "not_yet_proven": [
            "CLI file-change decline path",
            "CLI file-change AcceptForSession cache behavior",
            "freeform apply_patch transport through CLI/TUI",
            "network approval through CLI/TUI",
            "additional-permission approval through CLI/TUI",
            "approval process-kill or crash recovery",
            "complete T06 file-change data fidelity",
            "final user-indistinguishability",
        ],
    }

    passed = all(
        [
            summary["original_tui_reached_file_change_approval"],
            summary["chat_backend_tui_reached_file_change_approval"],
            summary["original_tui_sent_file_change_accept"],
            summary["chat_backend_tui_sent_file_change_accept"],
            summary["original_tui_final_visible"],
            summary["chat_backend_tui_final_visible"],
            summary["tui_response_request_counts_equal_after_file_change"],
            summary["workspace_patch_contents_equal"],
            summary["followup_exec_exit_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["mock_file_change_output_round_trip"],
            summary["followup_context_preserved_after_file_change"],
            summary["original_has_file_change_persisted"],
            summary["chat_backend_has_file_change_timeline"],
            summary["final_durable_line_counts_equal"],
        ]
    )
    summary["passed"] = passed
    summary["claim"] = (
        "This proves a narrow user-facing CLI/TUI file-change approval accept "
        "slice: both backends show the apply_patch edit approval path, accept "
        "the edit through the TUI shortcut, apply the same workspace patch, "
        "round-trip the file-change result to the model, preserve follow-up "
        "resume context, and keep durable original rollout line counts equal "
        "to `.chat` journal line counts. It is not full file-change approval "
        "parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/cli-file-change-approval-response.json", original_result)
    write_json(output_dir / "chat-backend/cli-file-change-approval-response.json", chat_result)
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
