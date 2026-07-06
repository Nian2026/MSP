#!/usr/bin/env python3
"""Run a real CLI fork-picker parity smoke through the interactive TUI.

This source-backed validation covers a narrow user-facing Codex CLI path:

    codex
      create a target interactive session
    codex
      create a decoy interactive session
    codex fork
      type a target-only picker search query
      press Enter to select the filtered target
      type a fork prompt in the forked TUI

The fork picker intentionally does not include non-interactive `codex exec`
histories, so this smoke creates ordinary interactive CLI sessions before
opening the picker. The third model request must contain target history, the
fork prompt, and no decoy history. This proves only a bounded fork-picker
search/select/fork path; it is not final fork parity.
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
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
)
from cli_fork_smoke import (  # noqa: E402
    chat_package_snapshot,
    inspect_chat_packages,
    original_thread_snapshot,
    summarize_original_sessions,
)
from cli_rollback_smoke import (  # noqa: E402
    TERMINAL_PROBE_RESPONSE,
    strip_ansi,
    type_prompt_and_enter,
)


TARGET_USER_TEXT = "CLI fork picker target durable turn."
DECOY_USER_TEXT = "CLI fork picker decoy durable turn."
FORK_USER_TEXT = "CLI fork picker selected target follow-up."
TARGET_ASSISTANT_TEXT = "CLI fork picker target answer from mock model."
DECOY_ASSISTANT_TEXT = "CLI fork picker decoy answer from mock model."
FORK_ASSISTANT_TEXT = "CLI fork picker fork answer from mock model."
PICKER_QUERY = "fork picker target durable"

COMPACT_TARGET_USER_TEXT = re.sub(r"\s+", "", TARGET_USER_TEXT)
COMPACT_DECOY_USER_TEXT = re.sub(r"\s+", "", DECOY_USER_TEXT)
COMPACT_TARGET_ASSISTANT_TEXT = re.sub(r"\s+", "", TARGET_ASSISTANT_TEXT)
COMPACT_FORK_USER_TEXT = re.sub(r"\s+", "", FORK_USER_TEXT)
COMPACT_FORK_ASSISTANT_TEXT = re.sub(r"\s+", "", FORK_ASSISTANT_TEXT)

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_search_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_rollback_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/cli/src/main.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/lib.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(
        1 for request in requests if request.get("path", "").endswith("/responses")
    )


def compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def thread_ids_for_tree(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> list[str]:
    if tree_name == "chat-backend":
        summary = summarize_chat_packages(chat_root)
        return sorted(
            package.get("conversation_id")
            for package in summary.get("packages", [])
            if package.get("conversation_id")
        )
    summary = summarize_original_sessions(codex_home, None)
    return sorted(summary.get("thread_ids") or [])


def storage_line_counts(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> list[int]:
    if tree_name == "chat-backend":
        summary = summarize_chat_packages(chat_root)
        return sorted(
            package.get("journal_line_count")
            for package in summary.get("packages", [])
            if package.get("journal_line_count") is not None
        )
    summary = summarize_original_sessions(codex_home, None)
    return sorted(
        line_count
        for line_count in summary.get("line_counts", [])
        if line_count is not None
    )


def snapshot_thread(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    thread_id: str | None,
) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return chat_package_snapshot(chat_root, thread_id)
    return original_thread_snapshot(codex_home, thread_id)


def wait_and_collect_tui(
    command: list[str],
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    loop_timeout_seconds: float,
    on_tick,
) -> dict[str, Any]:
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
    state: dict[str, Any] = {
        "sent_probe_response": False,
        "sent_trust_answer": False,
        "sent_trust_continue": False,
        "sent_term_gate_answer": False,
        "sent_ctrl_c": False,
    }
    try:
        while time.time() - started_at < loop_timeout_seconds:
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
            visible_tail = visible[-2400:]
            stripped = strip_ansi(visible)
            compact_tail = compact(strip_ansi(visible_tail))

            if not state["sent_probe_response"] and (
                "\x1b[6n" in visible_tail
                or "]10;?" in visible_tail
                or "[?u" in visible_tail
            ):
                os.write(master, TERMINAL_PROBE_RESPONSE)
                state["sent_probe_response"] = True
            if (
                not state["sent_trust_answer"]
                and "Doyoutrustthecontentsofthisdirectory?" in compact_tail
            ):
                os.write(master, b"1\r\r")
                state["sent_trust_answer"] = True
                state["sent_trust_continue"] = True
            if (
                state["sent_trust_answer"]
                and not state["sent_trust_continue"]
                and "Pressentertocontinue" in compact_tail
            ):
                os.write(master, b"\r")
                state["sent_trust_continue"] = True
            if "Continue anyway?" in visible_tail and not state["sent_term_gate_answer"]:
                os.write(master, b"y\r")
                state["sent_term_gate_answer"] = True

            should_stop = on_tick(master, state, visible, stripped, compact_tail)
            if should_stop:
                break

            if process.poll() is not None:
                break

        if process.poll() is None:
            try:
                os.write(master, b"\x03")
                state["sent_ctrl_c"] = True
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
        **state,
        "output_tail_stripped": stripped_output[-3000:],
        "raw_output_bytes": len(output),
    }


def run_single_turn_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
    user_text: str,
    assistant_text: str,
    expected_response_count: int,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    state_local = {
        "sent_prompt": False,
        "response_seen_at": None,
        "assistant_visible_at": None,
    }

    def on_tick(master, state, visible, stripped, compact_tail) -> bool:
        ready_for_prompt = (
            "OpenAICodex" in compact_tail
            and "mock-model" in compact_tail
            and (
                state["sent_trust_continue"]
                or "Doyoutrustthecontentsofthisdirectory?" not in compact_tail
            )
        )
        if ready_for_prompt and not state_local["sent_prompt"]:
            type_prompt_and_enter(master, user_text)
            state_local["sent_prompt"] = True

        requests_seen = response_request_count(mock_server.requests)
        if (
            state_local["sent_prompt"]
            and requests_seen >= expected_response_count
            and state_local["response_seen_at"] is None
        ):
            state_local["response_seen_at"] = time.time()
        if (
            state_local["response_seen_at"] is not None
            and assistant_text in stripped
            and state_local["assistant_visible_at"] is None
        ):
            state_local["assistant_visible_at"] = time.time()
        if (
            state_local["assistant_visible_at"] is not None
            and time.time() - state_local["assistant_visible_at"] > 1.2
        ):
            return True
        return False

    result = wait_and_collect_tui(
        command,
        workspace,
        codex_home,
        loop_timeout_seconds=65,
        on_tick=on_tick,
    )
    result.update(
        {
            "sent_prompt": state_local["sent_prompt"],
            "response_seen": state_local["response_seen_at"] is not None,
            "assistant_visible": state_local["assistant_visible_at"] is not None,
        }
    )
    return result


def write_picker_query(master: int) -> None:
    for char in PICKER_QUERY:
        os.write(master, char.encode("utf-8"))
        time.sleep(0.02)
    time.sleep(0.2)
    os.write(master, b"\r")


def run_fork_picker_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.append("fork")

    state_local = {
        "target_seen_before_query": False,
        "decoy_seen_before_query": False,
        "sent_query": False,
        "query_sent_at": None,
        "sent_fork_prompt": False,
        "fork_prompt_sent_at": None,
        "fork_response_seen_at": None,
        "fork_assistant_visible_at": None,
    }

    def on_tick(master, _state, visible, stripped, compact_tail) -> bool:
        compact_output = compact(stripped)
        if TARGET_USER_TEXT in stripped or COMPACT_TARGET_USER_TEXT in compact_output:
            state_local["target_seen_before_query"] = True
        if DECOY_USER_TEXT in stripped or COMPACT_DECOY_USER_TEXT in compact_output:
            state_local["decoy_seen_before_query"] = True

        if (
            not state_local["sent_query"]
            and state_local["target_seen_before_query"]
            and state_local["decoy_seen_before_query"]
            and "Forkaprevioussession" in compact_output
            and response_request_count(mock_server.requests) >= 2
        ):
            write_picker_query(master)
            state_local["sent_query"] = True
            state_local["query_sent_at"] = time.time()

        selected_or_started = (
            state_local["sent_query"]
            and state_local["query_sent_at"] is not None
            and time.time() - state_local["query_sent_at"] > 1.0
            and (
                "Forkaprevioussession" not in compact_tail
                or TARGET_ASSISTANT_TEXT in stripped
                or COMPACT_TARGET_ASSISTANT_TEXT in compact_output
                or "Pressentertocontinue" in compact_tail
            )
        )
        if selected_or_started and not state_local["sent_fork_prompt"]:
            type_prompt_and_enter(master, FORK_USER_TEXT)
            state_local["sent_fork_prompt"] = True
            state_local["fork_prompt_sent_at"] = time.time()

        requests_seen = response_request_count(mock_server.requests)
        if (
            state_local["sent_fork_prompt"]
            and requests_seen >= 3
            and state_local["fork_response_seen_at"] is None
        ):
            state_local["fork_response_seen_at"] = time.time()
        if (
            state_local["fork_response_seen_at"] is not None
            and (
                FORK_ASSISTANT_TEXT in stripped
                or COMPACT_FORK_ASSISTANT_TEXT in compact_output
            )
            and state_local["fork_assistant_visible_at"] is None
        ):
            state_local["fork_assistant_visible_at"] = time.time()
        if (
            state_local["fork_response_seen_at"] is not None
            and time.time() - state_local["fork_response_seen_at"] > 2.0
        ):
            return True
        return False

    result = wait_and_collect_tui(
        command,
        workspace,
        codex_home,
        loop_timeout_seconds=85,
        on_tick=on_tick,
    )
    result.update(
        {
            "target_seen_before_query": state_local["target_seen_before_query"],
            "decoy_seen_before_query": state_local["decoy_seen_before_query"],
            "sent_query": state_local["sent_query"],
            "sent_fork_prompt": state_local["sent_fork_prompt"],
            "fork_response_seen": state_local["fork_response_seen_at"] is not None,
            "fork_assistant_visible": state_local["fork_assistant_visible_at"] is not None,
        }
    )
    return result


def mock_request_summary(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    target_body = bodies[0] if len(bodies) > 0 else {}
    decoy_body = bodies[1] if len(bodies) > 1 else {}
    fork_body = bodies[2] if len(bodies) > 2 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "target_body_contains_target_user": body_contains(target_body, TARGET_USER_TEXT),
        "target_body_contains_decoy_user": body_contains(target_body, DECOY_USER_TEXT),
        "decoy_body_contains_decoy_user": body_contains(decoy_body, DECOY_USER_TEXT),
        "decoy_body_contains_target_user": body_contains(decoy_body, TARGET_USER_TEXT),
        "fork_body_contains_target_user": body_contains(fork_body, TARGET_USER_TEXT),
        "fork_body_contains_target_assistant": body_contains(
            fork_body, TARGET_ASSISTANT_TEXT
        ),
        "fork_body_contains_fork_user": body_contains(fork_body, FORK_USER_TEXT),
        "fork_body_contains_decoy_user": body_contains(fork_body, DECOY_USER_TEXT),
        "fork_body_contains_decoy_assistant": body_contains(
            fork_body, DECOY_ASSISTANT_TEXT
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

    with SequenceMockResponsesServer(
        [TARGET_ASSISTANT_TEXT, DECOY_ASSISTANT_TEXT, FORK_ASSISTANT_TEXT]
    ) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        before_target_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))
        target_tui = run_single_turn_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
            TARGET_USER_TEXT,
            TARGET_ASSISTANT_TEXT,
            expected_response_count=1,
        )
        after_target_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))
        target_new_ids = sorted(after_target_ids - before_target_ids)
        target_thread_id = target_new_ids[0] if len(target_new_ids) == 1 else None

        before_decoy_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))
        decoy_tui = run_single_turn_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
            DECOY_USER_TEXT,
            DECOY_ASSISTANT_TEXT,
            expected_response_count=2,
        )
        after_decoy_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))
        decoy_new_ids = sorted(after_decoy_ids - before_decoy_ids)
        decoy_thread_id = decoy_new_ids[0] if len(decoy_new_ids) == 1 else None

        target_snapshot_before_fork = snapshot_thread(
            tree_name,
            codex_home,
            chat_root,
            target_thread_id,
        )
        decoy_snapshot_before_fork = snapshot_thread(
            tree_name,
            codex_home,
            chat_root,
            decoy_thread_id,
        )
        pre_fork_line_counts = storage_line_counts(tree_name, codex_home, chat_root)

        fork_picker_tui = run_fork_picker_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )

        post_fork_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))
        fork_new_ids = sorted(post_fork_ids - after_decoy_ids)
        target_snapshot_after_fork = snapshot_thread(
            tree_name,
            codex_home,
            chat_root,
            target_thread_id,
        )
        decoy_snapshot_after_fork = snapshot_thread(
            tree_name,
            codex_home,
            chat_root,
            decoy_thread_id,
        )
        post_fork_line_counts = storage_line_counts(tree_name, codex_home, chat_root)
        mock_summary = mock_request_summary(mock_server.requests)

    post_fork_storage = (
        inspect_chat_packages(chat_root, target_thread_id)
        if tree_name == "chat-backend"
        else summarize_original_sessions(codex_home, target_thread_id)
    )

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "target_tui": target_tui,
        "decoy_tui": decoy_tui,
        "fork_picker_tui": fork_picker_tui,
        "target_thread_id": target_thread_id,
        "decoy_thread_id": decoy_thread_id,
        "fork_thread_ids": fork_new_ids,
        "target_snapshot_before_fork": target_snapshot_before_fork,
        "target_snapshot_after_fork": target_snapshot_after_fork,
        "decoy_snapshot_before_fork": decoy_snapshot_before_fork,
        "decoy_snapshot_after_fork": decoy_snapshot_after_fork,
        "target_source_durable_history_unchanged": (
            target_snapshot_before_fork == target_snapshot_after_fork
        ),
        "decoy_source_durable_history_unchanged": (
            decoy_snapshot_before_fork == decoy_snapshot_after_fork
        ),
        "pre_fork_line_counts": pre_fork_line_counts,
        "post_fork_line_counts": post_fork_line_counts,
        "mock_server_summary": mock_summary,
        "post_fork_storage": post_fork_storage,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "target_tui_exit_code": result["target_tui"]["exit_code"],
        "target_tui_sent_prompt": result["target_tui"]["sent_prompt"],
        "target_tui_response_seen": result["target_tui"]["response_seen"],
        "target_tui_assistant_visible": result["target_tui"]["assistant_visible"],
        "decoy_tui_exit_code": result["decoy_tui"]["exit_code"],
        "decoy_tui_sent_prompt": result["decoy_tui"]["sent_prompt"],
        "decoy_tui_response_seen": result["decoy_tui"]["response_seen"],
        "decoy_tui_assistant_visible": result["decoy_tui"]["assistant_visible"],
        "fork_picker_sent_query": result["fork_picker_tui"]["sent_query"],
        "fork_picker_target_seen_before_query": result["fork_picker_tui"][
            "target_seen_before_query"
        ],
        "fork_picker_decoy_seen_before_query": result["fork_picker_tui"][
            "decoy_seen_before_query"
        ],
        "fork_picker_sent_fork_prompt": result["fork_picker_tui"][
            "sent_fork_prompt"
        ],
        "fork_picker_response_seen": result["fork_picker_tui"][
            "fork_response_seen"
        ],
        "fork_picker_assistant_visible": result["fork_picker_tui"][
            "fork_assistant_visible"
        ],
        "target_thread_created": result["target_thread_id"] is not None,
        "decoy_thread_created": result["decoy_thread_id"] is not None,
        "fork_thread_count": len(result["fork_thread_ids"]),
        "target_source_durable_history_unchanged": result[
            "target_source_durable_history_unchanged"
        ],
        "decoy_source_durable_history_unchanged": result[
            "decoy_source_durable_history_unchanged"
        ],
        "mock": result["mock_server_summary"],
        "post_fork_line_counts": result["post_fork_line_counts"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Fork Picker Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not complete fork parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Picker selected target history: `{summary['picker_selected_target_history']}`",
        f"- Picker excluded decoy history: `{summary['picker_excluded_decoy_history']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke creates target and decoy sessions through the ordinary interactive",
        "`codex` TUI, opens `codex fork`, searches the fork picker for the target,",
        "selects it, then sends a fork prompt in the forked TUI.",
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
            "cli-fork-picker-smoke-"
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
            original_normalized["mock"]["fork_body_contains_target_user"],
            original_normalized["mock"]["fork_body_contains_target_assistant"],
            original_normalized["mock"]["fork_body_contains_fork_user"],
            chat_normalized["mock"]["fork_body_contains_target_user"],
            chat_normalized["mock"]["fork_body_contains_target_assistant"],
            chat_normalized["mock"]["fork_body_contains_fork_user"],
        ]
    )
    picker_excluded_decoy_history = not any(
        [
            original_normalized["mock"]["fork_body_contains_decoy_user"],
            original_normalized["mock"]["fork_body_contains_decoy_assistant"],
            chat_normalized["mock"]["fork_body_contains_decoy_user"],
            chat_normalized["mock"]["fork_body_contains_decoy_assistant"],
        ]
    )
    durable_line_counts_equal = (
        original_normalized["post_fork_line_counts"]
        == chat_normalized["post_fork_line_counts"]
        and len(original_normalized["post_fork_line_counts"]) == 3
    )
    normalized_summaries_equal = original_normalized == chat_normalized

    chat_post_storage = chat_result["post_fork_storage"]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-fork-picker-smoke",
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
        "chat_package_count_is_three": chat_post_storage.get("package_count") == 3,
        "chat_packages_have_standard_projections": chat_post_storage.get(
            "all_packages_have_standard_projections"
        ),
        "original_fork_rollout_records_source_relation": original_result[
            "post_fork_storage"
        ]["fork_rollout_records_source_relation"],
        "chat_fork_package_records_source_relation": chat_post_storage[
            "fork_package_mentions_source_thread"
        ],
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI fork picker slice: ordinary "
            "interactive target and decoy sessions can be loaded into `codex fork`, "
            "typed picker search can select the target session, the forked TUI "
            "sends a prompt request containing target history and excluding decoy "
            "history, and the original and .chat backends keep durable counts, "
            "source relation metadata, source histories, and standard .chat "
            "projection materialization aligned."
        ),
        "not_yet_proven": [
            "full visual fork picker parity across viewport sizes",
            "fork picker pagination beyond two loaded rows",
            "fork picker selected-row preview and transcript overlay behavior",
            "fork-by-turn-id through every CLI surface",
            "pathless fork through every CLI surface",
            "`--last` source-relation and copied-history semantics for every source kind",
            "complete copied-history persistence for every fork variant",
            "broader relation/list behavior",
            "complete fork parity",
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
            summary["chat_package_count_is_three"],
            summary["chat_packages_have_standard_projections"],
            summary["original_fork_rollout_records_source_relation"],
            summary["chat_fork_package_records_source_relation"],
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
