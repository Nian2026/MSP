#!/usr/bin/env python3
"""Run world-state rollback-after-compaction parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It extends the narrow K04 world-state
full/patch smoke across a rollback-after-compaction boundary:

1. start a remote-environment thread;
2. complete a first turn that triggers context compaction and records full
   world-state snapshots;
3. complete a second turn after the remote environment reports `zsh`, causing a
   world-state patch;
4. roll back the second turn;
5. cold-resume the thread and complete a final turn.

The original backend is the oracle. This is not final Codex parity evidence.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_resume_smoke import send_thread_resume  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    read_json_lines,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from app_server_fork_smoke import response_request_bodies  # noqa: E402
from app_server_rollback_smoke import (  # noqa: E402
    count_rollback_markers,
    send_thread_list,
    send_thread_rollback,
    storage_line_counts,
)
from app_server_world_state_full_patch_smoke import (  # noqa: E402
    COMPACTION_SUMMARY_TEXT,
    COMPACT_PROMPT,
    FIRST_FINAL_TEXT,
    FIRST_USER_TEXT,
    MiniExecServer,
    REMOTE_ENVIRONMENT_ID,
    WorldStateMockResponsesServer,
    environment_params,
    ev_assistant_message,
    ev_request_user_input_call,
    get_source_payload,
    send_environment_add,
    send_initialize,
    send_thread_read,
    send_thread_start_with_environment,
    send_turn_start_and_drain,
    state_value,
    write_world_state_config,
)


SECOND_USER_TEXT = "World state rollback target after compacted patch."
SECOND_FINAL_TEXT = "World state rollback target answer."
FINAL_USER_TEXT = "World state post rollback final resume."
FINAL_ASSISTANT_TEXT = "World state post rollback final answer."

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_world_state_full_patch_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_after_compaction_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_rollback_after_compaction_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/core/src/session/rollout_reconstruction.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/core/src/session/rollout_reconstruction.rs",
]


class RollbackWorldStateMockResponsesServer(WorldStateMockResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            ev_request_user_input_call(),
            ev_assistant_message(
                "resp-world-state-rollback-compact",
                "msg-world-state-rollback-compact",
                COMPACTION_SUMMARY_TEXT,
                10,
            ),
            ev_assistant_message(
                "resp-world-state-rollback-first",
                "msg-world-state-rollback-first",
                FIRST_FINAL_TEXT,
                20,
            ),
            ev_assistant_message(
                "resp-world-state-rollback-second",
                "msg-world-state-rollback-second",
                SECOND_FINAL_TEXT,
                20,
            ),
            ev_assistant_message(
                "resp-world-state-rollback-final",
                "msg-world-state-rollback-final",
                FINAL_ASSISTANT_TEXT,
                20,
            ),
        ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def body_for_user_text(bodies: list[dict[str, Any]], text: str) -> dict[str, Any]:
    for body in bodies:
        if response_input_contains(body, text):
            return body
    return {}


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    response_requests = [
        request for request in requests if str(request.get("path", "")).endswith("/responses")
    ]
    bodies = response_request_bodies(response_requests)
    second_body = body_for_user_text(bodies, SECOND_USER_TEXT)
    final_body = body_for_user_text(bodies, FINAL_USER_TEXT)
    serialized_inputs = [json.dumps(body.get("input"), ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(response_requests),
        "paths": [request.get("path") for request in requests],
        "contains_compact_prompt_count": sum(
            response_input_contains(body, COMPACT_PROMPT) for body in bodies
        ),
        "contains_compaction_summary_count": sum(
            response_input_contains(body, COMPACTION_SUMMARY_TEXT) for body in bodies
        ),
        "contains_first_user_text_count": sum(
            response_input_contains(body, FIRST_USER_TEXT) for body in bodies
        ),
        "contains_second_user_text_count": sum(
            response_input_contains(body, SECOND_USER_TEXT) for body in bodies
        ),
        "contains_final_user_text_count": sum(
            response_input_contains(body, FINAL_USER_TEXT) for body in bodies
        ),
        "second_response_contains_second_user_text": response_input_contains(
            second_body, SECOND_USER_TEXT
        ),
        "second_response_contains_zsh_context": "<shell>zsh</shell>" in json.dumps(
            second_body.get("input"), ensure_ascii=False
        ),
        "final_response_contains_first_user_text": response_input_contains(
            final_body, FIRST_USER_TEXT
        ),
        "final_response_contains_second_user_text": response_input_contains(
            final_body, SECOND_USER_TEXT
        ),
        "final_response_contains_final_user_text": response_input_contains(
            final_body, FINAL_USER_TEXT
        ),
        "final_response_contains_compaction_summary": response_input_contains(
            final_body, COMPACTION_SUMMARY_TEXT
        ),
        "final_response_contains_zsh_context": "<shell>zsh</shell>" in json.dumps(
            final_body.get("input"), ensure_ascii=False
        ),
        "environment_starting_context_count": sum(
            "<status>starting</status>" in body for body in serialized_inputs
        ),
        "environment_available_context_count": sum(
            "<status>available</status>" in body for body in serialized_inputs
        ),
        "environment_zsh_context_count": sum(
            "<shell>zsh</shell>" in body for body in serialized_inputs
        ),
    }


def summarize_world_state_payloads(payloads: list[dict[str, Any]]) -> dict[str, Any]:
    states: list[dict[str, Any]] = []
    for payload in payloads:
        world_payload = payload.get("payload") or {}
        state = world_payload.get("state") or {}
        remote = (
            state_value(state, ["environments", "environments", REMOTE_ENVIRONMENT_ID])
            or {}
        )
        states.append(
            {
                "full": world_payload.get("full"),
                "remote_status": remote.get("status"),
                "remote_shell": remote.get("shell"),
            }
        )
    return {
        "world_state_count": len(payloads),
        "full_flags": [state["full"] for state in states],
        "remote_statuses": [state["remote_status"] for state in states],
        "remote_shells": [state["remote_shell"] for state in states],
        "has_full_snapshot": any(state["full"] is True for state in states),
        "has_patch": any(state["full"] is False for state in states),
        "has_available_zsh": any(
            state["remote_status"] == "available" and state["remote_shell"] == "zsh"
            for state in states
        ),
    }


def original_world_state_summary(summary: dict[str, Any]) -> dict[str, Any]:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return {"rollout_count": len(rollouts), "world_state_count": 0}
    rollout_path = pathlib.Path(summary["codex_home"]) / rollouts[0]["path"]
    lines = read_json_lines(rollout_path)
    payloads = [line for line in lines if line.get("type") == "world_state"]
    result = summarize_world_state_payloads(payloads)
    result["rollout_line_count"] = len(lines)
    return result


def chat_world_state_summary(summary: dict[str, Any]) -> dict[str, Any]:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return {"package_count": len(packages), "world_state_count": 0}
    package = pathlib.Path(packages[0]["package"])
    timeline = read_json_lines(package / "timeline.ndjson")
    journal = read_json_lines(package / "journal.ndjson")
    payloads = [
        get_source_payload(line)
        for line in journal
        if get_source_payload(line).get("type") == "world_state"
    ]
    result = summarize_world_state_payloads(payloads)
    result.update(
        {
            "package_count": len(packages),
            "timeline_line_count": len(timeline),
            "journal_line_count": len(journal),
            "timeline_event_types": [line.get("type") for line in timeline],
            "timeline_state_snapshot_count": sum(
                line.get("type") == "state_snapshot" for line in timeline
            ),
            "timeline_state_patch_count": sum(
                line.get("type") == "state_patch" for line in timeline
            ),
            "timeline_rollback_count": sum(
                line.get("type") == "timeline_rollback" for line in timeline
            ),
            "timeline_compaction_count": sum(
                line.get("type") == "durable_compaction_checkpoint" for line in timeline
            ),
        }
    )
    return result


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    item_types = [
        [item.get("type") for item in (turn.get("items") or [])]
        for turn in turns
    ]
    return {
        "has_error": "error" in response,
        "thread_status_type": status_type(thread.get("status")),
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_types_by_turn": item_types,
        "contains_context_compaction_item": "contextCompaction"
        in json.dumps(item_types),
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_first_final_text": FIRST_FINAL_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_second_final_text": SECOND_FINAL_TEXT in serialized_turns,
        "contains_final_user_text": FINAL_USER_TEXT in serialized_turns,
        "contains_final_assistant_text": FINAL_ASSISTANT_TEXT in serialized_turns,
    }


def normalize_thread_list_response(
    response: dict[str, Any], thread_id: str | None
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    target = next((thread for thread in threads if thread.get("id") == thread_id), None)
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_thread": target is not None,
        "target_status_type": status_type((target or {}).get("status")),
        "target_preview": (target or {}).get("preview"),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
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

    with RollbackWorldStateMockResponsesServer() as mock_server, MiniExecServer() as exec_server:
        write_world_state_config(codex_home, mock_server.url)
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            environment_add_response = send_environment_add(first_client, 2, exec_server.url)
            thread_id, thread_start_response = send_thread_start_with_environment(
                first_client, 3, workspace
            )
            first_turn = send_turn_start_and_drain(
                first_client,
                4,
                thread_id,
                workspace,
                "client-user-message-world-state-rollback-first",
                FIRST_USER_TEXT,
                exec_server,
            )
            after_first_read = send_thread_read(first_client, 5, thread_id)
            second_turn = send_turn_start_and_drain(
                first_client,
                6,
                thread_id,
                workspace,
                "client-user-message-world-state-rollback-second",
                SECOND_USER_TEXT,
                exec_server,
            )
            after_second_read = send_thread_read(first_client, 7, thread_id)
            rollback = send_thread_rollback(first_client, 8, thread_id, 1)
            after_rollback_read = send_thread_read(first_client, 9, thread_id)
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 10)
            second_environment_add_response = send_environment_add(
                second_client, 11, exec_server.url
            )
            resume_after_rollback = send_thread_resume(second_client, 12, thread_id)
            read_after_resume = send_thread_read(second_client, 13, thread_id)
            final_turn = send_turn_start_and_drain(
                second_client,
                14,
                thread_id,
                workspace,
                "client-user-message-world-state-rollback-final",
                FINAL_USER_TEXT,
                exec_server,
            )
            final_read = send_thread_read(second_client, 15, thread_id)
            final_list = send_thread_list(second_client, 16)
        finally:
            second_stderr = second_client.close()

        if tree_name == "chat-backend":
            storage = summarize_chat_packages(chat_root)
            world_summary = chat_world_state_summary(storage)
        else:
            storage = summarize_original_storage(codex_home)
            world_summary = original_world_state_summary(storage)

        return {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "chat_root": str(chat_root),
            "first_process": {
                "command": first_client.command,
                "initialize_response": initialize_response,
                "environment_add_response": environment_add_response,
                "thread_start_response": thread_start_response,
                "first_turn": first_turn,
                "after_first_read": after_first_read,
                "second_turn": second_turn,
                "after_second_read": after_second_read,
                "rollback": rollback,
                "after_rollback_read": after_rollback_read,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "command": second_client.command,
                "initialize_response": second_initialize_response,
                "environment_add_response": second_environment_add_response,
                "resume_after_rollback": resume_after_rollback,
                "read_after_resume": read_after_resume,
                "final_turn": final_turn,
                "final_read": final_read,
                "final_list": final_list,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "exec_server_summary": {
                "url": exec_server.url,
                "methods": [message.get("method") for message in exec_server.messages],
                "environment_info_count": sum(
                    message.get("method") == "environment/info"
                    for message in exec_server.messages
                ),
                "errors": exec_server.errors,
            },
            "storage": storage,
            "world_state_summary": world_summary,
            "storage_line_counts": storage_line_counts(storage, tree_name),
            "rollback_marker_count": count_rollback_markers(
                tree_name, codex_home, chat_root
            ),
            "normalized_after_first_read": normalize_thread_response(after_first_read),
            "normalized_after_second_read": normalize_thread_response(after_second_read),
            "normalized_after_rollback_read": normalize_thread_response(after_rollback_read),
            "normalized_resume_after_rollback": normalize_thread_response(
                resume_after_rollback
            ),
            "normalized_read_after_resume": normalize_thread_response(read_after_resume),
            "normalized_final_read": normalize_thread_response(final_read),
            "normalized_final_list": normalize_thread_list_response(final_list, thread_id),
        }


def response_ok(result: dict[str, Any], process: str, key: str) -> bool:
    value = result[process][key]
    if key.endswith("turn"):
        return "result" in (value.get("response") or {}) and not value.get(
            "notification_errors"
        )
    return "result" in value


def evaluate(original: dict[str, Any], chat: dict[str, Any]) -> dict[str, Any]:
    normalized_keys = [
        "normalized_after_first_read",
        "normalized_after_second_read",
        "normalized_after_rollback_read",
        "normalized_resume_after_rollback",
        "normalized_read_after_resume",
        "normalized_final_read",
        "normalized_final_list",
    ]
    comparisons = {key: original[key] == chat[key] for key in normalized_keys}
    original_world = original["world_state_summary"]
    chat_world = chat["world_state_summary"]
    original_mock = original["mock_server_summary"]
    chat_mock = chat["mock_server_summary"]
    original_after_rollback = original["normalized_after_rollback_read"]
    chat_after_rollback = chat["normalized_after_rollback_read"]
    original_final = original["normalized_final_read"]
    chat_final = chat["normalized_final_read"]

    checks = {
        "all_normalized_fields_equal": all(comparisons.values()),
        "original_first_turn_ok": response_ok(original, "first_process", "first_turn"),
        "chat_first_turn_ok": response_ok(chat, "first_process", "first_turn"),
        "original_second_turn_ok": response_ok(original, "first_process", "second_turn"),
        "chat_second_turn_ok": response_ok(chat, "first_process", "second_turn"),
        "original_rollback_ok": "result"
        in original["first_process"]["rollback"].get("response", {}),
        "chat_rollback_ok": "result" in chat["first_process"]["rollback"].get("response", {}),
        "original_resume_ok": response_ok(
            original, "second_process", "resume_after_rollback"
        ),
        "chat_resume_ok": response_ok(chat, "second_process", "resume_after_rollback"),
        "original_final_turn_ok": response_ok(original, "second_process", "final_turn"),
        "chat_final_turn_ok": response_ok(chat, "second_process", "final_turn"),
        "rollback_marker_counts_equal": (
            original["rollback_marker_count"] == chat["rollback_marker_count"] == 1
        ),
        "storage_line_counts_equal": (
            original["storage_line_counts"] == chat["storage_line_counts"]
            and bool(original["storage_line_counts"])
        ),
        "world_state_flags_equal": (
            original_world.get("full_flags") == chat_world.get("full_flags")
            and bool(original_world.get("full_flags"))
        ),
        "world_state_has_full_and_patch": (
            original_world.get("has_full_snapshot")
            and original_world.get("has_patch")
            and chat_world.get("has_full_snapshot")
            and chat_world.get("has_patch")
        ),
        "world_state_has_available_zsh": (
            original_world.get("has_available_zsh")
            and chat_world.get("has_available_zsh")
        ),
        "chat_timeline_has_snapshot_patch_rollback_compaction": (
            chat_world.get("timeline_state_snapshot_count", 0) >= 1
            and chat_world.get("timeline_state_patch_count", 0) >= 1
            and chat_world.get("timeline_rollback_count", 0) == 1
            and chat_world.get("timeline_compaction_count", 0) >= 1
        ),
        "rollback_removed_second_visible_turn": (
            not original_after_rollback["contains_second_user_text"]
            and not chat_after_rollback["contains_second_user_text"]
            and not original_after_rollback["contains_second_final_text"]
            and not chat_after_rollback["contains_second_final_text"]
        ),
        "final_history_excludes_rolled_back_turn": (
            not original_final["contains_second_user_text"]
            and not chat_final["contains_second_user_text"]
            and not original_final["contains_second_final_text"]
            and not chat_final["contains_second_final_text"]
        ),
        "final_history_preserves_first_and_final_turns": (
            original_final["contains_first_user_text"]
            and chat_final["contains_first_user_text"]
            and original_final["contains_final_user_text"]
            and chat_final["contains_final_user_text"]
            and original_final["contains_final_assistant_text"]
            and chat_final["contains_final_assistant_text"]
        ),
        "final_model_context_excludes_rolled_back_turn": (
            not original_mock["final_response_contains_second_user_text"]
            and not chat_mock["final_response_contains_second_user_text"]
        ),
        "final_model_context_equal_core_markers": (
            original_mock["response_request_count"] == chat_mock["response_request_count"]
            and original_mock["final_response_contains_final_user_text"]
            == chat_mock["final_response_contains_final_user_text"]
            and original_mock["final_response_contains_compaction_summary"]
            == chat_mock["final_response_contains_compaction_summary"]
            and original_mock["final_response_contains_zsh_context"]
            == chat_mock["final_response_contains_zsh_context"]
        ),
        "exec_server_no_errors": (
            not original["exec_server_summary"]["errors"]
            and not chat["exec_server_summary"]["errors"]
        ),
    }
    return {
        "comparison_results": comparisons,
        "checks": checks,
        "passed": all(bool(value) for value in checks.values()),
        "original_world_state_summary": original_world,
        "chat_world_state_summary": chat_world,
        "original_mock_server_summary": original_mock,
        "chat_mock_server_summary": chat_mock,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-world-state-rollback-after-compaction-smoke-"
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
        [
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )
    evaluation = evaluate(original_result, chat_result)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-world-state-rollback-after-compaction-smoke",
        "matrix_slice": ["K04", "RB05", "K03-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "evaluation": evaluation,
        "passed": evaluation["passed"],
        "original_storage_line_counts": original_result["storage_line_counts"],
        "chat_backend_storage_line_counts": chat_result["storage_line_counts"],
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "not_yet_proven": [
            "process death before or during rollback marker durability",
            "world-state rollback-after-compaction projection-boundary crash recovery",
            "automatic-compaction rollback boundaries beyond this normal path",
            "broader world-state variants beyond remote environment status/shell",
            "arbitrary filesystem I/O failures outside validation failpoints",
            "final rollback/compaction/world-state parity",
            "final user-indistinguishability",
        ],
        "original": original_result,
        "chat_backend": chat_result,
    }

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/world-state-rollback-response.json", original_result)
    write_json(
        output_dir / "chat-backend/world-state-rollback-response.json",
        chat_result,
    )

    report = f"""# App-Server World-State Rollback After Compaction Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke extends K04 across a rollback-after-compaction boundary. The flow
