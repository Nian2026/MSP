#!/usr/bin/env python3
"""Run real CLI/TUI rollback process-kill parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI slice:

    codex
    type two prompts into the TUI
    press Esc, Esc, Enter to trigger backtrack rollback
    wait until the rollback marker is durably observable
    kill the TUI process with SIGKILL
    codex exec --json resume --last ...

The original backend is the behavioral oracle. This is not a final rollback,
crash-recovery, or user-indistinguishability claim.
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
    normalize_exec_events,
    run_cli_command,
)
from cli_rollback_smoke import (  # noqa: E402
    FIRST_ASSISTANT_TEXT,
    FIRST_USER_TEXT,
    FOLLOWUP_ASSISTANT_TEXT,
    FOLLOWUP_USER_TEXT,
    SECOND_ASSISTANT_TEXT,
    SECOND_USER_TEXT,
    TERMINAL_PROBE_RESPONSE,
    chat_package_observation,
    count_rollback_markers,
    durable_line_counts,
    response_request_count,
    storage_summary,
    strip_ansi,
    summarize_mock_requests,
    type_prompt_and_enter,
)


ROLLBACK_MARKER_IDLE_SECONDS = 0.5

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
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_command_output_process_kill_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_exec_resume_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_backtrack.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/input.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/thread_routing.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/rollout_reconstruction.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def run_cli_two_turns_backtrack_and_kill_tui(
    tree_name: str,
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["TERM"] = "xterm-256color"
    env.setdefault("RUST_LOG", "warn")

    rollback_markers_before = count_rollback_markers(tree_name, codex_home, chat_root)

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
    sent_first_prompt = False
    sent_second_prompt = False
    first_response_seen_at: float | None = None
    first_answer_visible_at: float | None = None
    second_prompt_sent_at: float | None = None
    second_enter_retry_sent = False
    second_response_seen_at: float | None = None
    second_answer_visible_at: float | None = None
    sent_first_escape = False
    sent_second_escape = False
    sent_backtrack_enter = False
    rollback_marker_seen_at: float | None = None
    killed_after_rollback_marker = False

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

            visible_text = output.decode(errors="replace")
            visible_tail = visible_text[-1800:]
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

            ready_for_prompt = (
                "OpenAICodex" in compact_visible_tail
                and "mock-model" in compact_visible_tail
                and (
                    sent_trust_continue
                    or "Doyoutrustthecontentsofthisdirectory?"
                    not in compact_visible_tail
                )
            )
            if ready_for_prompt and not sent_first_prompt:
                type_prompt_and_enter(master, FIRST_USER_TEXT)
                sent_first_prompt = True

            requests_seen = response_request_count(mock_server.requests)
            if sent_first_prompt and requests_seen >= 1 and first_response_seen_at is None:
                first_response_seen_at = time.time()
            if (
                first_response_seen_at is not None
                and FIRST_ASSISTANT_TEXT in visible_text
                and first_answer_visible_at is None
            ):
                first_answer_visible_at = time.time()
            if (
                first_answer_visible_at is not None
                and time.time() - first_answer_visible_at > 1.5
                and not sent_second_prompt
            ):
                type_prompt_and_enter(master, SECOND_USER_TEXT)
                sent_second_prompt = True
                second_prompt_sent_at = time.time()
            if (
                sent_second_prompt
                and requests_seen < 2
                and second_prompt_sent_at is not None
                and time.time() - second_prompt_sent_at > 2
                and not second_enter_retry_sent
            ):
                os.write(master, b"\r")
                second_enter_retry_sent = True

            if sent_second_prompt and requests_seen >= 2 and second_response_seen_at is None:
                second_response_seen_at = time.time()
            if (
                second_response_seen_at is not None
                and SECOND_ASSISTANT_TEXT in visible_text
                and second_answer_visible_at is None
            ):
                second_answer_visible_at = time.time()
            ready_for_backtrack = (
                second_answer_visible_at is not None
                and time.time() - second_answer_visible_at > 1.5
            )
            if ready_for_backtrack and not sent_first_escape:
                os.write(master, b"\x1b")
                sent_first_escape = True
                time.sleep(0.2)
            if sent_first_escape and not sent_second_escape:
                os.write(master, b"\x1b")
                sent_second_escape = True
                time.sleep(0.2)
            if sent_second_escape and not sent_backtrack_enter:
                os.write(master, b"\r")
                sent_backtrack_enter = True

            if sent_backtrack_enter and rollback_marker_seen_at is None:
                current_markers = count_rollback_markers(
                    tree_name,
                    codex_home,
                    chat_root,
                )
                if current_markers > rollback_markers_before:
                    rollback_marker_seen_at = time.time()

            if (
                rollback_marker_seen_at is not None
                and time.time() - rollback_marker_seen_at >= ROLLBACK_MARKER_IDLE_SECONDS
            ):
                process.kill()
                killed_after_rollback_marker = True
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
    rollback_markers_after = count_rollback_markers(tree_name, codex_home, chat_root)
    return {
        "command": command,
        "exit_code": exit_code,
        "duration_seconds": round(time.time() - started_at, 3),
        "sent_probe_response": sent_probe_response,
        "sent_trust_answer": sent_trust_answer,
        "sent_trust_continue": sent_trust_continue,
        "sent_term_gate_answer": sent_term_gate_answer,
        "sent_first_prompt": sent_first_prompt,
        "sent_second_prompt": sent_second_prompt,
        "first_answer_visible": first_answer_visible_at is not None,
        "second_enter_retry_sent": second_enter_retry_sent,
        "first_response_seen": first_response_seen_at is not None,
        "second_response_seen": second_response_seen_at is not None,
        "second_answer_visible": second_answer_visible_at is not None,
        "sent_first_escape": sent_first_escape,
        "sent_second_escape": sent_second_escape,
        "sent_backtrack_enter": sent_backtrack_enter,
        "rollback_markers_before": rollback_markers_before,
        "rollback_markers_after": rollback_markers_after,
        "rollback_marker_seen": rollback_marker_seen_at is not None,
        "killed_after_rollback_marker": killed_after_rollback_marker,
        "killed_by_sigkill": exit_code == -9,
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
        [FIRST_ASSISTANT_TEXT, SECOND_ASSISTANT_TEXT, FOLLOWUP_ASSISTANT_TEXT]
    ) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        killed_rollback_tui = run_cli_two_turns_backtrack_and_kill_tui(
            tree_name,
            codex_bin,
            workspace,
            codex_home,
            chat_root,
            config_overrides,
            mock_server,
        )
        after_kill_storage = storage_summary(tree_name, codex_home, chat_root)
        followup_exec = run_cli_command(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            FOLLOWUP_USER_TEXT,
            resume_last=True,
        )
        final_storage = storage_summary(tree_name, codex_home, chat_root)
        return {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "killed_rollback_tui": killed_rollback_tui,
            "followup_exec": followup_exec,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "after_kill_storage": after_kill_storage,
            "final_storage": final_storage,
            "after_kill_line_counts": durable_line_counts(
                after_kill_storage,
                tree_name,
            ),
            "final_line_counts": durable_line_counts(final_storage, tree_name),
            "chat_package_summary": chat_package_observation(chat_root)
            if tree_name == "chat-backend"
            else None,
            "rollback_marker_count": count_rollback_markers(
                tree_name,
                codex_home,
                chat_root,
            ),
        }


def build_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> str:
    return f"""# CLI Rollback Process-Kill Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real interactive Codex TUI, waits until backtrack rollback is
