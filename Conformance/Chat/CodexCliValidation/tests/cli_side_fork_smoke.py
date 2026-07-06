#!/usr/bin/env python3
"""Run a real CLI/TUI `/side` or `/btw` ephemeral fork parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI path:

    codex
      send a parent prompt
      /side ... or /btw ...

The slash command creates an ephemeral/pathless fork. The smoke proves only the
covered slash-command path: the side request sees copied parent context plus the
side prompt, while neither backend materializes an additional durable thread for
the side conversation.
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
from cli_fork_picker_smoke import wait_and_collect_tui  # noqa: E402


PARENT_USER_TEXT = "CLI side fork parent durable turn."
SIDE_USER_TEXT = "CLI side fork pathless follow-up."
PARENT_ASSISTANT_TEXT = "CLI side fork parent answer from mock model."
SIDE_ASSISTANT_TEXT = "CLI side fork side answer from mock model."
SIDE_BOUNDARY_TEXT = "Side conversation boundary."
NESTED_SIDE_USER_TEXT = "CLI side fork nested attempt."
NESTED_SIDE_REJECTION_HINT = (
    "unavailable in side conversations. Press Ctrl+C to return to the main thread first."
)
DEFAULT_PARENT_RUNNING_DELAY_SECONDS = 8.0

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
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/slash_command.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/slash_dispatch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/chatwidget/tests/side.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app/side.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/app_server_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/slash_command.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/chatwidget/slash_dispatch.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/chatwidget/tests/side.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/app/side.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/app_server_session.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


class DelayedFirstSequenceMockResponsesServer(SequenceMockResponsesServer):
    def __init__(self, answers: list[str], first_delay_seconds: float) -> None:
        super().__init__(answers)
        self.first_delay_seconds = first_delay_seconds

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter == 1 and self.first_delay_seconds > 0:
            time.sleep(self.first_delay_seconds)
        answer = self.answers[min(counter - 1, len(self.answers) - 1)]
        return sse_response(
            f"resp-cli-side-fork-smoke-{counter}",
            f"msg-cli-side-fork-smoke-{counter}",
            answer,
        )


def response_request_count(requests: list[dict[str, Any]]) -> int:
    return sum(1 for request in requests if request.get("path", "").endswith("/responses"))


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def paste_prompt_and_enter(master: int, text: str) -> None:
    """Submit a prompt through bracketed paste so slash popups do not steal Enter.

    Slow byte-by-byte typing opens the slash-command popup after `/` and can
    leave Enter selecting the currently highlighted command instead of
    dispatching the completed inline slash command. The real TUI accepts
    bracketed paste as a single paste event, then Enter submits the completed
    composer text.
    """
    os.write(master, b"\x1b[200~")
    os.write(master, text.encode())
    os.write(master, b"\x1b[201~")
    time.sleep(0.2)
    os.write(master, b"\r")


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
    return sorted(summarize_original_sessions(codex_home, None).get("thread_ids") or [])


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
    return sorted(
        line_count
        for line_count in summarize_original_sessions(codex_home, None).get("line_counts", [])
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


def durable_storage_text(tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path) -> str:
    if tree_name == "chat-backend":
        parts = []
        for package in sorted(chat_root.glob("*.chat")):
            for relative in [
                "manifest.json",
                "timeline.ndjson",
                "journal.ndjson",
                "indexes/thread-metadata.json",
            ]:
                path = package / relative
                if path.exists():
                    parts.append(path.read_text(errors="replace"))
        return "\n".join(parts)

    parts = []
    for rollout in codex_home.glob("sessions/**/*.jsonl"):
        parts.append(rollout.read_text(errors="replace"))
    return "\n".join(parts)


def summarize_storage_text(tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path) -> dict[str, Any]:
    text = durable_storage_text(tree_name, codex_home, chat_root)
    return {
        "contains_parent_user": PARENT_USER_TEXT in text,
        "contains_parent_assistant": PARENT_ASSISTANT_TEXT in text,
        "contains_side_user": SIDE_USER_TEXT in text,
        "contains_side_assistant": SIDE_ASSISTANT_TEXT in text,
        "contains_side_boundary": SIDE_BOUNDARY_TEXT in text,
        "contains_nested_side_user": NESTED_SIDE_USER_TEXT in text,
    }


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    parent_body = bodies[0] if len(bodies) > 0 else {}
    side_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "parent_body_contains_parent_user": body_contains(parent_body, PARENT_USER_TEXT),
        "parent_body_contains_side_user": body_contains(parent_body, SIDE_USER_TEXT),
        "side_body_contains_parent_user": body_contains(side_body, PARENT_USER_TEXT),
        "side_body_contains_parent_assistant": body_contains(side_body, PARENT_ASSISTANT_TEXT),
        "side_body_contains_side_user": body_contains(side_body, SIDE_USER_TEXT),
        "side_body_contains_side_boundary": body_contains(side_body, SIDE_BOUNDARY_TEXT),
        "side_body_contains_nested_side_user": body_contains(side_body, NESTED_SIDE_USER_TEXT),
    }


def run_parent_and_side_tui(
    tree_name: str,
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
    slash_command: str,
    nested_side_command: str | None,
    side_while_parent_running: bool,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])

    state_local: dict[str, Any] = {
        "sent_parent_prompt": False,
        "parent_prompt_sent_at": None,
        "parent_response_seen_at": None,
        "parent_assistant_visible_at": None,
        "sent_side_prompt": False,
        "side_prompt_sent_at": None,
        "side_prompt_sent_while_parent_running": False,
        "side_response_seen_at": None,
        "side_assistant_visible_at": None,
        "sent_first_ctrl_c": False,
        "first_ctrl_c_sent_at": None,
        "sent_nested_side_prompt": False,
        "nested_side_prompt_sent_at": None,
        "nested_side_rejection_visible_at": None,
        "sent_second_ctrl_c": False,
        "second_ctrl_c_sent_at": None,
        "pre_side_thread_ids": [],
        "pre_side_line_counts": [],
        "source_thread_id": None,
        "source_snapshot_before_side": {},
    }

    def on_tick(master: int, state: dict[str, Any], _visible: str, stripped: str, compact_tail: str) -> bool:
        compact_output = compact(stripped)
        requests_seen = response_request_count(mock_server.requests)
        ready_for_parent_prompt = (
            "OpenAICodex" in compact_tail
            and "mock-model" in compact_tail
            and (
                state["sent_trust_continue"]
                or "Doyoutrustthecontentsofthisdirectory?" not in compact_tail
            )
        )

        if not state_local["sent_parent_prompt"] and ready_for_parent_prompt:
            time.sleep(0.5)
            paste_prompt_and_enter(master, PARENT_USER_TEXT)
            state_local["sent_parent_prompt"] = True
            state_local["parent_prompt_sent_at"] = time.time()

        if (
            state_local["sent_parent_prompt"]
            and requests_seen >= 1
            and state_local["parent_response_seen_at"] is None
        ):
            state_local["parent_response_seen_at"] = time.time()

        if (
            state_local["parent_response_seen_at"] is not None
            and (
                PARENT_ASSISTANT_TEXT in stripped
                or compact(PARENT_ASSISTANT_TEXT) in compact_output
            )
            and state_local["parent_assistant_visible_at"] is None
        ):
            state_local["parent_assistant_visible_at"] = time.time()

        parent_ready_for_side = (
            state_local["parent_response_seen_at"] is not None
            and state_local["parent_assistant_visible_at"] is None
            and time.time() - state_local["parent_response_seen_at"] > 0.5
            if side_while_parent_running
            else state_local["parent_assistant_visible_at"] is not None
        )
        if (
            parent_ready_for_side
            and not state_local["sent_side_prompt"]
        ):
            time.sleep(0.5)
            pre_side_thread_ids = thread_ids_for_tree(tree_name, codex_home, chat_root)
            state_local["pre_side_thread_ids"] = pre_side_thread_ids
            state_local["pre_side_line_counts"] = storage_line_counts(
                tree_name, codex_home, chat_root
            )
            source_thread_id = (
                pre_side_thread_ids[0] if len(pre_side_thread_ids) == 1 else None
            )
            state_local["source_thread_id"] = source_thread_id
            state_local["source_snapshot_before_side"] = snapshot_thread(
                tree_name, codex_home, chat_root, source_thread_id
            )
            paste_prompt_and_enter(master, f"/{slash_command} {SIDE_USER_TEXT}")
            state_local["sent_side_prompt"] = True
            state_local["side_prompt_sent_at"] = time.time()
            state_local["side_prompt_sent_while_parent_running"] = (
                state_local["parent_assistant_visible_at"] is None
            )

        if (
            state_local["sent_side_prompt"]
            and requests_seen >= 2
            and state_local["side_response_seen_at"] is None
        ):
            state_local["side_response_seen_at"] = time.time()

        if (
            state_local["side_response_seen_at"] is not None
            and (
                SIDE_ASSISTANT_TEXT in stripped
                or compact(SIDE_ASSISTANT_TEXT) in compact_output
            )
            and state_local["side_assistant_visible_at"] is None
        ):
            state_local["side_assistant_visible_at"] = time.time()

        if (
            state_local["side_assistant_visible_at"] is not None
            and nested_side_command
            and not state_local["sent_nested_side_prompt"]
            and time.time() - state_local["side_assistant_visible_at"] > 1.0
        ):
            paste_prompt_and_enter(master, f"/{nested_side_command} {NESTED_SIDE_USER_TEXT}")
            state_local["sent_nested_side_prompt"] = True
            state_local["nested_side_prompt_sent_at"] = time.time()

        if (
            state_local["sent_nested_side_prompt"]
            and state_local["nested_side_rejection_visible_at"] is None
            and NESTED_SIDE_REJECTION_HINT in stripped
        ):
            state_local["nested_side_rejection_visible_at"] = time.time()

        ready_to_return_from_side = (
            state_local["nested_side_rejection_visible_at"]
            if nested_side_command
            else state_local["side_assistant_visible_at"]
        )
        if (
            ready_to_return_from_side is not None
            and not state_local["sent_first_ctrl_c"]
            and time.time() - ready_to_return_from_side > 1.0
        ):
            os.write(master, b"\x03")
            state_local["sent_first_ctrl_c"] = True
            state_local["first_ctrl_c_sent_at"] = time.time()

        exit_ready_after_side = (
            state_local["parent_assistant_visible_at"] is not None
            if side_while_parent_running
            else True
        )
        if (
            state_local["sent_first_ctrl_c"]
            and not state_local["sent_second_ctrl_c"]
            and exit_ready_after_side
            and time.time() - state_local["first_ctrl_c_sent_at"] > 1.0
        ):
            os.write(master, b"\x03")
            state_local["sent_second_ctrl_c"] = True
            state_local["second_ctrl_c_sent_at"] = time.time()

        if (
            state_local["sent_second_ctrl_c"]
            and time.time() - state_local["second_ctrl_c_sent_at"] > 1.0
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
            "sent_parent_prompt": state_local["sent_parent_prompt"],
            "parent_response_seen": state_local["parent_response_seen_at"] is not None,
            "parent_assistant_visible": state_local["parent_assistant_visible_at"] is not None,
            "sent_side_prompt": state_local["sent_side_prompt"],
            "side_prompt_sent_while_parent_running": state_local[
                "side_prompt_sent_while_parent_running"
            ],
            "side_response_seen": state_local["side_response_seen_at"] is not None,
            "side_assistant_visible": state_local["side_assistant_visible_at"] is not None,
            "sent_nested_side_prompt": state_local["sent_nested_side_prompt"],
            "nested_side_rejection_visible": state_local[
                "nested_side_rejection_visible_at"
            ]
            is not None,
            "sent_first_side_ctrl_c": state_local["sent_first_ctrl_c"],
            "sent_second_exit_ctrl_c": state_local["sent_second_ctrl_c"],
            "pre_side_thread_ids": state_local["pre_side_thread_ids"],
            "pre_side_line_counts": state_local["pre_side_line_counts"],
            "source_thread_id": state_local["source_thread_id"],
            "source_snapshot_before_side": state_local["source_snapshot_before_side"],
        }
    )
    return result


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    slash_command: str,
    nested_side_command: str | None,
    side_while_parent_running: bool,
    first_response_delay_seconds: float,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    server_class = (
        lambda answers: DelayedFirstSequenceMockResponsesServer(
            answers, first_response_delay_seconds
        )
        if side_while_parent_running
        else SequenceMockResponsesServer
    )
    with server_class([PARENT_ASSISTANT_TEXT, SIDE_ASSISTANT_TEXT]) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        parent_side_tui = run_parent_and_side_tui(
            tree_name,
            codex_bin,
            workspace,
            codex_home,
            chat_root,
            config_overrides,
            mock_server,
            slash_command,
            nested_side_command,
            side_while_parent_running,
        )
        source_thread_id = parent_side_tui["source_thread_id"]
        pre_side_thread_ids = parent_side_tui["pre_side_thread_ids"]
        pre_side_line_counts = parent_side_tui["pre_side_line_counts"]
        source_snapshot_before_side = parent_side_tui["source_snapshot_before_side"]
        post_side_thread_ids = thread_ids_for_tree(tree_name, codex_home, chat_root)
        post_side_line_counts = storage_line_counts(tree_name, codex_home, chat_root)
        source_snapshot_after_side = snapshot_thread(
            tree_name, codex_home, chat_root, source_thread_id
        )
        post_side_storage = (
            inspect_chat_packages(chat_root, source_thread_id)
            if tree_name == "chat-backend"
            else summarize_original_sessions(codex_home, source_thread_id)
        )
        durable_text_summary = summarize_storage_text(tree_name, codex_home, chat_root)

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "source_thread_id": source_thread_id,
        "parent_side_tui": parent_side_tui,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "pre_side_thread_ids": pre_side_thread_ids,
        "post_side_thread_ids": post_side_thread_ids,
        "pre_side_line_counts": pre_side_line_counts,
        "post_side_line_counts": post_side_line_counts,
        "source_snapshot_before_side": source_snapshot_before_side,
        "source_snapshot_after_side": source_snapshot_after_side,
        "source_durable_history_unchanged": (
            source_snapshot_before_side == source_snapshot_after_side
        ),
        "post_side_storage": post_side_storage,
        "durable_text_summary": durable_text_summary,
    }


def normalize_result(result: dict[str, Any]) -> dict[str, Any]:
    mock = result["mock_server_summary"]
    tui_result = result["parent_side_tui"]
    return {
        "tui_exit_ok": result["parent_side_tui"]["exit_code"] == 0,
        "parent_tui_reached_model": tui_result["parent_response_seen"],
        "parent_tui_assistant_visible": tui_result["parent_assistant_visible"],
        "side_tui_reached_model": tui_result["side_response_seen"],
        "side_tui_assistant_visible": tui_result["side_assistant_visible"],
        "side_prompt_sent_while_parent_running": tui_result[
            "side_prompt_sent_while_parent_running"
        ],
        "nested_side_rejection_visible": tui_result["nested_side_rejection_visible"],
        "mock": mock,
        "pre_side_thread_count": len(result["pre_side_thread_ids"]),
        "post_side_thread_count": len(result["post_side_thread_ids"]),
        "pre_side_line_counts": result["pre_side_line_counts"],
        "post_side_line_counts": result["post_side_line_counts"],
        "durable_threads_unchanged": result["pre_side_thread_ids"]
        == result["post_side_thread_ids"],
        "durable_line_counts_unchanged": result["pre_side_line_counts"]
        == result["post_side_line_counts"],
        "source_durable_history_unchanged": result["source_durable_history_unchanged"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=None,
    )
    parser.add_argument("--slash-command", choices=["side", "btw"], default="side")
    parser.add_argument("--nested-side-command", choices=["side", "btw"], default=None)
    parser.add_argument("--side-while-parent-running", action="store_true")
    parser.add_argument(
        "--first-response-delay-seconds",
        type=float,
        default=DEFAULT_PARENT_RUNNING_DELAY_SECONDS,
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    default_scope = f"cli-{args.slash_command}-fork-smoke"
    if args.side_while_parent_running:
        default_scope = f"cli-{args.slash_command}-running-parent-fork-smoke"
    if args.nested_side_command:
        default_scope = (
            f"cli-{args.slash_command}-nested-{args.nested_side_command}-rejection-smoke"
        )
    output_dir = (
        args.output_dir.resolve()
        if args.output_dir is not None
        else (
            validation_results_root()
            / (default_scope + "-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
        )
    )
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
        [],
        args.slash_command,
        args.nested_side_command,
        args.side_while_parent_running,
        args.first_response_delay_seconds,
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
        args.slash_command,
        args.nested_side_command,
        args.side_while_parent_running,
        args.first_response_delay_seconds,
    )

    original_normalized = normalize_result(original_result)
    chat_normalized = normalize_result(chat_result)
    original_mock = original_normalized["mock"]
    chat_mock = chat_normalized["mock"]

    if args.side_while_parent_running:
        no_extra_durable_threads = (
            original_normalized["pre_side_thread_count"] <= 1
            and chat_normalized["pre_side_thread_count"] <= 1
            and original_normalized["post_side_thread_count"]
            == chat_normalized["post_side_thread_count"]
            == 1
        )
    else:
        no_extra_durable_threads = (
            original_normalized["durable_threads_unchanged"]
            and chat_normalized["durable_threads_unchanged"]
            and original_normalized["pre_side_thread_count"]
            == original_normalized["post_side_thread_count"]
            == chat_normalized["pre_side_thread_count"]
            == chat_normalized["post_side_thread_count"]
            == 1
        )
    no_extra_durable_lines = (
        original_normalized["durable_line_counts_unchanged"]
        and chat_normalized["durable_line_counts_unchanged"]
        and original_normalized["post_side_line_counts"]
        == chat_normalized["post_side_line_counts"]
    )
    side_request_has_parent_user_context = (
        original_mock["side_body_contains_parent_user"]
        and chat_mock["side_body_contains_parent_user"]
    )
    side_request_has_completed_parent_assistant = (
        original_mock["side_body_contains_parent_assistant"]
        and chat_mock["side_body_contains_parent_assistant"]
    )
    side_request_has_side_prompt = (
        original_mock["side_body_contains_side_user"]
        and chat_mock["side_body_contains_side_user"]
    )
    side_request_has_boundary = (
        original_mock["side_body_contains_side_boundary"]
        and chat_mock["side_body_contains_side_boundary"]
    )

    chat_storage = chat_result["post_side_storage"]
    scope = f"cli-{args.slash_command}-fork-smoke"
    if args.side_while_parent_running:
        scope = f"cli-{args.slash_command}-running-parent-fork-smoke"
    if args.nested_side_command:
        scope = f"cli-{args.slash_command}-nested-{args.nested_side_command}-rejection-smoke"
    original_durable_text = original_result["durable_text_summary"]
    chat_durable_text = chat_result["durable_text_summary"]
    no_side_text_persisted = (
        not original_durable_text["contains_side_user"]
        and not original_durable_text["contains_side_assistant"]
        and not original_durable_text["contains_side_boundary"]
        and not chat_durable_text["contains_side_user"]
        and not chat_durable_text["contains_side_assistant"]
        and not chat_durable_text["contains_side_boundary"]
    )
    parent_durable_history_completed = (
        original_durable_text["contains_parent_user"]
        and original_durable_text["contains_parent_assistant"]
        and chat_durable_text["contains_parent_user"]
        and chat_durable_text["contains_parent_assistant"]
    )
    summary = {
        "generated_at": utc_now_iso(),
        "scope": scope,
        "slash_command": args.slash_command,
        "nested_side_command": args.nested_side_command,
        "side_while_parent_running": args.side_while_parent_running,
        "first_response_delay_seconds": (
            args.first_response_delay_seconds if args.side_while_parent_running else None
        ),
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original_tui_exit_ok": original_normalized["tui_exit_ok"],
        "chat_backend_tui_exit_ok": chat_normalized["tui_exit_ok"],
        "original_parent_tui_reached_model": original_normalized[
            "parent_tui_reached_model"
        ],
        "chat_backend_parent_tui_reached_model": chat_normalized[
            "parent_tui_reached_model"
        ],
        "original_parent_assistant_visible": original_normalized[
            "parent_tui_assistant_visible"
        ],
        "chat_backend_parent_assistant_visible": chat_normalized[
            "parent_tui_assistant_visible"
        ],
        "original_side_tui_reached_model": original_normalized["side_tui_reached_model"],
        "chat_backend_side_tui_reached_model": chat_normalized["side_tui_reached_model"],
        "original_side_assistant_visible": original_normalized["side_tui_assistant_visible"],
        "chat_backend_side_assistant_visible": chat_normalized[
            "side_tui_assistant_visible"
        ],
        "original_side_prompt_sent_while_parent_running": original_normalized[
            "side_prompt_sent_while_parent_running"
        ],
        "chat_backend_side_prompt_sent_while_parent_running": chat_normalized[
            "side_prompt_sent_while_parent_running"
        ],
        "original_nested_side_rejection_visible": original_normalized[
            "nested_side_rejection_visible"
        ],
        "chat_backend_nested_side_rejection_visible": chat_normalized[
            "nested_side_rejection_visible"
        ],
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 2
        ),
        "mock_side_context_equal": original_mock == chat_mock,
        "nested_side_did_not_reach_model": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 2
            and not original_mock["side_body_contains_nested_side_user"]
            and not chat_mock["side_body_contains_nested_side_user"]
        ),
        "side_request_has_parent_user_context": side_request_has_parent_user_context,
        "side_request_has_completed_parent_assistant": (
            side_request_has_completed_parent_assistant
        ),
        "side_request_has_parent_context": (
            side_request_has_parent_user_context
            and (
                args.side_while_parent_running
                or side_request_has_completed_parent_assistant
            )
        ),
        "side_request_has_side_prompt": side_request_has_side_prompt,
        "side_request_has_boundary": side_request_has_boundary,
        "no_extra_durable_threads": no_extra_durable_threads,
        "no_extra_durable_lines": no_extra_durable_lines,
        "no_side_text_persisted": no_side_text_persisted,
        "parent_durable_history_completed": parent_durable_history_completed,
        "original_source_durable_history_unchanged": original_normalized[
            "source_durable_history_unchanged"
        ],
        "chat_backend_source_durable_history_unchanged": chat_normalized[
            "source_durable_history_unchanged"
        ],
        "chat_package_count_after_side": chat_storage.get("package_count"),
        "chat_all_packages_have_standard_projections": chat_storage.get(
            "all_packages_have_standard_projections"
        ),
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "original": original_result,
        "chat_backend": chat_result,
        "passed": False,
    }
    summary["passed"] = all(
        [
            summary["original_parent_tui_reached_model"],
            summary["chat_backend_parent_tui_reached_model"],
            summary["original_parent_assistant_visible"],
            summary["chat_backend_parent_assistant_visible"],
            summary["original_side_tui_reached_model"],
            summary["chat_backend_side_tui_reached_model"],
            (
                not args.side_while_parent_running
                or summary["original_side_prompt_sent_while_parent_running"]
            ),
            (
                not args.side_while_parent_running
                or summary["chat_backend_side_prompt_sent_while_parent_running"]
            ),
            (
                args.nested_side_command is None
                or summary["original_nested_side_rejection_visible"]
            ),
            (
                args.nested_side_command is None
                or summary["chat_backend_nested_side_rejection_visible"]
            ),
            summary["mock_response_request_counts_equal"],
            summary["mock_side_context_equal"],
            (
                args.nested_side_command is None
                or summary["nested_side_did_not_reach_model"]
            ),
            summary["side_request_has_parent_context"],
            summary["side_request_has_side_prompt"],
            summary["side_request_has_boundary"],
            summary["no_extra_durable_threads"],
            (
                not args.side_while_parent_running
                and summary["no_extra_durable_lines"]
                and summary["original_source_durable_history_unchanged"]
                and summary["chat_backend_source_durable_history_unchanged"]
            )
            or (
                args.side_while_parent_running
                and summary["parent_durable_history_completed"]
                and summary["no_side_text_persisted"]
                and original_normalized["post_side_line_counts"]
                == chat_normalized["post_side_line_counts"]
            ),
            summary["chat_package_count_after_side"] == 1,
            summary["chat_all_packages_have_standard_projections"],
        ]
    )

    report_lines = [
        (
            f"# CLI `/{args.slash_command}` Nested `/{args.nested_side_command}` Rejection Smoke"
            if args.nested_side_command
            else (
                f"# CLI `/{args.slash_command}` Running-Parent Ephemeral Fork Smoke"
                if args.side_while_parent_running
                else f"# CLI `/{args.slash_command}` Ephemeral Fork Smoke"
            )
        ),
        "",
        f"Generated: `{summary['generated_at']}`",
        "",
        "This source-backed smoke covers one narrow user-facing path: create a parent",
        f"thread in the real TUI, submit `/{args.slash_command} ...`, and compare the original",
        "backend with the `.chat` backend.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Parent request reached model on original: `{summary['original_parent_tui_reached_model']}`",
        f"- Parent request reached model on `.chat`: `{summary['chat_backend_parent_tui_reached_model']}`",
        f"- `/{args.slash_command}` request reached model on original: `{summary['original_side_tui_reached_model']}`",
        f"- `/{args.slash_command}` request reached model on `.chat`: `{summary['chat_backend_side_tui_reached_model']}`",
        f"- `/{args.slash_command}` sent while parent running: `{args.side_while_parent_running}`",
        f"- Original sent side before parent assistant visible: `{summary['original_side_prompt_sent_while_parent_running']}`",
        f"- `.chat` sent side before parent assistant visible: `{summary['chat_backend_side_prompt_sent_while_parent_running']}`",
        f"- Nested side command: `{args.nested_side_command}`",
        f"- Nested side rejection visible on original: `{summary['original_nested_side_rejection_visible']}`",
        f"- Nested side rejection visible on `.chat`: `{summary['chat_backend_nested_side_rejection_visible']}`",
        f"- Nested side did not reach model: `{summary['nested_side_did_not_reach_model']}`",
        f"- Mock side context equal: `{summary['mock_side_context_equal']}`",
        f"- `/{args.slash_command}` request has parent context: `{summary['side_request_has_parent_context']}`",
        f"- `/{args.slash_command}` request has completed-parent assistant context: `{summary['side_request_has_completed_parent_assistant']}`",
        f"- `/{args.slash_command}` request has side boundary prompt: `{summary['side_request_has_boundary']}`",
        f"- No extra durable threads: `{summary['no_extra_durable_threads']}`",
        f"- No extra durable lines: `{summary['no_extra_durable_lines']}`",
        f"- Parent durable history completed: `{summary['parent_durable_history_completed']}`",
        f"- No side text persisted to parent durable storage: `{summary['no_side_text_persisted']}`",
        "",
        "## Evidence Boundary",
        "",
        f"This proves only the real TUI `/{args.slash_command}` path from "
        + (
            "a parent turn that was still running when the side prompt was submitted."
            if args.side_while_parent_running
            else "an already persisted parent thread."
        ),
    ]
    if args.nested_side_command:
        report_lines.extend(
            [
                "",
                f"It also proves only the real TUI nested `/{args.nested_side_command}`",
                "rejection path from inside that side conversation: both backends show",
                "the side-conversation rejection and do not send a third model request.",
            ]
        )
    report_lines.append("")
    if args.side_while_parent_running:
        report_lines.append(
            "It does not prove completed-parent side conversations, nested side-command "
            "rejection, side conversation cleanup failures, or final fork parity."
        )
    else:
        report_lines.extend(
            [
                "It does not prove side conversations started while the parent turn is",
                "still running, side conversation cleanup failures, or final fork parity.",
            ]
        )

    write_json(output_dir / "summary.json", summary)
    (output_dir / "report.md").write_text("\n".join(report_lines) + "\n")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
