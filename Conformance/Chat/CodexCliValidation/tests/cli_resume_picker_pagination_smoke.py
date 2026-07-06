#!/usr/bin/env python3
"""Run a real CLI resume-picker pagination parity smoke.

This source-backed validation covers one narrow user-facing Codex CLI picker slice:

    fixture seed
      create one older target session
      create enough newer filler sessions to push the target past page one
    codex resume --include-non-interactive
      use End to trigger lazy pagination and jump to the older target
      select the target and send a follow-up prompt in the resumed TUI

The picker, pagination, selection, and resumed prompt run through the real TUI.
This proves only a bounded resume-picker pagination/select path; it is not
final picker/list/search parity or final user-indistinguishability evidence.
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
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
)
from cli_fork_picker_pagination_smoke import (  # noqa: E402
    iso_at,
    send_end,
    write_chat_seed_package,
    write_original_seed_session,
)
from cli_fork_picker_smoke import (  # noqa: E402
    compact,
    inspect_chat_packages,
    response_request_count,
    storage_line_counts,
    summarize_original_sessions,
    thread_ids_for_tree,
    wait_and_collect_tui,
)
FILLER_COUNT = 25
TARGET_MARKER = "RESUME_PAGINATION_TARGET_MARKER"
FILLER_MARKER_PREFIX = "RESUME_PAGINATION_FILLER_MARKER_"
TARGET_USER_TEXT = (
    f"{TARGET_MARKER} older target session for resume picker pagination."
)
TARGET_ASSISTANT_TEXT = "Resume pagination target answer from mock model."
FOLLOWUP_USER_TEXT = "CLI resume picker pagination selected target follow-up."
FOLLOWUP_ASSISTANT_TEXT = "CLI resume picker pagination answer from mock model."
NEWEST_FILLER_MARKER = f"{FILLER_MARKER_PREFIX}{FILLER_COUNT:02d}"
OLDEST_FILLER_MARKER = f"{FILLER_MARKER_PREFIX}01"

COMPACT_FOLLOWUP_ASSISTANT_TEXT = compact(FOLLOWUP_ASSISTANT_TEXT)
COMPACT_FOLLOWUP_USER_TEXT = compact(FOLLOWUP_USER_TEXT)

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
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_transcript_scroll_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_pagination_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def filler_marker(index: int) -> str:
    return f"{FILLER_MARKER_PREFIX}{index:02d}"


def filler_user_text(index: int) -> str:
    return (
        f"{filler_marker(index)} newer filler session {index:02d} for "
        "resume picker pagination."
    )


def filler_assistant_text(index: int) -> str:
    return f"Resume pagination filler answer {index:02d} from mock model."


def seeded_thread_id(index: int) -> str:
    import uuid

    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"msp-chat-resume-pagination-{index:02d}"))


def seed_source_sessions(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    workspace: pathlib.Path,
) -> dict[str, Any]:
    base = dt.datetime(2026, 7, 2, 13, 0, 0, tzinfo=dt.timezone.utc)
    seeded: list[dict[str, Any]] = []

    target_id = seeded_thread_id(0)
    target_timestamp = iso_at(base, 0)
    if tree_name == "chat-backend":
        target_path = write_chat_seed_package(
            chat_root,
            workspace,
            target_id,
            target_timestamp,
            TARGET_USER_TEXT,
            TARGET_ASSISTANT_TEXT,
        )
    else:
        target_path = write_original_seed_session(
            codex_home,
            workspace,
            target_id,
            target_timestamp,
            TARGET_USER_TEXT,
            TARGET_ASSISTANT_TEXT,
        )
    seeded.append(
        {
            "index": 0,
            "role": "target",
            "thread_id": target_id,
            "path": str(target_path),
            "created_at": target_timestamp,
            "user_text": TARGET_USER_TEXT,
            "assistant_text": TARGET_ASSISTANT_TEXT,
        }
    )

    for index in range(1, FILLER_COUNT + 1):
        thread_id = seeded_thread_id(index)
        timestamp = iso_at(base, index)
        if tree_name == "chat-backend":
            path = write_chat_seed_package(
                chat_root,
                workspace,
                thread_id,
                timestamp,
                filler_user_text(index),
                filler_assistant_text(index),
            )
        else:
            path = write_original_seed_session(
                codex_home,
                workspace,
                thread_id,
                timestamp,
                filler_user_text(index),
                filler_assistant_text(index),
            )
        seeded.append(
            {
                "index": index,
                "role": "filler",
                "thread_id": thread_id,
                "path": str(path),
                "created_at": timestamp,
                "user_text": filler_user_text(index),
                "assistant_text": filler_assistant_text(index),
            }
        )

    return {
        "target_thread_id": target_id,
        "seeded_count": len(seeded),
        "seeded": seeded,
    }


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def compact_contains(text: str, compact_text: str, needle: str) -> bool:
    return needle in text or compact(needle) in compact_text


def run_resume_picker_pagination_tui(
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

    state_local: dict[str, Any] = {
        "newest_filler_seen_before_pagination": False,
        "target_seen_before_pagination": False,
        "target_seen_after_pagination": False,
        "sent_end_count": 0,
        "last_end_sent_at": None,
        "sent_accept": False,
        "accept_sent_at": None,
        "sent_followup_prompt": False,
        "sent_followup_submit": False,
        "followup_prompt_sent_at": None,
        "followup_submit_sent_at": None,
        "followup_response_seen_at": None,
        "followup_assistant_visible_at": None,
        "pagination_tail": "",
    }

    def on_tick(master, _state, _visible, stripped, compact_tail) -> bool:
        compact_output = compact(stripped)
        picker_visible = "Resumeaprevioussession" in compact_output

        target_visible = compact_contains(stripped, compact_output, TARGET_MARKER)
        newest_filler_visible = compact_contains(
            stripped, compact_output, NEWEST_FILLER_MARKER
        )

        if picker_visible and newest_filler_visible and state_local["sent_end_count"] == 0:
            state_local["newest_filler_seen_before_pagination"] = True
            state_local["target_seen_before_pagination"] = target_visible
            send_end(master)
            state_local["sent_end_count"] += 1
            state_local["last_end_sent_at"] = time.time()

        if (
            picker_visible
            and state_local["sent_end_count"] > 0
            and not target_visible
            and state_local["last_end_sent_at"] is not None
            and time.time() - state_local["last_end_sent_at"] > 0.9
            and state_local["sent_end_count"] < 8
        ):
            send_end(master)
            state_local["sent_end_count"] += 1
            state_local["last_end_sent_at"] = time.time()

        if (
            picker_visible
            and target_visible
            and state_local["sent_end_count"] < 2
            and state_local["last_end_sent_at"] is not None
            and time.time() - state_local["last_end_sent_at"] > 0.4
        ):
            send_end(master)
            state_local["sent_end_count"] += 1
            state_local["last_end_sent_at"] = time.time()

        if (
            picker_visible
            and target_visible
            and state_local["sent_end_count"] >= 2
            and not state_local["sent_accept"]
            and state_local["last_end_sent_at"] is not None
            and time.time() - state_local["last_end_sent_at"] > 0.7
        ):
            state_local["target_seen_after_pagination"] = True
            state_local["pagination_tail"] = stripped[-2400:]
            os.write(master, b"\r")
            state_local["sent_accept"] = True
            state_local["accept_sent_at"] = time.time()

        selected_or_started = (
            state_local["sent_accept"]
            and state_local["accept_sent_at"] is not None
            and time.time() - state_local["accept_sent_at"] > 1.0
            and (
                "Resumeaprevioussession" not in compact_tail
                or TARGET_ASSISTANT_TEXT in stripped
                or "Pressentertocontinue" in compact_tail
            )
        )
        if selected_or_started and not state_local["sent_followup_prompt"]:
            os.write(master, FOLLOWUP_USER_TEXT.encode("utf-8"))
            state_local["sent_followup_prompt"] = True
            state_local["followup_prompt_sent_at"] = time.time()

        followup_text_visible = (
            FOLLOWUP_USER_TEXT in stripped
            or COMPACT_FOLLOWUP_USER_TEXT in compact_output
        )
        if (
            state_local["sent_followup_prompt"]
            and not state_local["sent_followup_submit"]
            and state_local["followup_prompt_sent_at"] is not None
            and time.time() - state_local["followup_prompt_sent_at"] > 0.5
            and followup_text_visible
        ):
            os.write(master, b"\r")
            state_local["sent_followup_submit"] = True
            state_local["followup_submit_sent_at"] = time.time()

        requests_seen = response_request_count(mock_server.requests)
        if (
            state_local["sent_followup_submit"]
            and requests_seen >= 1
            and state_local["followup_response_seen_at"] is None
        ):
            state_local["followup_response_seen_at"] = time.time()

        if (
            state_local["followup_response_seen_at"] is not None
            and (
                FOLLOWUP_ASSISTANT_TEXT in stripped
                or COMPACT_FOLLOWUP_ASSISTANT_TEXT in compact_output
            )
            and state_local["followup_assistant_visible_at"] is None
        ):
            state_local["followup_assistant_visible_at"] = time.time()

        if (
            state_local["followup_response_seen_at"] is not None
            and time.time() - state_local["followup_response_seen_at"] > 2.0
        ):
            return True
        return False

    result = wait_and_collect_tui(
        command,
        workspace,
        codex_home,
        loop_timeout_seconds=120,
        on_tick=on_tick,
    )
    result.update(
        {
            "newest_filler_seen_before_pagination": state_local[
                "newest_filler_seen_before_pagination"
            ],
            "target_seen_before_pagination": state_local[
                "target_seen_before_pagination"
            ],
            "target_seen_after_pagination": state_local[
                "target_seen_after_pagination"
            ],
            "sent_end_count": state_local["sent_end_count"],
            "sent_accept": state_local["sent_accept"],
            "sent_followup_prompt": state_local["sent_followup_prompt"],
            "sent_followup_submit": state_local["sent_followup_submit"],
            "followup_response_seen": state_local["followup_response_seen_at"] is not None,
            "followup_assistant_visible": state_local[
                "followup_assistant_visible_at"
            ]
            is not None,
            "pagination_tail": state_local["pagination_tail"],
        }
    )
    return result


def mock_request_summary(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    followup_body = bodies[0] if bodies else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "followup_body_contains_target_marker": body_contains(
            followup_body, TARGET_MARKER
        ),
        "followup_body_contains_target_assistant": body_contains(
            followup_body, TARGET_ASSISTANT_TEXT
        ),
        "followup_body_contains_followup_user": body_contains(
            followup_body, FOLLOWUP_USER_TEXT
        ),
        "followup_body_contains_newest_filler_marker": body_contains(
            followup_body, NEWEST_FILLER_MARKER
        ),
        "followup_body_contains_oldest_filler_marker": body_contains(
            followup_body, OLDEST_FILLER_MARKER
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

    seed_summary = seed_source_sessions(tree_name, codex_home, chat_root, workspace)
    target_thread_id = seed_summary["target_thread_id"]
    pre_resume_ids = thread_ids_for_tree(tree_name, codex_home, chat_root)
    pre_resume_line_counts = storage_line_counts(tree_name, codex_home, chat_root)

    with SequenceMockResponsesServer([FOLLOWUP_ASSISTANT_TEXT]) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        picker_tui = run_resume_picker_pagination_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )
        post_resume_ids = thread_ids_for_tree(tree_name, codex_home, chat_root)
        post_resume_line_counts = storage_line_counts(tree_name, codex_home, chat_root)
        mock_summary = mock_request_summary(mock_server.requests)

    post_resume_storage = (
        inspect_chat_packages(chat_root, target_thread_id)
        if tree_name == "chat-backend"
        else summarize_original_sessions(codex_home, target_thread_id)
    )

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "seed_summary": seed_summary,
        "target_thread_id": target_thread_id,
        "pre_resume_thread_ids": pre_resume_ids,
        "post_resume_thread_ids": post_resume_ids,
        "pre_resume_line_counts": pre_resume_line_counts,
        "post_resume_line_counts": post_resume_line_counts,
        "picker_tui": picker_tui,
        "mock_server_summary": mock_summary,
        "post_resume_storage": post_resume_storage,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    seed_summary = result["seed_summary"]
    return {
        "seeded_count": seed_summary["seeded_count"],
        "target_seeded": bool(seed_summary["target_thread_id"]),
        "filler_count": seed_summary["seeded_count"] - 1,
        "all_fillers_seeded": all(
            item.get("thread_id")
            for item in seed_summary["seeded"]
            if item["role"] == "filler"
        ),
        "resume_picker_newest_filler_seen_before_pagination": result["picker_tui"][
            "newest_filler_seen_before_pagination"
        ],
        "resume_picker_target_seen_before_pagination": result["picker_tui"][
            "target_seen_before_pagination"
        ],
        "resume_picker_target_seen_after_pagination": result["picker_tui"][
            "target_seen_after_pagination"
        ],
        "resume_picker_sent_end_count": result["picker_tui"]["sent_end_count"],
        "resume_picker_sent_accept": result["picker_tui"]["sent_accept"],
        "resume_picker_sent_followup_prompt": result["picker_tui"][
            "sent_followup_prompt"
        ],
        "resume_picker_sent_followup_submit": result["picker_tui"][
            "sent_followup_submit"
        ],
        "resume_picker_response_seen": result["picker_tui"][
            "followup_response_seen"
        ],
        "resume_picker_assistant_visible": result["picker_tui"][
            "followup_assistant_visible"
        ],
        "target_thread_created": result["target_thread_id"] is not None,
        "thread_ids_unchanged": result["pre_resume_thread_ids"]
        == result["post_resume_thread_ids"],
        "mock": result["mock_server_summary"],
        "post_resume_line_counts": result["post_resume_line_counts"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Resume Picker Pagination Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not complete resume picker parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Target absent before pagination: `{summary['target_absent_before_pagination']}`",
        f"- Target visible after pagination: `{summary['target_visible_after_pagination']}`",
        f"- Picker selected target history: `{summary['picker_selected_target_history']}`",
        f"- Picker excluded filler history: `{summary['picker_excluded_filler_history']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke seeds one older target session and",
        f"{FILLER_COUNT} newer filler sessions, opens",
        "`codex resume --include-non-interactive`, uses End to trigger lazy",
        "pagination and jump to the target row, selects that row, then sends a",
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
            "cli-resume-picker-pagination-smoke-"
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

    target_absent_before_pagination = (
        not original_normalized["resume_picker_target_seen_before_pagination"]
        and not chat_normalized["resume_picker_target_seen_before_pagination"]
    )
    target_visible_after_pagination = (
        original_normalized["resume_picker_target_seen_after_pagination"]
        and chat_normalized["resume_picker_target_seen_after_pagination"]
    )
    picker_selected_target_history = all(
        [
            original_normalized["mock"]["followup_body_contains_target_marker"],
            original_normalized["mock"]["followup_body_contains_target_assistant"],
            original_normalized["mock"]["followup_body_contains_followup_user"],
            chat_normalized["mock"]["followup_body_contains_target_marker"],
            chat_normalized["mock"]["followup_body_contains_target_assistant"],
            chat_normalized["mock"]["followup_body_contains_followup_user"],
        ]
    )
    picker_excluded_filler_history = not any(
        [
            original_normalized["mock"]["followup_body_contains_newest_filler_marker"],
            original_normalized["mock"]["followup_body_contains_oldest_filler_marker"],
            chat_normalized["mock"]["followup_body_contains_newest_filler_marker"],
            chat_normalized["mock"]["followup_body_contains_oldest_filler_marker"],
        ]
    )
    durable_line_counts_equal = (
        original_normalized["post_resume_line_counts"]
        == chat_normalized["post_resume_line_counts"]
        and len(original_normalized["post_resume_line_counts"]) == FILLER_COUNT + 1
    )
    normalized_summaries_equal = original_normalized == chat_normalized

    chat_post_storage = chat_result["post_resume_storage"]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-resume-picker-pagination-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "filler_count": FILLER_COUNT,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "target_absent_before_pagination": target_absent_before_pagination,
        "target_visible_after_pagination": target_visible_after_pagination,
        "picker_selected_target_history": picker_selected_target_history,
        "picker_excluded_filler_history": picker_excluded_filler_history,
        "durable_line_counts_equal": durable_line_counts_equal,
        "chat_package_count": chat_post_storage.get("package_count"),
        "chat_package_count_is_expected": chat_post_storage.get("package_count")
        == FILLER_COUNT + 1,
        "chat_packages_have_standard_projections": chat_post_storage.get(
            "all_packages_have_standard_projections"
        ),
        "thread_ids_unchanged": original_normalized["thread_ids_unchanged"]
        and chat_normalized["thread_ids_unchanged"],
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI resume picker pagination slice: "
            "an older target session can be pushed beyond the first picker page "
            "by newer filler sessions, reached through lazy pagination in "
            "`codex resume --include-non-interactive`, selected, and resumed with "
            "original and .chat backends preserving target history, excluding "
            "filler history, keeping thread identities stable, and keeping "
            "durable line counts aligned."
        ),
        "not_yet_proven": [
            "full visual resume picker parity across viewport sizes",
            "resume picker pagination beyond this oldest-row End-key path",
            "arbitrary resume picker overlay scroll positions beyond Home/End",
            "fork picker pagination beyond the covered fork paths",
            "running-thread picker/rejoin parity",
            "broader CLI list/search behavior",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }

    summary["passed"] = all(
        [
            normalized_summaries_equal,
            target_absent_before_pagination,
            target_visible_after_pagination,
            picker_selected_target_history,
            picker_excluded_filler_history,
            durable_line_counts_equal,
            summary["chat_package_count_is_expected"],
            summary["chat_packages_have_standard_projections"],
            summary["thread_ids_unchanged"],
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
