#!/usr/bin/env python3
"""Run a real CLI resume-picker preview-expansion parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI picker slice:

    codex exec --json <target prompt>
    codex exec --json <decoy prompt>
    codex resume --include-non-interactive
      type a target-only picker search query
      press Ctrl+E to expand the selected row
      wait for recent transcript preview metadata/content
      press Enter to select the target
      send a follow-up prompt in the resumed TUI

The preview must expose selected-session metadata and target transcript content
in both the original backend and the `.chat` backend. The follow-up request must
still contain the target history and exclude the decoy history. This proves only
a bounded resume-picker preview expansion path; it is not final picker/list/search
parity or final user-indistinguishability evidence.
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
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
    run_cli_command,
)
from cli_resume_picker_search_smoke import (  # noqa: E402
    COMPACT_DECOY_USER_TEXT,
    COMPACT_FOLLOWUP_ASSISTANT_TEXT,
    COMPACT_FOLLOWUP_USER_TEXT,
    COMPACT_TARGET_ASSISTANT_TEXT,
    COMPACT_TARGET_USER_TEXT,
    DECOY_ASSISTANT_TEXT,
    DECOY_USER_TEXT,
    FOLLOWUP_ASSISTANT_TEXT,
    FOLLOWUP_USER_TEXT,
    PICKER_QUERY,
    TARGET_ASSISTANT_TEXT,
    TARGET_USER_TEXT,
    TERMINAL_PROBE_RESPONSE,
    mock_request_summary,
    storage_summary,
    strip_ansi,
    write_typed_text,
)


GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_search_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def run_resume_picker_preview_tui(
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

        winsize = struct.pack("HHHH", 36, 128, 0, 0)
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
    exit_code: int | None = None
    sent_probe_response = False
    sent_trust_answer = False
    sent_query_text = False
    sent_expand = False
    sent_accept = False
    sent_followup_text = False
    sent_followup_submit = False
    sent_ctrl_c = False
    query_sent_at: float | None = None
    expand_sent_at: float | None = None
    accept_sent_at: float | None = None
    followup_text_sent_at: float | None = None
    followup_seen_at: float | None = None
    target_seen_before_query = False
    decoy_seen_before_query = False
    preview_metadata_seen = False
    preview_loading_seen = False
    preview_target_user_seen = False
    preview_target_assistant_seen = False

    try:
        while time.time() - started_at < 80:
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
            compact_output = compact(stripped)
            visible_tail = visible[-2000:]
            compact_tail = compact(strip_ansi(visible_tail))

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
                not sent_query_text
                and target_seen_before_query
                and decoy_seen_before_query
                and len(response_request_bodies(mock_server.requests)) >= 2
            ):
                write_typed_text(master, PICKER_QUERY)
                sent_query_text = True
                query_sent_at = time.time()

            if (
                sent_query_text
                and not sent_expand
                and query_sent_at is not None
                and time.time() - query_sent_at > 1.5
                and "Search:" in stripped
            ):
                os.write(master, b"\x05")
                sent_expand = True
                expand_sent_at = time.time()

            if sent_expand:
                metadata_tokens = ["Session:", "Created:", "Updated:", "Directory:", "Conversation:"]
                preview_metadata_seen = preview_metadata_seen or all(
                    token in stripped for token in metadata_tokens
                )
                preview_loading_seen = preview_loading_seen or (
                    "Loading recent transcript" in stripped
                    or "Loadingrecenttranscript" in compact_output
                )
                preview_target_user_seen = preview_target_user_seen or (
                    TARGET_USER_TEXT in stripped or COMPACT_TARGET_USER_TEXT in compact_output
                )
                preview_target_assistant_seen = preview_target_assistant_seen or (
                    TARGET_ASSISTANT_TEXT in stripped
                    or COMPACT_TARGET_ASSISTANT_TEXT in compact_output
                )

            if (
                sent_expand
                and not sent_accept
                and expand_sent_at is not None
                and time.time() - expand_sent_at > 0.8
                and preview_metadata_seen
                and preview_target_assistant_seen
            ):
                os.write(master, b"\r")
                sent_accept = True
                accept_sent_at = time.time()

            if (
                sent_accept
                and not sent_followup_text
                and accept_sent_at is not None
                and time.time() - accept_sent_at > 1.5
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
    compact_stripped_output = compact(stripped_output)
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_query_text": sent_query_text,
        "sent_expand": sent_expand,
        "sent_accept": sent_accept,
        "sent_followup_text": sent_followup_text,
        "sent_followup_submit": sent_followup_submit,
        "sent_ctrl_c": sent_ctrl_c,
        "third_response_seen": followup_seen_at is not None,
        "target_seen_before_query": target_seen_before_query,
        "decoy_seen_before_query": decoy_seen_before_query,
        "preview_metadata_seen": preview_metadata_seen,
        "preview_loading_seen": preview_loading_seen,
        "preview_target_user_seen": preview_target_user_seen,
        "preview_target_assistant_seen": preview_target_assistant_seen,
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
        picker_tui = run_resume_picker_preview_tui(
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
    picker = result["picker_tui"]
    return {
        "target_exec_exit_code": result["target_exec"]["exit_code"],
        "decoy_exec_exit_code": result["decoy_exec"]["exit_code"],
        "picker_sent_query_text": picker["sent_query_text"],
        "picker_sent_expand": picker["sent_expand"],
        "picker_sent_accept": picker["sent_accept"],
        "picker_preview_metadata_seen": picker["preview_metadata_seen"],
        "picker_preview_loading_seen": picker["preview_loading_seen"],
        "picker_preview_target_user_seen": picker["preview_target_user_seen"],
        "picker_preview_target_assistant_seen": picker["preview_target_assistant_seen"],
        "picker_sent_followup_text": picker["sent_followup_text"],
        "picker_sent_followup_submit": picker["sent_followup_submit"],
        "picker_third_response_seen": picker["third_response_seen"],
        "target_seen_before_query": picker["target_seen_before_query"],
        "decoy_seen_before_query": picker["decoy_seen_before_query"],
        "mock": result["mock_server_summary"],
        "after_line_counts": result["after_picker_storage"]["line_counts"],
        "after_package_count": result["after_picker_storage"]["package_count"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Resume Picker Preview Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final picker/list/search parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Picker preview showed selected-session metadata: `{summary['picker_preview_metadata_seen']}`",
        f"- Picker preview showed target transcript content: `{summary['picker_preview_target_transcript_seen']}`",
        f"- Picker preview path preserved target history after selection: `{summary['picker_selected_target_history']}`",
        f"- Picker preview path excluded decoy history after selection: `{summary['picker_excluded_decoy_history']}`",
        f"- Original and `.chat` normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke creates target and decoy `codex exec --json` sessions, opens",
        "`codex resume --include-non-interactive`, types a target-only search",
        "query in the real TUI picker, expands the selected row with Ctrl+E,",
        "waits for selected-session metadata and recent transcript preview,",
        "then selects the row and sends a follow-up prompt from the resumed TUI.",
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
            "cli-resume-picker-preview-smoke-"
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

    picker_preview_metadata_seen = all(
        [
            original_normalized["picker_preview_metadata_seen"],
            chat_normalized["picker_preview_metadata_seen"],
        ]
    )
    picker_preview_target_transcript_seen = all(
        [
            original_normalized["picker_preview_target_user_seen"],
            original_normalized["picker_preview_target_assistant_seen"],
            chat_normalized["picker_preview_target_user_seen"],
            chat_normalized["picker_preview_target_assistant_seen"],
        ]
    )
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
        "scope": "cli-resume-picker-preview-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "picker_preview_metadata_seen": picker_preview_metadata_seen,
        "picker_preview_target_transcript_seen": picker_preview_target_transcript_seen,
        "picker_selected_target_history": picker_selected_target_history,
        "picker_excluded_decoy_history": picker_excluded_decoy_history,
        "durable_line_counts_equal": durable_line_counts_equal,
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI resume picker preview slice: "
            "`codex resume --include-non-interactive` can load exec-created "
            "sessions into the real picker, typed search can focus the target "
            "session, Ctrl+E can expand that selected row and render selected "
            "metadata plus recent transcript content, and the resumed TUI "
            "follow-up model request preserves target history while excluding "
            "decoy history for both original and .chat backends."
        ),
        "not_yet_proven": [
            "full visual picker parity across viewport sizes",
            "picker pagination beyond two loaded rows",
            "full transcript overlay parity via Ctrl+T",
            "fork picker search or preview parity",
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
            picker_preview_metadata_seen,
            picker_preview_target_transcript_seen,
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
