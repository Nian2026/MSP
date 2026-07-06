#!/usr/bin/env python3
"""Run a real CLI/TUI `/compact` parity smoke.

This source-backed validation uses ordinary user-facing Codex CLI entry points:

    codex exec --json ...
    codex resume --last
    type /compact into the TUI
    codex exec --json resume --last ...

The middle command enters the interactive TUI, so the test drives it through a
PTY and waits for the mock Responses API to receive the compaction request.
This proves only a narrow CLI K02 and K03-adjacent slice; it is not a final
compaction or user-indistinguishability claim.
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

from app_server_compaction_smoke import (  # noqa: E402
    COMPACTION_SUMMARY_SUFFIX,
    FIRST_ASSISTANT_TEXT,
    FIRST_USER_TEXT,
    FOLLOWUP_ASSISTANT_TEXT,
    FOLLOWUP_USER_TEXT,
    SUMMARY_PREFIX,
    CompactionMockResponsesServer,
    chat_compaction_summary,
    original_compaction_summary,
    summarize_mock_requests,
    write_compaction_mock_config,
)
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
from cli_exec_resume_smoke import (  # noqa: E402
    normalize_exec_events,
    run_cli_command,
)


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
    "Conformance/Chat/CodexCliValidation/tests/app_server_compaction_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/slash_command.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/slash_dispatch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_server_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/chatwidget/slash_dispatch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/app-server/src/request_processors/thread_processor.rs",
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
    stripped = ANSI_RE.sub("", text)
    stripped = stripped.replace("\r", "\n")
    lines = [line.strip() for line in stripped.splitlines()]
    return "\n".join(line for line in lines if line)


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(
        1 for request in requests if request.get("path", "").endswith("/responses")
    )


def run_cli_compact_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: CompactionMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(["resume", "--last"])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    master, slave = pty.openpty()
    try:
        import fcntl
        import termios

        winsize = struct.pack("HHHH", 30, 100, 0, 0)
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
    sent_compact_command = False
    sent_ctrl_c = False
    compaction_request_seen_at: float | None = None

    try:
        while time.time() - started_at < 60:
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

            visible_tail = output.decode(errors="replace")[-1600:]
            compact_visible_tail = re.sub(r"\s+", "", strip_ansi(visible_tail))
            if not sent_probe_response and (
                "\x1b[6n" in visible_tail
                or "]10;?" in visible_tail
                or "[?u" in visible_tail
            ):
                os.write(master, TERMINAL_PROBE_RESPONSE)
                sent_probe_response = True
            if (
                not sent_trust_answer
                and "Doyoutrustthecontentsofthisdirectory?" in compact_visible_tail
            ):
                os.write(master, b"1\r\r")
                sent_trust_answer = True
                sent_trust_continue = True
            if (
                sent_trust_answer
                and not sent_trust_continue
                and "Pressentertocontinue" in compact_visible_tail
            ):
                os.write(master, b"\r")
                sent_trust_continue = True
            if "Continue anyway?" in visible_tail and not sent_term_gate_answer:
                os.write(master, b"y\r")
                sent_term_gate_answer = True
            if (
                not sent_compact_command
                and "OpenAICodex" in compact_visible_tail
                and (
                    sent_trust_continue
                    or (
                        not "Doyoutrustthecontentsofthisdirectory?"
                        in compact_visible_tail
                        and time.time() - started_at > 2
                    )
                )
            ):
                os.write(master, b"/compact\r")
                sent_compact_command = True

            if response_request_count(mock_server.requests) >= 2:
                if compaction_request_seen_at is None:
                    compaction_request_seen_at = time.time()
                if time.time() - compaction_request_seen_at > 5 and not sent_ctrl_c:
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
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_compact_command": sent_compact_command,
        "sent_ctrl_c": sent_ctrl_c,
        "compaction_request_seen": compaction_request_seen_at is not None,
        "output_tail_stripped": stripped_output[-3000:],
        "raw_output_bytes": len(output),
    }


def chat_package_observation(chat_root: pathlib.Path) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    packages = summary.get("packages") or []
    if not packages:
        return {
            "package_count": 0,
            "journal_line_counts": [],
            "timeline_line_counts": [],
            "all_packages_have_standard_projections": False,
        }
    package_details = []
    package = pathlib.Path(packages[0]["package"])
    for package_item in packages:
        package = pathlib.Path(package_item["package"])
        projections = sorted(
            item.relative_to(package).as_posix()
            for item in (package / "projections").glob("*.ndjson")
        )
        timeline = read_json_lines(package / "timeline.ndjson")
        journal = read_json_lines(package / "journal.ndjson")
        package_details.append(
            {
                "conversation_id": package_item.get("conversation_id"),
                "package": str(package),
                "projection_files": projections,
                "has_standard_projections": all(
                    projection in projections
                    for projection in [
                        "projections/chat-read.ndjson",
                        "projections/model-context.ndjson",
                        "projections/audit.ndjson",
                    ]
                ),
                "journal_line_count": len(journal),
                "timeline_line_count": len(timeline),
                "timeline_event_types": [event.get("type") for event in timeline],
            }
        )
    return {
        "package_count": len(packages),
        "packages": package_details,
        "journal_line_counts": sorted(item["journal_line_count"] for item in package_details),
        "timeline_line_counts": sorted(item["timeline_line_count"] for item in package_details),
        "all_packages_have_standard_projections": all(
            item["has_standard_projections"] for item in package_details
        ),
    }


def original_session_rollouts(summary: dict[str, Any]) -> list[dict[str, Any]]:
    rollouts = summary.get("rollouts") or []
    return [
        item
        for item in rollouts
        if (item.get("path") or "").startswith("sessions/")
        and (item.get("path") or "").endswith(".jsonl")
    ]


def original_line_counts(summary: dict[str, Any]) -> list[int]:
    return sorted(
        item.get("line_count") or 0 for item in original_session_rollouts(summary)
    )


def original_cli_compaction_summary(summary: dict[str, Any]) -> dict[str, Any]:
    codex_home = pathlib.Path(summary["codex_home"])
    compacted = []
    all_lines = []
    for rollout in original_session_rollouts(summary):
        lines = read_json_lines(codex_home / rollout["path"])
        all_lines.extend(lines)
        compacted.extend(line for line in lines if line.get("type") == "compacted")
    serialized = json.dumps(compacted, ensure_ascii=False)
    replacement_history_counts = [
        len(((line.get("payload") or {}).get("replacement_history") or []))
        for line in compacted
    ]
    return {
        "session_rollout_count": len(original_session_rollouts(summary)),
        "session_rollout_line_counts": original_line_counts(summary),
        "total_session_rollout_lines": len(all_lines),
        "compacted_count": len(compacted),
        "has_replacement_history": any(count > 0 for count in replacement_history_counts),
        "replacement_history_counts": replacement_history_counts,
        "contains_compaction_summary": COMPACTION_SUMMARY_SUFFIX in serialized,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
    }


def chat_cli_compaction_summary(summary: dict[str, Any]) -> dict[str, Any]:
    packages = summary.get("packages") or []
    timeline_compaction = []
    journal_compaction = []
    timeline_line_counts = []
    journal_line_counts = []
    journal_texts = []
    for package_item in packages:
        package = pathlib.Path(package_item["package"])
        timeline = read_json_lines(package / "timeline.ndjson")
        journal = read_json_lines(package / "journal.ndjson")
        timeline_line_counts.append(len(timeline))
        journal_line_counts.append(len(journal))
        timeline_compaction.extend(
            line for line in timeline if line.get("type") == "durable_compaction_checkpoint"
        )
        journal_compaction.extend(
            line
            for line in journal
            if ((line.get("source_transport") or {}).get("payload") or {}).get("type")
            == "compacted"
        )
        journal_texts.append(json.dumps(journal, ensure_ascii=False))
    journal_serialized = "\n".join(journal_texts)
    return {
        "package_count": len(packages),
        "timeline_line_counts": sorted(timeline_line_counts),
        "journal_line_counts": sorted(journal_line_counts),
        "timeline_compaction_event_count": len(timeline_compaction),
        "journal_compaction_event_count": len(journal_compaction),
        "has_replacement_history": "replacement_history" in journal_serialized,
        "contains_compaction_summary": COMPACTION_SUMMARY_SUFFIX in journal_serialized,
        "contains_first_user_text": FIRST_USER_TEXT in journal_serialized,
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

    with CompactionMockResponsesServer() as mock_server:
        write_compaction_mock_config(codex_home, mock_server.url)
        first_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FIRST_USER_TEXT,
            resume_last=False,
        )
        compact_tui = run_cli_compact_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        followup_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_last=True,
        )

        storage_summary = (
            summarize_chat_packages(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        compaction_storage = (
            chat_cli_compaction_summary(storage_summary)
            if tree_name == "chat-backend"
            else original_cli_compaction_summary(storage_summary)
        )

        return {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "first_exec": first_exec,
            "compact_tui": compact_tui,
            "followup_exec": followup_exec,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "storage_summary": storage_summary,
            "compaction_storage": compaction_storage,
            "chat_package_summary": chat_package_observation(chat_root)
            if tree_name == "chat-backend"
            else None,
            "original_line_counts": original_line_counts(storage_summary)
            if tree_name == "original"
            else None,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-compaction-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_result = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_compaction = original_result["compaction_storage"]
    chat_compaction = chat_result["compaction_storage"]
    chat_package = chat_result["chat_package_summary"] or {}

    original_first_events = original_result["first_exec"].get("events") or []
    chat_first_events = chat_result["first_exec"].get("events") or []
    original_followup_events = original_result["followup_exec"].get("events") or []
    chat_followup_events = chat_result["followup_exec"].get("events") or []

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-compaction-smoke",
        "matrix_slice": ["K02", "K03-adjacent"],
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_first_exec_ok": original_result["first_exec"].get("exit_code") == 0,
        "chat_backend_first_exec_ok": chat_result["first_exec"].get("exit_code") == 0,
        "original_compact_tui_exit_ok": original_result["compact_tui"].get("exit_code")
        == 0,
        "chat_backend_compact_tui_exit_ok": chat_result["compact_tui"].get("exit_code")
        == 0,
        "original_compaction_request_seen": original_result["compact_tui"].get(
            "compaction_request_seen"
        ),
        "chat_backend_compaction_request_seen": chat_result["compact_tui"].get(
            "compaction_request_seen"
        ),
        "original_compact_command_sent": original_result["compact_tui"].get(
            "sent_compact_command"
        ),
        "chat_backend_compact_command_sent": chat_result["compact_tui"].get(
            "sent_compact_command"
        ),
        "original_followup_exec_ok": original_result["followup_exec"].get("exit_code")
        == 0,
        "chat_backend_followup_exec_ok": chat_result["followup_exec"].get("exit_code")
        == 0,
        "normalized_first_exec_equal": normalize_exec_events(original_first_events)
        == normalize_exec_events(chat_first_events),
        "normalized_followup_exec_equal": normalize_exec_events(original_followup_events)
        == normalize_exec_events(chat_followup_events),
        "mock_response_request_counts_equal": original_mock["response_request_count"]
        == chat_mock["response_request_count"],
        "mock_context_markers_equal": original_mock == chat_mock,
        "mock_compaction_context_ok": all(
            [
                original_mock == chat_mock,
                original_mock["response_request_count"] >= 3,
                original_mock["any_middle_response_contains_prompt"],
                chat_mock["any_middle_response_contains_prompt"],
                original_mock["followup_response_contains_first_user_text"],
                chat_mock["followup_response_contains_first_user_text"],
                original_mock["followup_response_contains_first_assistant_text"],
                chat_mock["followup_response_contains_first_assistant_text"],
                original_mock["followup_response_contains_followup_user_text"],
                chat_mock["followup_response_contains_followup_user_text"],
            ]
        ),
        "original_compaction_storage_ok": all(
            [
                original_compaction["compacted_count"] >= 1,
                original_compaction["has_replacement_history"],
                original_compaction["contains_compaction_summary"],
            ]
        ),
        "chat_backend_compaction_storage_ok": all(
            [
                chat_compaction["timeline_compaction_event_count"] >= 1,
                chat_compaction["journal_compaction_event_count"] >= 1,
                chat_compaction["has_replacement_history"],
                chat_compaction["contains_compaction_summary"],
            ]
        ),
        "chat_backend_standard_projections_ok": chat_package.get(
            "all_packages_have_standard_projections"
        ),
        "original_rollout_line_counts": original_result.get("original_line_counts"),
        "chat_backend_journal_line_counts": chat_package.get("journal_line_counts"),
        "durable_line_counts_equal": original_result.get("original_line_counts")
        == chat_package.get("journal_line_counts"),
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_compaction_summary": original_compaction,
        "chat_backend_compaction_summary": chat_compaction,
        "original_compact_tui": original_result["compact_tui"],
        "chat_backend_compact_tui": chat_result["compact_tui"],
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "automatic compaction K01 through CLI",
            "compact-summary-as-resume-baseline behavior through CLI",
            "world state full/patch K04 through CLI",
            "legacy compaction fallback K05",
            "rollback after compaction RB05 through CLI",
            "full context-window lineage parity",
            "process-kill compaction recovery",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/cli-compaction-response.json", original_result)
    write_json(output_dir / "chat-backend/cli-compaction-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# CLI Compaction Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives user-facing CLI/TUI paths and a local mock Responses API.

## Gate

Before this work, the public `.chat` spec files, formal spec
drafts, vendor manifest, baseline checks, backend mapping, parity matrix,
current data-fidelity files, and relevant vendored CLI/TUI compaction source
were read.

## Scope

This smoke covers a narrow CLI K02 and K03-adjacent slice:

- complete one durable turn with `codex exec --json`;
- trigger manual compaction through `codex resume --last /compact`;
- wait for the real interactive TUI path to reach the mock Responses API;
- run a follow-up `codex exec --json resume --last`;
- verify the follow-up model context behavior and durable compaction storage
  match the unmodified original backend.

It is not a complete compaction proof. In this CLI/TUI path, original Codex
materializes a separate compact summary thread and the follow-up resume request
does not include the compact summary; the `.chat` backend must match that
behavior rather than idealize it. This smoke does not cover automatic
compaction, compact-summary-as-resume-baseline behavior, world-state full/patch
restore, legacy compaction fallback, rollback after compaction, crash recovery,
performance, complete data fidelity, or final user-indistinguishability.

## Result

- original first CLI turn succeeded: `{summary['original_first_exec_ok']}`
- `.chat` first CLI turn succeeded: `{summary['chat_backend_first_exec_ok']}`
- original TUI `/compact` exited cleanly: `{summary['original_compact_tui_exit_ok']}`
- `.chat` TUI `/compact` exited cleanly: `{summary['chat_backend_compact_tui_exit_ok']}`
- original PTY sent slash command: `{summary['original_compact_command_sent']}`
- `.chat` PTY sent slash command: `{summary['chat_backend_compact_command_sent']}`
- original TUI compaction request reached mock model: `{summary['original_compaction_request_seen']}`
- `.chat` TUI compaction request reached mock model: `{summary['chat_backend_compaction_request_seen']}`
- original follow-up CLI resume succeeded: `{summary['original_followup_exec_ok']}`
- `.chat` follow-up CLI resume succeeded: `{summary['chat_backend_followup_exec_ok']}`
- normalized first CLI turn equal: `{summary['normalized_first_exec_equal']}`
- normalized follow-up CLI resume equal: `{summary['normalized_followup_exec_equal']}`
- mock request context markers matched original: `{summary['mock_context_markers_equal']}`
- compaction/follow-up context checks passed: `{summary['mock_compaction_context_ok']}`
- original rollout preserved compacted replacement history: `{summary['original_compaction_storage_ok']}`
- `.chat` timeline/journal preserved compaction checkpoint/source transport: `{summary['chat_backend_compaction_storage_ok']}`
- `.chat` package has standard projections: `{summary['chat_backend_standard_projections_ok']}`
- original rollout lines equal `.chat` journal lines: `{summary['durable_line_counts_equal']}`

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat-backend': chat_mock}, indent=2, sort_keys=True)}
```

## Compaction Storage Summary

```json
{json.dumps({'original': original_compaction, 'chat-backend': chat_compaction}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-compaction-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-compaction-response.json
```

## Not Yet Proven

This smoke does not prove automatic compaction, compact-summary-as-resume
baseline behavior, world-state full/patch restore, legacy compaction fallback,
rollback after compaction, crash recovery, complete data fidelity, or
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_first_exec_ok"],
            summary["chat_backend_first_exec_ok"],
            summary["original_compact_tui_exit_ok"],
            summary["chat_backend_compact_tui_exit_ok"],
            summary["original_compact_command_sent"],
            summary["chat_backend_compact_command_sent"],
            summary["original_compaction_request_seen"],
            summary["chat_backend_compaction_request_seen"],
            summary["original_followup_exec_ok"],
            summary["chat_backend_followup_exec_ok"],
            summary["normalized_first_exec_equal"],
            summary["normalized_followup_exec_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_compaction_context_ok"],
            summary["original_compaction_storage_ok"],
            summary["chat_backend_compaction_storage_ok"],
            summary["chat_backend_standard_projections_ok"],
            summary["durable_line_counts_equal"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
