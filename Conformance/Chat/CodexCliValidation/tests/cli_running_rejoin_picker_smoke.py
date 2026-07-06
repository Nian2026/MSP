#!/usr/bin/env python3
"""Run a real CLI/TUI resume-picker running-thread rejoin parity smoke.

This source-backed validation covers a narrow user-facing Codex CLI path:

    codex --remote <app-server>       # TUI A starts a turn and keeps it running
    codex --remote <app-server> resume
                                      # TUI B opens the real resume picker,
                                      # searches, and selects the running thread

The first TUI uses a shared WebSocket app-server and a delayed mock Responses
API. The second TUI opens the real resume picker before the delayed model
response completes, selects the already-loaded running thread through the picker,
and must attach without causing another model request.

This is not a final parity claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

import cli_running_rejoin_smoke as running  # noqa: E402
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


RUNNING_USER_TEXT = "CLI picker running rejoin active user turn."
RUNNING_ASSISTANT_TEXT = "CLI picker running rejoin delayed answer from mock model."
PICKER_QUERY = "picker running rejoin active"

running.RUNNING_USER_TEXT = RUNNING_USER_TEXT
running.RUNNING_ASSISTANT_TEXT = RUNNING_ASSISTANT_TEXT

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_running_rejoin_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_search_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/app-server/src/thread_state.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def visible_contains(tui: running.TuiProcess, text: str) -> bool:
    return text in tui.stripped() or running.compact(text) in tui.compact_output()


def storage_summary(tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return summarize_chat_packages(chat_root)
    return summarize_original_storage(codex_home)


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

    with running.DelayedMockResponsesServer(delay_seconds=8.0) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        app_server = running.AppServerProcess(codex_bin, workspace, codex_home, config_overrides)
        first_tui: running.TuiProcess | None = None
        second_tui: running.TuiProcess | None = None
        app_server_exit: int | None = None
        try:
            remote_url = app_server.wait_for_remote_url()
            first_tui = running.TuiProcess(
                running.tui_command(codex_bin, workspace, config_overrides, remote_url),
                workspace,
                codex_home,
            )

            state: dict[str, Any] = {
                "sent_first_prompt": False,
                "first_prompt_sent_at": None,
                "first_prompt_enter_retry_sent": False,
                "first_model_request_seen_at": None,
                "thread_id": None,
                "started_second_tui_at": None,
                "picker_saw_running_user_before_query_at": None,
                "sent_picker_query_at": None,
                "second_running_user_visible_at": None,
                "second_running_assistant_visible_at": None,
                "first_running_assistant_visible_at": None,
            }
            deadline = time.time() + 100
            while time.time() < deadline:
                first_tui.pump()
                if second_tui is not None:
                    second_tui.pump()

                first_compact = first_tui.compact_output()
                first_stripped = first_tui.stripped()
                ready_for_prompt = (
                    "OpenAICodex" in first_compact
                    and "mock-model" in first_compact
                    and (
                        "Togetstarted" in first_compact
                        or "/init-createanAGENTS" in first_compact
                    )
                    and (
                        first_tui.state["sent_trust_continue"]
                        or "Doyoutrustthecontentsofthisdirectory?" not in first_compact
                    )
                    and not state["sent_first_prompt"]
                )
                if ready_for_prompt:
                    running.type_prompt_and_enter(first_tui.master, RUNNING_USER_TEXT)
                    state["sent_first_prompt"] = True
                    state["first_prompt_sent_at"] = time.time()

                response_count = mock_server.summary()["response_request_count"]
                if (
                    state["sent_first_prompt"]
                    and response_count < 1
                    and state["first_prompt_sent_at"] is not None
                    and time.time() - state["first_prompt_sent_at"] > 2.0
                    and not state["first_prompt_enter_retry_sent"]
                ):
                    first_tui.write(b"\r")
                    state["first_prompt_enter_retry_sent"] = True

                if response_count >= 1 and state["first_model_request_seen_at"] is None:
                    state["first_model_request_seen_at"] = time.time()

                ids = running.thread_ids_for_tree(tree_name, codex_home, chat_root)
                if len(ids) == 1 and state["thread_id"] is None:
                    state["thread_id"] = ids[0]

                if (
                    state["first_model_request_seen_at"] is not None
                    and state["thread_id"] is not None
                    and second_tui is None
                ):
                    second_tui = running.TuiProcess(
                        running.tui_command(
                            codex_bin,
                            workspace,
                            config_overrides,
                            remote_url,
                            ["resume"],
                        ),
                        workspace,
                        codex_home,
                    )
                    state["started_second_tui_at"] = time.time()

                if second_tui is not None:
                    if (
                        state["picker_saw_running_user_before_query_at"] is None
                        and visible_contains(second_tui, RUNNING_USER_TEXT)
                    ):
                        state["picker_saw_running_user_before_query_at"] = time.time()

                    if (
                        state["picker_saw_running_user_before_query_at"] is not None
                        and state["sent_picker_query_at"] is None
                    ):
                        running.write_typed_text(second_tui.master, PICKER_QUERY)
                        second_tui.write(b"\r")
                        state["sent_picker_query_at"] = time.time()

                    if (
                        state["second_running_user_visible_at"] is None
                        and state["sent_picker_query_at"] is not None
                        and visible_contains(second_tui, RUNNING_USER_TEXT)
                    ):
                        state["second_running_user_visible_at"] = time.time()

                    if (
                        state["second_running_assistant_visible_at"] is None
                        and visible_contains(second_tui, RUNNING_ASSISTANT_TEXT)
                    ):
                        state["second_running_assistant_visible_at"] = time.time()

                if (
                    state["first_running_assistant_visible_at"] is None
                    and (
                        RUNNING_ASSISTANT_TEXT in first_stripped
                        or running.compact(RUNNING_ASSISTANT_TEXT) in first_compact
                    )
                ):
                    state["first_running_assistant_visible_at"] = time.time()

                if (
                    state["second_running_assistant_visible_at"] is not None
                    and state["first_running_assistant_visible_at"] is not None
                    and time.time() - state["second_running_assistant_visible_at"] > 1.0
                ):
                    break

                if first_tui.process.poll() is not None:
                    break
                time.sleep(0.05)

            first_result = first_tui.close()
            second_result = (
                second_tui.close()
                if second_tui is not None
                else {"not_started": True}
            )
        finally:
            app_server_exit = app_server.close()

        mock_summary = mock_server.summary()

    final_storage_summary = storage_summary(tree_name, codex_home, chat_root)
    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "app_server": {
            "command": app_server.command,
            "exit_code": app_server_exit,
            "stderr_tail": app_server.stderr_tail(),
        },
        "first_tui": first_result,
        "second_tui": second_result,
        "state": state,
        "mock_server_summary": mock_summary,
        "durable_line_counts": running.durable_line_counts(tree_name, codex_home, chat_root),
        "storage_summary": final_storage_summary,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    state = result["state"]
    mock = result["mock_server_summary"]
    return {
        "sent_first_prompt": state["sent_first_prompt"],
        "first_model_request_seen": state["first_model_request_seen_at"] is not None,
        "thread_id_present": state["thread_id"] is not None,
        "started_second_tui": state["started_second_tui_at"] is not None,
        "picker_saw_running_user_before_query": (
            state["picker_saw_running_user_before_query_at"] is not None
        ),
        "sent_picker_query": state["sent_picker_query_at"] is not None,
        "second_running_user_visible": state["second_running_user_visible_at"] is not None,
        "second_running_assistant_visible": (
            state["second_running_assistant_visible_at"] is not None
        ),
        "first_running_assistant_visible": (
            state["first_running_assistant_visible_at"] is not None
        ),
        "mock_response_request_count": mock["response_request_count"],
        "mock_first_request_contains_running_user": mock[
            "first_response_input_contains_running_user_text"
        ],
        "durable_line_counts": result["durable_line_counts"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Running Rejoin Picker Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final R03 parity and not final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Picker saw the running user message before selection on both backends: `{summary['picker_saw_running_user_before_query_both']}`",
        f"- Picker query was submitted on both backends: `{summary['picker_query_submitted_both']}`",
        f"- Rejoined TUI saw final live assistant answer on both backends: `{summary['second_tui_saw_live_answer_both']}`",
        f"- Mock request counts equal and not duplicated: `{summary['mock_request_counts_equal_and_single']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        f"- `.chat` package valid for this slice: `{summary['chat_package_running_rejoin_ok']}`",
        "",
        "## Scope",
        "",
        "The smoke starts a shared WebSocket app-server, launches one real TUI to",
        "start a delayed model turn, then launches a second real TUI with",
        "`codex --remote <server> resume` before the delayed response completes.",
        "The second TUI must load the real resume picker, show the running user",
        "message, accept a typed picker search query, select the running thread,",
        "and receive the eventual assistant answer without causing another model",
        "request.",
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
            "cli-running-rejoin-picker-smoke-"
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
    normalized_summaries_equal = original_normalized == chat_normalized
    durable_line_counts_equal = (
        original_normalized["durable_line_counts"]
        == chat_normalized["durable_line_counts"]
        and len(original_normalized["durable_line_counts"]) == 1
    )
    mock_request_counts_equal_and_single = (
        original_normalized["mock_response_request_count"]
        == chat_normalized["mock_response_request_count"]
        == 1
    )
    picker_saw_running_user_before_query_both = (
        original_normalized["picker_saw_running_user_before_query"]
        and chat_normalized["picker_saw_running_user_before_query"]
    )
    picker_query_submitted_both = (
        original_normalized["sent_picker_query"] and chat_normalized["sent_picker_query"]
    )
    second_tui_saw_live_answer_both = (
        original_normalized["second_running_assistant_visible"]
        and chat_normalized["second_running_assistant_visible"]
    )
    first_tui_saw_live_answer_both = (
        original_normalized["first_running_assistant_visible"]
        and chat_normalized["first_running_assistant_visible"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-running-rejoin-picker-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "picker_saw_running_user_before_query_both": (
            picker_saw_running_user_before_query_both
        ),
        "picker_query_submitted_both": picker_query_submitted_both,
        "second_tui_saw_live_answer_both": second_tui_saw_live_answer_both,
        "first_tui_saw_live_answer_both": first_tui_saw_live_answer_both,
        "mock_request_counts_equal_and_single": mock_request_counts_equal_and_single,
        "durable_line_counts_equal": durable_line_counts_equal,
        "chat_package_running_rejoin_ok": running.chat_package_running_rejoin_ok(
            chat_result["storage_summary"]
        ),
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI/TUI resume-picker running "
            "rejoin slice: a second real TUI can open the real resume picker "
            "against a shared remote app-server, find and select an already "
            "running thread, receive the eventual assistant answer, avoid a "
            "duplicate model request, and keep original-vs-.chat durable "
            "storage counts aligned."
        ),
        "not_yet_proven": [
            "full R03 running rejoin through every daemon/local/remote mode",
            "resume-picker running rejoin with multiple running/idle rows",
            "goal snapshot and token usage visual parity for this picker path",
            "stale path rejection and override warning through this picker path",
            "unload race behavior through this picker path",
            "fork/rollback/compaction/list/search/archive parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    summary["passed"] = all(
        [
            normalized_summaries_equal,
            picker_saw_running_user_before_query_both,
            picker_query_submitted_both,
            second_tui_saw_live_answer_both,
            first_tui_saw_live_answer_both,
            mock_request_counts_equal_and_single,
            durable_line_counts_equal,
            summary["chat_package_running_rejoin_ok"],
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
