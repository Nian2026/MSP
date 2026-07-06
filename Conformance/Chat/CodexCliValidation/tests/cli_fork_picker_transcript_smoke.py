#!/usr/bin/env python3
"""Run a real CLI fork-picker full-transcript overlay parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI picker slice:

    codex
      create a target interactive session
    codex
      create a decoy interactive session
    codex fork
      type a target-only picker search query
      press Ctrl+T to open the selected row transcript overlay
      wait for the loading frame and full transcript overlay content
      press Ctrl+T again to close the overlay
      press Enter to select the target
      type a fork prompt in the forked TUI

The overlay must expose the selected target transcript in both the original
backend and the `.chat` backend. The fork request must still contain target
history and exclude decoy history. This proves only a bounded fork-picker
transcript-overlay path; it is not final fork parity.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
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
from cli_exec_resume_smoke import SequenceMockResponsesServer  # noqa: E402
from cli_fork_picker_smoke import (  # noqa: E402
    COMPACT_DECOY_USER_TEXT,
    COMPACT_FORK_ASSISTANT_TEXT,
    COMPACT_FORK_USER_TEXT,
    COMPACT_TARGET_ASSISTANT_TEXT,
    COMPACT_TARGET_USER_TEXT,
    DECOY_ASSISTANT_TEXT,
    DECOY_USER_TEXT,
    FORK_ASSISTANT_TEXT,
    FORK_USER_TEXT,
    PICKER_QUERY,
    TARGET_ASSISTANT_TEXT,
    TARGET_USER_TEXT,
    compact,
    inspect_chat_packages,
    mock_request_summary,
    response_request_count,
    run_single_turn_tui,
    snapshot_thread,
    storage_line_counts,
    summarize_original_sessions,
    thread_ids_for_tree,
    wait_and_collect_tui,
)
from cli_resume_picker_search_smoke import write_typed_text  # noqa: E402


GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_preview_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_transcript_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/thread_transcript.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/thread_transcript.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def run_fork_picker_transcript_tui(
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

    state_local: dict[str, Any] = {
        "target_seen_before_query": False,
        "decoy_seen_before_query": False,
        "sent_query_text": False,
        "query_sent_at": None,
        "sent_open_transcript": False,
        "transcript_open_sent_at": None,
        "transcript_open_stripped_len": None,
        "sent_close_transcript": False,
        "transcript_close_sent_at": None,
        "transcript_close_stripped_len": None,
        "sent_accept": False,
        "accept_sent_at": None,
        "sent_fork_prompt_text": False,
        "fork_prompt_text_sent_at": None,
        "sent_fork_prompt_submit": False,
        "fork_prompt_sent_at": None,
        "fork_response_seen_at": None,
        "fork_assistant_visible_at": None,
        "transcript_loading_seen": False,
        "transcript_overlay_title_seen": False,
        "transcript_target_user_seen": False,
        "transcript_target_assistant_seen": False,
        "picker_seen_after_close": False,
        "transcript_after_open_tail": "",
        "transcript_after_close_tail": "",
    }

    def on_tick(master, _state, _visible, stripped, compact_tail) -> bool:
        compact_output = compact(stripped)
        if TARGET_USER_TEXT in stripped or COMPACT_TARGET_USER_TEXT in compact_output:
            state_local["target_seen_before_query"] = True
        if DECOY_USER_TEXT in stripped or COMPACT_DECOY_USER_TEXT in compact_output:
            state_local["decoy_seen_before_query"] = True

        if (
            not state_local["sent_query_text"]
            and state_local["target_seen_before_query"]
            and state_local["decoy_seen_before_query"]
            and "Forkaprevioussession" in compact_output
            and response_request_count(mock_server.requests) >= 2
        ):
            write_typed_text(master, PICKER_QUERY)
            state_local["sent_query_text"] = True
            state_local["query_sent_at"] = time.time()

        if (
            state_local["sent_query_text"]
            and not state_local["sent_open_transcript"]
            and state_local["query_sent_at"] is not None
            and time.time() - state_local["query_sent_at"] > 1.5
            and "Search:" in stripped
        ):
            state_local["transcript_open_stripped_len"] = len(stripped)
            os.write(master, b"\x14")
            state_local["sent_open_transcript"] = True
            state_local["transcript_open_sent_at"] = time.time()

        if state_local["sent_open_transcript"]:
            offset = state_local["transcript_open_stripped_len"] or 0
            after_open = stripped[offset:]
            compact_after_open = compact(after_open)
            state_local["transcript_after_open_tail"] = after_open[-3000:]
            state_local["transcript_loading_seen"] = state_local[
                "transcript_loading_seen"
            ] or (
                "Loading transcript" in after_open
                or "Loadingtranscript" in compact_after_open
            )
            state_local["transcript_overlay_title_seen"] = state_local[
                "transcript_overlay_title_seen"
            ] or (
                "T R A N S C R I P T" in after_open
                or "TRANSCRIPT" in compact_after_open
            )
            state_local["transcript_target_user_seen"] = state_local[
                "transcript_target_user_seen"
            ] or (
                TARGET_USER_TEXT in after_open
                or COMPACT_TARGET_USER_TEXT in compact_after_open
            )
            state_local["transcript_target_assistant_seen"] = state_local[
                "transcript_target_assistant_seen"
            ] or (
                TARGET_ASSISTANT_TEXT in after_open
                or COMPACT_TARGET_ASSISTANT_TEXT in compact_after_open
            )

        if (
            state_local["sent_open_transcript"]
            and not state_local["sent_close_transcript"]
            and state_local["transcript_open_sent_at"] is not None
            and time.time() - state_local["transcript_open_sent_at"] > 0.8
            and state_local["transcript_overlay_title_seen"]
            and state_local["transcript_target_user_seen"]
            and state_local["transcript_target_assistant_seen"]
        ):
            state_local["transcript_close_stripped_len"] = len(stripped)
            os.write(master, b"\x14")
            state_local["sent_close_transcript"] = True
            state_local["transcript_close_sent_at"] = time.time()

        if (
            state_local["sent_close_transcript"]
            and state_local["transcript_close_stripped_len"] is not None
        ):
            offset = state_local["transcript_close_stripped_len"] or 0
            after_close = stripped[offset:]
            state_local["transcript_after_close_tail"] = after_close[-1600:]
            state_local["picker_seen_after_close"] = state_local[
                "picker_seen_after_close"
            ] or "Search:" in after_close

        if (
            state_local["sent_close_transcript"]
            and not state_local["sent_accept"]
            and state_local["transcript_close_sent_at"] is not None
            and time.time() - state_local["transcript_close_sent_at"] > 0.8
            and state_local["picker_seen_after_close"]
        ):
            os.write(master, b"\r")
            state_local["sent_accept"] = True
            state_local["accept_sent_at"] = time.time()

        selected_or_started = (
            state_local["sent_accept"]
            and state_local["accept_sent_at"] is not None
            and time.time() - state_local["accept_sent_at"] > 1.0
            and (
                "Forkaprevioussession" not in compact_tail
                or TARGET_ASSISTANT_TEXT in stripped
                or COMPACT_TARGET_ASSISTANT_TEXT in compact_output
                or "Pressentertocontinue" in compact_tail
            )
        )
        if selected_or_started and not state_local["sent_fork_prompt_text"]:
            write_typed_text(master, FORK_USER_TEXT)
            state_local["sent_fork_prompt_text"] = True
            state_local["fork_prompt_text_sent_at"] = time.time()

        fork_prompt_visible = (
            FORK_USER_TEXT in stripped or COMPACT_FORK_USER_TEXT in compact_output
        )
        if (
            state_local["sent_fork_prompt_text"]
            and not state_local["sent_fork_prompt_submit"]
            and state_local["fork_prompt_text_sent_at"] is not None
            and time.time() - state_local["fork_prompt_text_sent_at"] > 0.5
            and fork_prompt_visible
        ):
            os.write(master, b"\r")
            state_local["sent_fork_prompt_submit"] = True
            state_local["fork_prompt_sent_at"] = time.time()

        requests_seen = response_request_count(mock_server.requests)
        if (
            state_local["sent_fork_prompt_submit"]
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
        loop_timeout_seconds=90,
        on_tick=on_tick,
    )
    result.update(
        {
            "target_seen_before_query": state_local["target_seen_before_query"],
            "decoy_seen_before_query": state_local["decoy_seen_before_query"],
            "sent_query_text": state_local["sent_query_text"],
            "sent_open_transcript": state_local["sent_open_transcript"],
            "sent_close_transcript": state_local["sent_close_transcript"],
            "transcript_loading_seen": state_local["transcript_loading_seen"],
            "transcript_overlay_title_seen": state_local[
                "transcript_overlay_title_seen"
            ],
            "transcript_target_user_seen": state_local["transcript_target_user_seen"],
            "transcript_target_assistant_seen": state_local[
                "transcript_target_assistant_seen"
            ],
            "picker_seen_after_close": state_local["picker_seen_after_close"],
            "sent_accept": state_local["sent_accept"],
            "sent_fork_prompt_text": state_local["sent_fork_prompt_text"],
            "sent_fork_prompt_submit": state_local["sent_fork_prompt_submit"],
            "fork_response_seen": state_local["fork_response_seen_at"] is not None,
            "fork_assistant_visible": state_local["fork_assistant_visible_at"]
            is not None,
            "transcript_after_open_tail": state_local["transcript_after_open_tail"],
            "transcript_after_close_tail": state_local["transcript_after_close_tail"],
        }
    )
    return result


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

        fork_picker_tui = run_fork_picker_transcript_tui(
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
    picker = result["fork_picker_tui"]
    return {
        "target_tui_exit_code": result["target_tui"]["exit_code"],
        "target_tui_sent_prompt": result["target_tui"]["sent_prompt"],
        "target_tui_response_seen": result["target_tui"]["response_seen"],
        "target_tui_assistant_visible": result["target_tui"]["assistant_visible"],
        "decoy_tui_exit_code": result["decoy_tui"]["exit_code"],
        "decoy_tui_sent_prompt": result["decoy_tui"]["sent_prompt"],
        "decoy_tui_response_seen": result["decoy_tui"]["response_seen"],
        "decoy_tui_assistant_visible": result["decoy_tui"]["assistant_visible"],
        "fork_picker_sent_query_text": picker["sent_query_text"],
        "fork_picker_sent_open_transcript": picker["sent_open_transcript"],
        "fork_picker_sent_close_transcript": picker["sent_close_transcript"],
        "fork_picker_transcript_loading_seen": picker["transcript_loading_seen"],
        "fork_picker_transcript_overlay_title_seen": picker[
            "transcript_overlay_title_seen"
        ],
        "fork_picker_transcript_target_user_seen": picker[
            "transcript_target_user_seen"
        ],
        "fork_picker_transcript_target_assistant_seen": picker[
            "transcript_target_assistant_seen"
        ],
        "fork_picker_seen_after_close": picker["picker_seen_after_close"],
        "fork_picker_sent_accept": picker["sent_accept"],
        "fork_picker_target_seen_before_query": picker["target_seen_before_query"],
        "fork_picker_decoy_seen_before_query": picker["decoy_seen_before_query"],
        "fork_picker_sent_fork_prompt_text": picker["sent_fork_prompt_text"],
        "fork_picker_sent_fork_prompt_submit": picker["sent_fork_prompt_submit"],
        "fork_picker_response_seen": picker["fork_response_seen"],
        "fork_picker_assistant_visible": picker["fork_assistant_visible"],
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
        "# CLI Fork Picker Transcript Overlay Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not complete fork picker parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Picker transcript loading frame seen: `{summary['picker_transcript_loading_seen']}`",
        f"- Picker transcript overlay title seen: `{summary['picker_transcript_overlay_title_seen']}`",
        f"- Picker transcript overlay showed target transcript content: `{summary['picker_transcript_target_content_seen']}`",
        f"- Picker returned to search UI after closing overlay: `{summary['picker_returned_after_close']}`",
        f"- Picker transcript path selected target history: `{summary['picker_selected_target_history']}`",
        f"- Picker transcript path excluded decoy history: `{summary['picker_excluded_decoy_history']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke creates target and decoy sessions through the ordinary interactive",
        "`codex` TUI, opens `codex fork`, searches the fork picker for the target,",
        "opens the selected row full transcript overlay with Ctrl+T, waits for",
        "loading/title and target transcript content, closes the overlay with Ctrl+T,",
        "selects the row, then sends a fork prompt in the forked TUI.",
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
            "cli-fork-picker-transcript-smoke-"
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

    picker_transcript_loading_seen = all(
        [
            original_normalized["fork_picker_transcript_loading_seen"],
            chat_normalized["fork_picker_transcript_loading_seen"],
        ]
    )
    picker_transcript_overlay_title_seen = all(
        [
            original_normalized["fork_picker_transcript_overlay_title_seen"],
            chat_normalized["fork_picker_transcript_overlay_title_seen"],
        ]
    )
    picker_transcript_target_content_seen = all(
        [
            original_normalized["fork_picker_transcript_target_user_seen"],
            original_normalized["fork_picker_transcript_target_assistant_seen"],
            chat_normalized["fork_picker_transcript_target_user_seen"],
            chat_normalized["fork_picker_transcript_target_assistant_seen"],
        ]
    )
    picker_returned_after_close = all(
        [
            original_normalized["fork_picker_seen_after_close"],
            chat_normalized["fork_picker_seen_after_close"],
        ]
    )
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
        "scope": "cli-fork-picker-transcript-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "picker_transcript_loading_seen": picker_transcript_loading_seen,
        "picker_transcript_overlay_title_seen": picker_transcript_overlay_title_seen,
        "picker_transcript_target_content_seen": picker_transcript_target_content_seen,
        "picker_returned_after_close": picker_returned_after_close,
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
            "This proves a narrow user-facing CLI fork picker transcript-overlay "
            "slice: ordinary interactive target and decoy sessions can be loaded "
            "into `codex fork`, typed picker search can focus the target session, "
            "Ctrl+T can open and close the selected row full transcript overlay "
            "with target transcript content, the forked TUI sends a prompt request "
            "containing target history and excluding decoy history, and original "
            "and .chat backends keep durable counts, source relation metadata, "
            "source histories, and standard .chat projection materialization "
            "aligned."
        ),
        "not_yet_proven": [
            "full visual fork picker parity across viewport sizes",
            "fork picker pagination beyond two loaded rows",
            "fork picker transcript overlay scrolling and long-history rendering",
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
            picker_transcript_loading_seen,
            picker_transcript_overlay_title_seen,
            picker_transcript_target_content_seen,
            picker_returned_after_close,
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