durably observable, kills the TUI process with SIGKILL, and then uses
`codex exec --json resume --last` as the cold CLI resume surface.

## Gate

Before this work, the public `.chat` spec files, formal draft
spec files, vendor manifest, baseline checks, backend mapping, current parity
matrix, current reports, existing rollback/process-kill tests, TUI backtrack
sources, rollback reconstruction source, and the adapted `.chat` thread-store
source were read. The unmodified original source tree was used only as the
oracle.

## Scope

This smoke covers a narrow RB01/R01/H05-adjacent user-visible slice:

```text
codex
type two prompts in the real TUI
Esc, Esc, Enter in the real TUI backtrack flow
wait for durable rollback marker
SIGKILL the TUI process
codex exec --json resume --last ...
```

It verifies:

- both real TUIs reach two completed mock-model turns;
- both real TUIs dispatch the backtrack rollback keys;
- both backends have a durable rollback marker before process death;
- both TUI processes are killed with SIGKILL after that marker;
- follow-up `codex exec --json resume --last` returns matching normalized
  CLI JSONL output;
- follow-up model context preserves the first turn and excludes the rolled-back
  second user/assistant turn for both backends;
- durable line counts stay aligned after kill and after follow-up resume;
- the `.chat` backend exposes a neutral `timeline_rollback` event and standard
  projections.

