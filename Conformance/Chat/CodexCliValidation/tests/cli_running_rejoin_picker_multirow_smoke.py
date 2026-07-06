#!/usr/bin/env python3
"""Run a real CLI/TUI resume-picker running rejoin parity smoke with two rows.

This source-backed validation covers a narrow user-facing Codex CLI path:

    codex                         # seed one completed interactive idle thread
    codex --remote <app-server>   # TUI A starts a second thread and keeps it running
    codex --remote <app-server> resume
                                  # TUI B opens the real resume picker, sees
                                  # both idle and running rows, searches, and
                                  # selects the running thread

The second TUI must attach to the already-running thread without causing a
duplicate model request. This fills only the multi-row picker/rejoin gap; it is
not a final R03 parity claim.
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
    MockResponsesServer,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import response_request_bodies  # noqa: E402


RUNNING_USER_TEXT = "CLI picker multirow running active user turn."
RUNNING_ASSISTANT_TEXT = "CLI picker multirow running delayed answer from mock model."
IDLE_DECOY_USER_TEXT = "CLI picker multirow idle decoy completed turn."
IDLE_DECOY_ASSISTANT_TEXT = "CLI picker multirow idle decoy answer from mock model."
PICKER_QUERY = "multirow running active"

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
    "Conformance/Chat/CodexCliValidation/tests/cli_running_rejoin_picker_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_running_rejoin_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_resume_picker_search_smoke.py",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/app-server/src/thread_state.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def visible_contains(tui: running.TuiProcess, text: str) -> bool:
    return text in tui.stripped() or running.compact(text) in tui.compact_output()


def ready_for_prompt_surface(
    compact_output: str,
    *,
    sent_trust_continue: bool,
) -> bool:
    trust_gate_done = (
        sent_trust_continue
        or "Doyoutrustthecontentsofthisdirectory?" not in compact_output
    )
    return (
        "OpenAICodex" in compact_output
        and "mock-model" in compact_output
        and trust_gate_done
    )


def local_tui_command(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    config_overrides: list[str],
) -> list[str]:
    command = [str(codex_bin)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.extend(["--cd", str(workspace)])
    return command


def storage_summary(tree_name: str, codex_home: pathlib.Path, chat_root: pathlib.Path) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return summarize_chat_packages(chat_root)
    return summarize_original_storage(codex_home)


def seed_idle_decoy_thread(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    with MockResponsesServer(IDLE_DECOY_ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        tui = running.TuiProcess(
            local_tui_command(codex_bin, workspace, config_overrides),
            workspace,
            codex_home,
        )
        state: dict[str, Any] = {
            "sent_decoy_prompt": False,
            "decoy_prompt_sent_at": None,
            "decoy_prompt_enter_retry_sent": False,
            "decoy_assistant_visible_at": None,
        }
        deadline = time.time() + 80
        while time.time() < deadline:
            tui.pump()
            compact_output = tui.compact_output()
            ready_for_prompt = (
                ready_for_prompt_surface(
                    compact_output,
                    sent_trust_continue=tui.state["sent_trust_continue"],
                )
                and not state["sent_decoy_prompt"]
            )
            if ready_for_prompt:
                running.type_prompt_and_enter(tui.master, IDLE_DECOY_USER_TEXT)
                state["sent_decoy_prompt"] = True
                state["decoy_prompt_sent_at"] = time.time()

            response_count = len(response_request_bodies(mock_server.requests))
            if (
                state["sent_decoy_prompt"]
                and response_count < 1
                and state["decoy_prompt_sent_at"] is not None
                and time.time() - state["decoy_prompt_sent_at"] > 2.0
                and not state["decoy_prompt_enter_retry_sent"]
            ):
                tui.write(b"\r")
                state["decoy_prompt_enter_retry_sent"] = True

            if (
                state["decoy_assistant_visible_at"] is None
                and visible_contains(tui, IDLE_DECOY_ASSISTANT_TEXT)
            ):
                state["decoy_assistant_visible_at"] = time.time()

            if (
                state["decoy_assistant_visible_at"] is not None
                and time.time() - state["decoy_assistant_visible_at"] > 0.8
            ):
                break

            if tui.process.poll() is not None:
                break
            time.sleep(0.05)

        tui_result = tui.close()
        bodies = response_request_bodies(mock_server.requests)
        first_body = bodies[0] if bodies else {}
        mock_summary = {
            "request_count": len(mock_server.requests),
            "response_request_count": len(bodies),
            "paths": [request.get("path") for request in mock_server.requests],
            "first_body_contains_idle_decoy_user": body_contains(
                first_body, IDLE_DECOY_USER_TEXT
            ),
        }

    return {
        "tui": tui_result,
        "state": state,
        "mock_server_summary": mock_summary,
    }


def chat_packages_multirow_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 2:
        return False
    for package in packages:
        event_types = set(package.get("timeline_event_types") or [])
        files = set(package.get("files") or [])
        if package.get("manifest_format") != "msp.chat":
            return False
        if package.get("timeline_line_count", 0) < 8:
            return False
        if package.get("journal_line_count", 0) < 8:
            return False
        if "message" not in event_types or "runtime_context_snapshot" not in event_types:
            return False
        if "projections/chat-read.ndjson" not in files:
            return False
        if "projections/model-context.ndjson" not in files:
            return False
        if "projections/audit.ndjson" not in files:
            return False
    return True


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

    decoy_seed = seed_idle_decoy_thread(codex_bin, workspace, codex_home, config_overrides)
    decoy_thread_ids = set(running.thread_ids_for_tree(tree_name, codex_home, chat_root))

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
                "target_thread_id": None,
                "started_second_tui_at": None,
                "picker_saw_running_user_before_query_at": None,
                "picker_saw_idle_decoy_before_query_at": None,
                "sent_picker_query_at": None,
                "second_running_user_visible_at": None,
                "second_running_assistant_visible_at": None,
                "first_running_assistant_visible_at": None,
            }
            deadline = time.time() + 110
            while time.time() < deadline:
                first_tui.pump()
                if second_tui is not None:
                    second_tui.pump()

                first_compact = first_tui.compact_output()
                first_stripped = first_tui.stripped()
                ready_for_prompt = (
                    ready_for_prompt_surface(
                        first_compact,
                        sent_trust_continue=first_tui.state["sent_trust_continue"],
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

                ids = set(running.thread_ids_for_tree(tree_name, codex_home, chat_root))
                target_ids = sorted(ids - decoy_thread_ids)
                if len(target_ids) == 1 and state["target_thread_id"] is None:
                    state["target_thread_id"] = target_ids[0]

                if (
                    state["first_model_request_seen_at"] is not None
                    and state["target_thread_id"] is not None
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
                        state["picker_saw_idle_decoy_before_query_at"] is None
                        and visible_contains(second_tui, IDLE_DECOY_USER_TEXT)
                    ):
                        state["picker_saw_idle_decoy_before_query_at"] = time.time()

                    if (
                        state["picker_saw_running_user_before_query_at"] is not None
                        and state["picker_saw_idle_decoy_before_query_at"] is not None
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
        "decoy_seed": decoy_seed,
        "decoy_thread_ids": sorted(decoy_thread_ids),
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
    decoy_mock = result["decoy_seed"]["mock_server_summary"]
    return {
        "decoy_seeded": result["decoy_seed"]["state"]["decoy_assistant_visible_at"] is not None,
        "decoy_thread_count": len(result["decoy_thread_ids"]),
        "decoy_mock_response_request_count": decoy_mock["response_request_count"],
        "decoy_mock_first_body_contains_idle_decoy_user": decoy_mock[
            "first_body_contains_idle_decoy_user"
        ],
        "sent_first_prompt": state["sent_first_prompt"],
        "first_model_request_seen": state["first_model_request_seen_at"] is not None,
        "target_thread_id_present": state["target_thread_id"] is not None,
        "started_second_tui": state["started_second_tui_at"] is not None,
        "picker_saw_running_user_before_query": (
            state["picker_saw_running_user_before_query_at"] is not None
        ),
        "picker_saw_idle_decoy_before_query": (
            state["picker_saw_idle_decoy_before_query_at"] is not None
        ),
        "sent_picker_query": state["sent_picker_query_at"] is not None,
        "second_running_user_visible": state["second_running_user_visible_at"] is not None,
        "second_running_assistant_visible": (
            state["second_running_assistant_visible_at"] is not None
        ),
        "first_running_assistant_visible": (
            state["first_running_assistant_visible_at"] is not None
        ),
        "running_mock_response_request_count": mock["response_request_count"],
        "running_mock_first_request_contains_running_user": mock[
            "first_response_input_contains_running_user_text"
        ],
        "durable_line_counts": result["durable_line_counts"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Running Rejoin Picker Multirow Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not final R03 parity and not final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Idle decoy seeded on both backends: `{summary['idle_decoy_seeded_both']}`",
        f"- Picker saw running and idle rows before search on both backends: `{summary['picker_saw_running_and_idle_rows_both']}`",
        f"- Picker query was submitted on both backends: `{summary['picker_query_submitted_both']}`",
        f"- Rejoined TUI saw final live assistant answer on both backends: `{summary['second_tui_saw_live_answer_both']}`",
        f"- Mock request counts show no duplicate running request: `{summary['running_mock_request_counts_equal_and_single']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        f"- `.chat` packages valid for this slice: `{summary['chat_packages_multirow_ok']}`",
        "",
        "## Scope",
        "",
        "The smoke first creates a completed interactive idle thread. It then",
        "starts a shared WebSocket app-server, launches a running thread in one",
        "real TUI, and opens `codex --remote <server> resume` in a second real",
        "TUI before the delayed response completes. The picker must show both",
        "the idle decoy and the running target before search. The typed search",
        "selects the running row, attaches to the live turn, receives the final",
        "assistant answer, and does not create a second running model request.",
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
            "cli-running-rejoin-picker-multirow-smoke-"
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
    idle_decoy_seeded_both = (
        original_normalized["decoy_seeded"] and chat_normalized["decoy_seeded"]
    )
    picker_saw_running_and_idle_rows_both = all(
        [
            original_normalized["picker_saw_running_user_before_query"],
            original_normalized["picker_saw_idle_decoy_before_query"],
            chat_normalized["picker_saw_running_user_before_query"],
            chat_normalized["picker_saw_idle_decoy_before_query"],
        ]
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
    running_mock_request_counts_equal_and_single = (
        original_normalized["running_mock_response_request_count"]
        == chat_normalized["running_mock_response_request_count"]
        == 1
    )
    decoy_mock_request_counts_equal_and_single = (
        original_normalized["decoy_mock_response_request_count"]
        == chat_normalized["decoy_mock_response_request_count"]
        == 1
    )
    durable_line_counts_equal = (
        original_normalized["durable_line_counts"]
        == chat_normalized["durable_line_counts"]
        and len(original_normalized["durable_line_counts"]) == 2
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-running-rejoin-picker-multirow-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "idle_decoy_seeded_both": idle_decoy_seeded_both,
        "picker_saw_running_and_idle_rows_both": picker_saw_running_and_idle_rows_both,
        "picker_query_submitted_both": picker_query_submitted_both,
        "second_tui_saw_live_answer_both": second_tui_saw_live_answer_both,
        "first_tui_saw_live_answer_both": first_tui_saw_live_answer_both,
        "running_mock_request_counts_equal_and_single": (
            running_mock_request_counts_equal_and_single
        ),
        "decoy_mock_request_counts_equal_and_single": (
            decoy_mock_request_counts_equal_and_single
        ),
        "durable_line_counts_equal": durable_line_counts_equal,
        "chat_packages_multirow_ok": chat_packages_multirow_ok(
            chat_result["storage_summary"]
        ),
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI/TUI resume-picker running "
            "rejoin slice with multiple rows: a completed interactive idle "
            "thread and an already-running thread both appear in the real "
            "remote resume picker, typed search selects the running thread, "
            "the second TUI attaches to the live answer, no duplicate running "
            "model request is made, and original-vs-.chat durable storage "
            "counts stay aligned."
        ),
        "not_yet_proven": [
            "full R03 running rejoin through every daemon/local/remote mode",
            "goal snapshot and token usage visual parity for this picker path",
            "stale path rejection and override warning through this picker path",
            "unload race behavior through this picker path",
            "picker pagination with running rows beyond this two-row case",
            "fork/rollback/compaction/list/search/archive parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    summary["passed"] = all(
        [
            normalized_summaries_equal,
            idle_decoy_seeded_both,
            picker_saw_running_and_idle_rows_both,
            picker_query_submitted_both,
            second_tui_saw_live_answer_both,
            first_tui_saw_live_answer_both,
            running_mock_request_counts_equal_and_single,
            decoy_mock_request_counts_equal_and_single,
            durable_line_counts_equal,
            summary["chat_packages_multirow_ok"],
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