starts a remote-environment thread, records full world-state snapshots around
compaction, records a later world-state patch when the remote environment
reports `zsh`, rolls that later turn back, cold-resumes the thread, and
continues with a final turn.

Original Codex is the oracle. This proves only the covered normal app-server
path, not final world-state, rollback, compaction, crash-recovery, or
user-indistinguishability parity.

## Result

- Passed: `{summary['passed']}`
- Original world-state flags: `{evaluation['original_world_state_summary'].get('full_flags')}`
- .chat world-state flags: `{evaluation['chat_world_state_summary'].get('full_flags')}`
- .chat timeline state snapshots: `{evaluation['chat_world_state_summary'].get('timeline_state_snapshot_count')}`
- .chat timeline state patches: `{evaluation['chat_world_state_summary'].get('timeline_state_patch_count')}`
- .chat timeline rollback events: `{evaluation['chat_world_state_summary'].get('timeline_rollback_count')}`
- Original storage line counts: `{summary['original_storage_line_counts']}`
- .chat storage line counts: `{summary['chat_backend_storage_line_counts']}`

## Checks

```json
{json.dumps(evaluation['checks'], indent=2, sort_keys=True)}
```

## Comparison Booleans

```json
{json.dumps(evaluation['comparison_results'], indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': evaluation['original_mock_server_summary'], 'chat_backend': evaluation['chat_mock_server_summary']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/world-state-rollback-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/world-state-rollback-response.json
```

## Not Yet Proven

This smoke does not prove process death before or during rollback marker
durability, projection-boundary crash recovery for this world-state path,
automatic-compaction rollback boundaries beyond this normal path, broader
world-state variants, arbitrary filesystem I/O failures, final
rollback/compaction/world-state parity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