This smoke does not claim complete rollback parity, arbitrary process-kill
crash recovery, lifecycle process-kill parity, or final user-indistinguishability.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cli-rollback-process-kill-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cli-rollback-process-kill-response.json
```
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("cli-rollback-process-kill-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_followup_events = normalize_exec_events(
        original_result["followup_exec"].get("events") or []
    )
    chat_followup_events = normalize_exec_events(
        chat_result["followup_exec"].get("events") or []
    )
    chat_package = chat_result["chat_package_summary"] or {}

    followup_context_ok = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["followup_body_contains_first_user_text"],
            chat_mock["followup_body_contains_first_user_text"],
            original_mock["followup_body_contains_first_assistant_text"],
            chat_mock["followup_body_contains_first_assistant_text"],
            original_mock["followup_body_contains_followup_user_text"],
            chat_mock["followup_body_contains_followup_user_text"],
            not original_mock["followup_body_contains_second_user_text"],
            not chat_mock["followup_body_contains_second_user_text"],
            not original_mock["followup_body_contains_second_assistant_text"],
            not chat_mock["followup_body_contains_second_assistant_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-rollback-process-kill-smoke",
        "matrix_slice": [
            "RB01-adjacent",
            "R01-adjacent",
            "H05-adjacent-process-kill-after-durable-rollback-marker",
        ],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_rollback_tui_killed_by_sigkill": original_result[
            "killed_rollback_tui"
        ].get("killed_by_sigkill"),
        "chat_backend_rollback_tui_killed_by_sigkill": chat_result[
            "killed_rollback_tui"
        ].get("killed_by_sigkill"),
        "original_tui_prompts_and_responses_seen": all(
            [
                original_result["killed_rollback_tui"].get("sent_first_prompt"),
                original_result["killed_rollback_tui"].get("sent_second_prompt"),
                original_result["killed_rollback_tui"].get("first_response_seen"),
                original_result["killed_rollback_tui"].get("second_response_seen"),
            ]
        ),
        "chat_backend_tui_prompts_and_responses_seen": all(
            [
                chat_result["killed_rollback_tui"].get("sent_first_prompt"),
                chat_result["killed_rollback_tui"].get("sent_second_prompt"),
                chat_result["killed_rollback_tui"].get("first_response_seen"),
                chat_result["killed_rollback_tui"].get("second_response_seen"),
            ]
        ),
        "original_backtrack_keys_sent": all(
            [
                original_result["killed_rollback_tui"].get("sent_first_escape"),
                original_result["killed_rollback_tui"].get("sent_second_escape"),
                original_result["killed_rollback_tui"].get("sent_backtrack_enter"),
            ]
        ),
        "chat_backend_backtrack_keys_sent": all(
            [
                chat_result["killed_rollback_tui"].get("sent_first_escape"),
                chat_result["killed_rollback_tui"].get("sent_second_escape"),
                chat_result["killed_rollback_tui"].get("sent_backtrack_enter"),
            ]
        ),
        "original_rollback_marker_seen_before_kill": original_result[
            "killed_rollback_tui"
        ].get("rollback_marker_seen"),
        "chat_backend_rollback_marker_seen_before_kill": chat_result[
            "killed_rollback_tui"
        ].get("rollback_marker_seen"),
        "original_killed_after_rollback_marker": original_result[
            "killed_rollback_tui"
        ].get("killed_after_rollback_marker"),
        "chat_backend_killed_after_rollback_marker": chat_result[
            "killed_rollback_tui"
        ].get("killed_after_rollback_marker"),
        "original_followup_exec_ok": original_result["followup_exec"].get("exit_code")
        == 0,
        "chat_backend_followup_exec_ok": chat_result["followup_exec"].get("exit_code")
        == 0,
        "normalized_followup_exec_equal": original_followup_events == chat_followup_events,
        "mock_request_summaries_equal": original_mock == chat_mock,
        "followup_context_excludes_rolled_back_turn": followup_context_ok,
        "rollback_marker_counts_equal": original_result["rollback_marker_count"]
        == chat_result["rollback_marker_count"],
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "durable_line_counts_equal_after_kill": original_result["after_kill_line_counts"]
        == chat_result["after_kill_line_counts"],
        "original_after_kill_line_counts": original_result["after_kill_line_counts"],
        "chat_backend_after_kill_line_counts": chat_result["after_kill_line_counts"],
        "durable_line_counts_equal_after_followup": original_result["final_line_counts"]
        == chat_result["final_line_counts"],
        "original_final_line_counts": original_result["final_line_counts"],
        "chat_backend_final_line_counts": chat_result["final_line_counts"],
        "chat_backend_timeline_rollback_event_present": chat_package.get(
            "total_timeline_rollback_count"
        )
        == 1,
        "chat_backend_standard_projections_ok": chat_package.get(
            "all_packages_have_standard_projections"
        ),
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_killed_rollback_tui": original_result["killed_rollback_tui"],
        "chat_backend_killed_rollback_tui": chat_result["killed_rollback_tui"],
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "process kill before rollback marker is durable",
            "process kill during rollback request before app-server response",
            "rollback many turns RB02 through a process-kill boundary",
            "cumulative rollback markers RB03 through a process-kill boundary",
            "rollback during active turn RB04 through a process-kill boundary",
            "rollback after compaction RB05 through a process-kill boundary",
            "lifecycle archive/delete process-kill parity through real CLI",
            "arbitrary filesystem I/O failure",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }
    summary["passed"] = all(
        [
            summary["original_rollback_tui_killed_by_sigkill"],
            summary["chat_backend_rollback_tui_killed_by_sigkill"],
            summary["original_tui_prompts_and_responses_seen"],
            summary["chat_backend_tui_prompts_and_responses_seen"],
            summary["original_backtrack_keys_sent"],
            summary["chat_backend_backtrack_keys_sent"],
            summary["original_rollback_marker_seen_before_kill"],
            summary["chat_backend_rollback_marker_seen_before_kill"],
            summary["original_killed_after_rollback_marker"],
            summary["chat_backend_killed_after_rollback_marker"],
            summary["original_followup_exec_ok"],
            summary["chat_backend_followup_exec_ok"],
            summary["normalized_followup_exec_equal"],
            summary["mock_request_summaries_equal"],
            summary["followup_context_excludes_rolled_back_turn"],
            summary["rollback_marker_counts_equal"],
            summary["durable_line_counts_equal_after_kill"],
            summary["durable_line_counts_equal_after_followup"],
            summary["chat_backend_timeline_rollback_event_present"],
            summary["chat_backend_standard_projections_ok"],
        ]
    )

    write_json(
        output_dir / "original/cli-rollback-process-kill-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/cli-rollback-process-kill-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)
    (output_dir / "report.md").write_text(build_report(output_dir, summary))

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
