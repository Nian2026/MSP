#!/usr/bin/env python3
"""Run a real CLI resume-picker search parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI picker slice:

    codex exec --json <target prompt>
    codex exec --json <decoy prompt>
    codex resume --include-non-interactive
      type a target-only picker search query
      press Enter to select the filtered target
      send a follow-up prompt in the resumed TUI

The third model request must contain the target thread history and must not
contain the decoy thread history. This proves only a bounded resume-picker
search and selection path; it is not final picker/list/search parity.
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
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
    run_cli_command,
)


TARGET_USER_TEXT = "CLI picker target durable turn."
DECOY_USER_TEXT = "CLI picker decoy durable turn."
FOLLOWUP_USER_TEXT = "CLI picker selected target follow-up."
TARGET_ASSISTANT_TEXT = "CLI picker target answer from mock model."
DECOY_ASSISTANT_TEXT = "CLI picker decoy answer from mock model."
FOLLOWUP_ASSISTANT_TEXT = "CLI picker resumed target answer from mock model."
PICKER_QUERY = "picker target durable"
COMPACT_TARGET_USER_TEXT = re.sub(r"\s+", "", TARGET_USER_TEXT)
COMPACT_DECOY_USER_TEXT = re.sub(r"\s+", "", DECOY_USER_TEXT)
COMPACT_TARGET_ASSISTANT_TEXT = re.sub(r"\s+", "", TARGET_ASSISTANT_TEXT)
COMPACT_FOLLOWUP_USER_TEXT = re.sub(r"\s+", "", FOLLOWUP_USER_TEXT)
COMPACT_FOLLOWUP_ASSISTANT_TEXT = re.sub(r"\s+", "", FOLLOWUP_ASSISTANT_TEXT)

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_lifecycle_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/session_archive_commands.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

ANSI_RE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
TERMINAL_PROBE_RESPONSE = (
    b"\x1b[20;10R"
    b"\x1b]10;rgb:eeee/eeee/eeee\x07"
    b"\x1b]11;rgb:1111/1111/1111\x07"
    b"\x1b[?64;1;2c"
    b"\x1b[?7u"
)


def strip_ansi(text: str) -> str:
    stripped = ANSI_RE.sub("", text).replace("\r", "\n")
    lines = [line.strip() for line in stripped.splitlines()]
    return "\n".join(line for line in lines if line)


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def write_typed_text(master: int, text: str, delay_seconds: float = 0.03) -> None:
    for char in text:
        os.write(master, char.encode("utf-8"))
        time.sleep(delay_seconds)


def mock_request_summary(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    target_body = bodies[0] if len(bodies) > 0 else {}
    decoy_body = bodies[1] if len(bodies) > 1 else {}
    followup_body = bodies[2] if len(bodies) > 2 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "target_body_contains_target_user": body_contains(target_body, TARGET_USER_TEXT),
        "target_body_contains_decoy_user": body_contains(target_body, DECOY_USER_TEXT),
        "decoy_body_contains_decoy_user": body_contains(decoy_body, DECOY_USER_TEXT),
        "decoy_body_contains_target_user": body_contains(decoy_body, TARGET_USER_TEXT),
        "followup_body_contains_target_user": body_contains(followup_body, TARGET_USER_TEXT),
        "followup_body_contains_target_assistant": body_contains(
            followup_body, TARGET_ASSISTANT_TEXT
        ),
        "followup_body_contains_followup_user": body_contains(
            followup_body, FOLLOWUP_USER_TEXT
        ),
        "followup_body_contains_decoy_user": body_contains(followup_body, DECOY_USER_TEXT),
        "followup_body_contains_decoy_assistant": body_contains(
            followup_body, DECOY_ASSISTANT_TEXT
        ),
    }


def storage_summary(tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path) -> dict[str, Any]:
    if tree_name == "chat-backend":
        summary = summarize_chat_packages(chat_root)
        return {
            "package_count": summary.get("package_count"),
            "line_counts": sorted(
                package.get("journal_line_count")
                for package in summary.get("packages", [])
                if package.get("journal_line_count") is not None
            ),
            "summary": summary,
        }
    summary = summarize_original_storage(codex_home)
    rollouts = [
        rollout
        for rollout in summary.get("rollouts", [])
        if (rollout.get("path") or "").startswith(("sessions/", "archived_sessions/"))
    ]
    return {
        "package_count": len(rollouts),
        "line_counts": sorted(
            rollout.get("line_count")
            for rollout in rollouts
            if rollout.get("line_count") is not None
        ),
        "summary": summary,
    }


def run_resume_picker_search_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(["resume", "--include-non-interactive"])

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
    sent_query = False
    sent_followup_text = False
    sent_followup_submit = False
    sent_ctrl_c = False
    query_sent_at: float | None = None
    followup_text_sent_at: float | None = None
    followup_seen_at: float | None = None
    target_seen_before_query = False
    decoy_seen_before_query = False

    try:
        while time.time() - started_at < 70:
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

            visible = output.decode(errors="replace")
            stripped = strip_ansi(visible)
            compact_output = re.sub(r"\s+", "", stripped)
            visible_tail = visible[-1600:]
            compact_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))

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

            if TARGET_USER_TEXT in stripped or COMPACT_TARGET_USER_TEXT in compact_output:
                target_seen_before_query = True
            if DECOY_USER_TEXT in stripped or COMPACT_DECOY_USER_TEXT in compact_output:
                decoy_seen_before_query = True

            if (
                not sent_query
                and target_seen_before_query
                and decoy_seen_before_query
                and len(response_request_bodies(mock_server.requests)) >= 2
            ):
                os.write(master, PICKER_QUERY.encode("utf-8") + b"\r")
                sent_query = True
                query_sent_at = time.time()

            if (
                sent_query
                and not sent_followup_text
                and query_sent_at is not None
                and time.time() - query_sent_at > 1.5
                and (
                    TARGET_ASSISTANT_TEXT in stripped
                    or COMPACT_TARGET_ASSISTANT_TEXT in compact_output
                    or "Pressentertocontinue" in compact_tail
                )
            ):
                write_typed_text(master, FOLLOWUP_USER_TEXT)
                sent_followup_text = True
                followup_text_sent_at = time.time()

            followup_text_visible = (
                FOLLOWUP_USER_TEXT in stripped or COMPACT_FOLLOWUP_USER_TEXT in compact_output
            )
            if (
                sent_followup_text
                and not sent_followup_submit
                and followup_text_sent_at is not None
                and time.time() - followup_text_sent_at > 0.5
                and followup_text_visible
            ):
                os.write(master, b"\r")
                sent_followup_submit = True

            if len(response_request_bodies(mock_server.requests)) >= 3 and followup_seen_at is None:
                followup_seen_at = time.time()

            if (
                followup_seen_at is not None
                and time.time() - followup_seen_at > 2
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

    output_text = output.decode(errors="replace")
    stripped_output = strip_ansi(output_text)
    compact_stripped_output = re.sub(r"\s+", "", stripped_output)
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_query": sent_query,
        "sent_followup_text": sent_followup_text,
        "sent_followup_submit": sent_followup_submit,
        "sent_ctrl_c": sent_ctrl_c,
        "third_response_seen": followup_seen_at is not None,
        "target_seen_before_query": target_seen_before_query,
        "decoy_seen_before_query": decoy_seen_before_query,
        "output_contains_target_user": TARGET_USER_TEXT in stripped_output
        or COMPACT_TARGET_USER_TEXT in compact_stripped_output,
        "output_contains_decoy_user": DECOY_USER_TEXT in stripped_output
        or COMPACT_DECOY_USER_TEXT in compact_stripped_output,
        "output_contains_target_assistant": TARGET_ASSISTANT_TEXT in stripped_output
        or COMPACT_TARGET_ASSISTANT_TEXT in compact_stripped_output,
        "output_contains_followup_assistant": FOLLOWUP_ASSISTANT_TEXT in stripped_output
        or COMPACT_FOLLOWUP_ASSISTANT_TEXT in compact_stripped_output,
        "output_tail_stripped": stripped_output[-3000:],
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

    with SequenceMockResponsesServer(
        [TARGET_ASSISTANT_TEXT, DECOY_ASSISTANT_TEXT, FOLLOWUP_ASSISTANT_TEXT]
    ) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        target_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            TARGET_USER_TEXT,
            resume_last=False,
        )
        decoy_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            DECOY_USER_TEXT,
            resume_last=False,
        )
        before_picker_storage = storage_summary(tree_name, codex_home, chat_root)
        picker_tui = run_resume_picker_search_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        after_picker_storage = storage_summary(tree_name, codex_home, chat_root)
        mock_summary = mock_request_summary(mock_server.requests)

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "target_exec": {
            "exit_code": target_exec["exit_code"],
            "normalized_events": target_exec["normalized_events"],
            "thread_ids": target_exec["thread_ids"],
            "stderr_tail": target_exec["stderr_tail"],
        },
        "decoy_exec": {
            "exit_code": decoy_exec["exit_code"],
            "normalized_events": decoy_exec["normalized_events"],
            "thread_ids": decoy_exec["thread_ids"],
            "stderr_tail": decoy_exec["stderr_tail"],
        },
        "picker_tui": picker_tui,
        "mock_server_summary": mock_summary,
        "before_picker_storage": before_picker_storage,
        "after_picker_storage": after_picker_storage,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "target_exec_exit_code": result["target_exec"]["exit_code"],
        "decoy_exec_exit_code": result["decoy_exec"]["exit_code"],
        "picker_sent_query": result["picker_tui"]["sent_query"],
        "picker_sent_followup_text": result["picker_tui"]["sent_followup_text"],
        "picker_sent_followup_submit": result["picker_tui"]["sent_followup_submit"],
        "picker_third_response_seen": result["picker_tui"]["third_response_seen"],
        "target_seen_before_query": result["picker_tui"]["target_seen_before_query"],
        "decoy_seen_before_query": result["picker_tui"]["decoy_seen_before_query"],
        "mock": result["mock_server_summary"],
        "after_line_counts": result["after_picker_storage"]["line_counts"],
        "after_package_count": result["after_picker_storage"]["package_count"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Resume Picker Search Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final picker/list/search parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Picker search selected target history: `{summary['picker_selected_target_history']}`",
        f"- Picker did not select decoy history: `{summary['picker_excluded_decoy_history']}`",
        f"- Original and `.chat` normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke creates target and decoy `codex exec --json` sessions, opens",
        "`codex resume --include-non-interactive`, types a target-only search",
        "query in the real TUI picker, selects the filtered row, then sends a",
        "follow-up prompt from the resumed TUI.",
        "",
        "## Not Proven",
        "",
    ]
    lines.extend(f"- {item}" for item in summary["not_yet_proven"])
    (output_dir / "report.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-resume-picker-search-smoke-"
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

    original_normalized = normalized_tree_summary(original_result)
    chat_normalized = normalized_tree_summary(chat_result)

    picker_selected_target_history = all(
        [
            original_normalized["mock"]["followup_body_contains_target_user"],
            original_normalized["mock"]["followup_body_contains_target_assistant"],
            original_normalized["mock"]["followup_body_contains_followup_user"],
            chat_normalized["mock"]["followup_body_contains_target_user"],
            chat_normalized["mock"]["followup_body_contains_target_assistant"],
            chat_normalized["mock"]["followup_body_contains_followup_user"],
        ]
    )
    picker_excluded_decoy_history = not any(
        [
            original_normalized["mock"]["followup_body_contains_decoy_user"],
            original_normalized["mock"]["followup_body_contains_decoy_assistant"],
            chat_normalized["mock"]["followup_body_contains_decoy_user"],
            chat_normalized["mock"]["followup_body_contains_decoy_assistant"],
        ]
    )
    durable_line_counts_equal = (
        original_normalized["after_line_counts"] == chat_normalized["after_line_counts"]
        and original_normalized["after_package_count"] == chat_normalized["after_package_count"] == 2
    )

    normalized_summaries_equal = original_normalized == chat_normalized
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-resume-picker-search-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "picker_selected_target_history": picker_selected_target_history,
        "picker_excluded_decoy_history": picker_excluded_decoy_history,
        "durable_line_counts_equal": durable_line_counts_equal,
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI resume picker search slice: "
            "`codex resume --include-non-interactive` can load exec-created "
            "sessions into the real picker, typed search can select the target "
            "session rather than a decoy, and the resumed TUI follow-up model "
            "request preserves the target history while excluding decoy history "
            "for both original and .chat backends."
        ),
        "not_yet_proven": [
            "full visual picker parity across viewport sizes",
            "picker pagination beyond two loaded rows",
            "picker transcript preview expansion",
            "fork picker search parity",
            "archive/delete descendant ordering",
            "running-thread picker/rejoin parity",
            "complete CLI feature parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }

    summary["passed"] = all(
        [
            normalized_summaries_equal,
            picker_selected_target_history,
            picker_excluded_decoy_history,
            durable_line_counts_equal,
        ]
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    write_markdown_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
