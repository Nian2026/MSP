#!/usr/bin/env python3
"""Run rollback-after-compaction parity smoke for original vs `.chat` backend.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers a first RB05 slice: complete two
durable turns, manually compact the conversation, roll back after that
compaction boundary, cold-resume the thread, then start a follow-up turn. The
oracle is original Codex behavior: the visible compaction turn is removed, while
the follow-up request still uses the compacted context baseline.
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
from app_server_compaction_smoke import send_thread_compact_start  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
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
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_rollback,
    send_thread_start,
    send_turn_start,
    storage_line_counts,
)


FIRST_USER_TEXT = "Rollback after compaction first durable turn."
SECOND_USER_TEXT = "Rollback after compaction second turn to remove."
FOLLOWUP_USER_TEXT = "Rollback after compaction follow-up after cold resume."
FIRST_ASSISTANT_TEXT = "Rollback after compaction first answer."
SECOND_ASSISTANT_TEXT = "Rollback after compaction second answer to remove."
COMPACTION_SUMMARY_TEXT = "Rollback after compaction manual summary."
FOLLOWUP_ASSISTANT_TEXT = "Rollback after compaction follow-up answer."
SUMMARY_PREFIX = "Summarize before rollback after compaction."


class RollbackAfterCompactionMockServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FIRST_ASSISTANT_TEXT)
        self._answers = [
            FIRST_ASSISTANT_TEXT,
            SECOND_ASSISTANT_TEXT,
            COMPACTION_SUMMARY_TEXT,
            COMPACTION_SUMMARY_TEXT,
            FOLLOWUP_ASSISTANT_TEXT,
        ]

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text = self._answers[min(counter - 1, len(self._answers) - 1)]
        return sse_response(
            f"resp-rollback-after-compaction-{counter}",
            f"msg-rollback-after-compaction-{counter}",
            answer_text,
        )


def write_rb05_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"
model_provider = "mock_provider"
compact_prompt = "{SUMMARY_PREFIX}"
model_auto_compact_token_limit = 1000

[model_providers.mock_provider]
name = "Mock provider for rollback-after-compaction smoke"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def body_for_user_text(
    bodies: list[dict[str, Any]],
    user_text: str,
) -> dict[str, Any]:
    for body in bodies:
        if response_input_contains(body, user_text):
            return body
    return {}


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = body_for_user_text(bodies, FIRST_USER_TEXT)
    second_body = body_for_user_text(bodies, SECOND_USER_TEXT)
    followup_body = body_for_user_text(bodies, FOLLOWUP_USER_TEXT)
    compaction_bodies = [
        body
        for body in bodies
        if response_input_contains(body, SUMMARY_PREFIX)
        or (
            response_input_contains(body, FIRST_USER_TEXT)
            and response_input_contains(body, SECOND_USER_TEXT)
            and not response_input_contains(body, FOLLOWUP_USER_TEXT)
        )
    ]
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "first_response_contains_first_user_text": response_input_contains(
            first_body,
            FIRST_USER_TEXT,
        ),
        "second_response_contains_first_user_text": response_input_contains(
            second_body,
            FIRST_USER_TEXT,
        ),
        "second_response_contains_first_assistant_text": response_input_contains(
            second_body,
            FIRST_ASSISTANT_TEXT,
        ),
        "second_response_contains_second_user_text": response_input_contains(
            second_body,
            SECOND_USER_TEXT,
        ),
        "compaction_request_count": len(compaction_bodies),
        "any_compaction_request_contains_prompt": any(
            response_input_contains(body, SUMMARY_PREFIX) for body in compaction_bodies
        ),
        "any_compaction_request_contains_first_user_text": any(
            response_input_contains(body, FIRST_USER_TEXT) for body in compaction_bodies
        ),
        "any_compaction_request_contains_second_user_text": any(
            response_input_contains(body, SECOND_USER_TEXT) for body in compaction_bodies
        ),
        "followup_response_contains_first_user_text": response_input_contains(
            followup_body,
            FIRST_USER_TEXT,
        ),
        "followup_response_contains_first_assistant_text": response_input_contains(
            followup_body,
            FIRST_ASSISTANT_TEXT,
        ),
        "followup_response_contains_second_user_text": response_input_contains(
            followup_body,
            SECOND_USER_TEXT,
        ),
        "followup_response_contains_second_assistant_text": response_input_contains(
            followup_body,
            SECOND_ASSISTANT_TEXT,
        ),
        "followup_response_contains_compaction_summary": response_input_contains(
            followup_body,
            COMPACTION_SUMMARY_TEXT,
        ),
        "followup_response_contains_followup_user_text": response_input_contains(
            followup_body,
            FOLLOWUP_USER_TEXT,
        ),
    }


def thread_from_response(response: dict[str, Any]) -> dict[str, Any]:
    return (response.get("result") or {}).get("thread") or {}


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    item_types = [
        [item.get("type") for item in (turn.get("items") or [])]
        for turn in turns
    ]
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": thread.get("model"),
        "model_provider": thread.get("modelProvider"),
        "name_is_null_or_absent": thread.get("name") is None,
        "session_id_present": thread.get("sessionId") is not None,
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": item_types,
        "contains_context_compaction_item": "contextCompaction"
        in json.dumps(item_types),
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_followup_user_text": FOLLOWUP_USER_TEXT in serialized_turns,
        "contains_first_assistant_text": FIRST_ASSISTANT_TEXT in serialized_turns,
        "contains_second_assistant_text": SECOND_ASSISTANT_TEXT in serialized_turns,
        "contains_compaction_summary": COMPACTION_SUMMARY_TEXT in serialized_turns,
        "contains_followup_assistant_text": FOLLOWUP_ASSISTANT_TEXT in serialized_turns,
    }


def normalize_compaction_result(compaction: dict[str, Any]) -> dict[str, Any]:
    methods = compaction.get("notification_methods") or []
    context_ids = compaction.get("context_compaction_item_ids") or []
    return {
        "has_error": "error" in compaction.get("response", {}),
        "response_result": (compaction.get("response") or {}).get("result"),
        "notification_methods": methods,
        "notification_errors": compaction.get("notification_errors") or [],
        "context_compaction_notification_count": len(context_ids),
        "context_compaction_started_completed_same_id": (
            len(context_ids) >= 2 and context_ids[0] == context_ids[1]
        ),
    }


def normalize_rollback_result(rollback_result: dict[str, Any]) -> dict[str, Any]:
    normalized = normalize_thread_response(rollback_result["response"])
    methods = rollback_result.get("notification_methods_after_request") or []
    normalized.update(
        {
            "deprecation_notice_seen": "deprecationNotice" in methods,
            "notification_methods_after_request": methods,
        }
    )
    return normalized


def normalize_thread_list_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    ids = {thread.get("id") for thread in threads}
    target = next((thread for thread in threads if thread.get("id") == thread_id), None)
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_thread": thread_id in ids if thread_id is not None else False,
        "target_preview": (target or {}).get("preview"),
        "target_status_type": status_type((target or {}).get("status")),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def original_rollout_lines(summary: dict[str, Any]) -> list[dict[str, Any]]:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return []
    rollout_path = pathlib.Path(summary["codex_home"]) / rollouts[0]["path"]
    return read_json_lines(rollout_path)


def original_storage_detail(summary: dict[str, Any]) -> dict[str, Any]:
    lines = original_rollout_lines(summary)
    compacted = [line for line in lines if line.get("type") == "compacted"]
    serialized = json.dumps(lines, ensure_ascii=False)
    replacement_history_counts = [
        len(((line.get("payload") or {}).get("replacement_history") or []))
        for line in compacted
    ]
    return {
        "rollout_line_count": len(lines),
        "compacted_count": len(compacted),
        "rollback_marker_count": serialized.count("thread_rolled_back")
        + serialized.count("ThreadRolledBack"),
        "has_replacement_history": any(count > 0 for count in replacement_history_counts),
        "replacement_history_counts": replacement_history_counts,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
        "contains_second_user_text": SECOND_USER_TEXT in serialized,
        "contains_compaction_summary": COMPACTION_SUMMARY_TEXT in serialized,
        "contains_rollback_marker": (
            "thread_rolled_back" in serialized or "ThreadRolledBack" in serialized
        ),
    }


def chat_storage_detail(summary: dict[str, Any]) -> dict[str, Any]:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return {
            "package_count": len(packages),
            "timeline_line_count": 0,
            "journal_line_count": 0,
            "timeline_compaction_event_count": 0,
            "timeline_rollback_event_count": 0,
            "journal_compaction_event_count": 0,
            "journal_rollback_marker_count": 0,
            "has_replacement_history": False,
            "contains_first_user_text": False,
            "contains_second_user_text": False,
            "contains_compaction_summary": False,
            "contains_rollback_marker": False,
        }
    package = pathlib.Path(packages[0]["package"])
    timeline = read_json_lines(package / "timeline.ndjson")
    journal = read_json_lines(package / "journal.ndjson")
    timeline_serialized = json.dumps(timeline, ensure_ascii=False)
    serialized = json.dumps({"timeline": timeline, "journal": journal}, ensure_ascii=False)
    journal_compaction = [
        line
        for line in journal
        if ((line.get("source_transport") or {}).get("payload") or {}).get("type")
        == "compacted"
    ]
    journal_rollback = [
        line
        for line in journal
        if (
            ((line.get("source_transport") or {}).get("payload") or {}).get(
                "payload"
            )
            or {}
        ).get("type")
        == "thread_rolled_back"
    ]
    timeline_compaction = [
        line for line in timeline if line.get("type") == "durable_compaction_checkpoint"
    ]
    timeline_rollback = [
        line for line in timeline if line.get("type") == "timeline_rollback"
    ]
    return {
        "package_count": len(packages),
        "timeline_line_count": len(timeline),
        "journal_line_count": len(journal),
        "timeline_compaction_event_count": len(timeline_compaction),
        "timeline_rollback_event_count": len(timeline_rollback),
        "timeline_source_rollback_marker_count": timeline_serialized.count(
            "thread_rolled_back"
        )
        + timeline_serialized.count("ThreadRolledBack"),
        "journal_compaction_event_count": len(journal_compaction),
        "journal_rollback_marker_count": len(journal_rollback),
        "timeline_event_types": [line.get("type") for line in timeline],
        "has_replacement_history": "replacement_history" in serialized,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
        "contains_second_user_text": SECOND_USER_TEXT in serialized,
        "contains_compaction_summary": COMPACTION_SUMMARY_TEXT in serialized,
        "contains_rollback_marker": (
            "thread_rolled_back" in serialized or "ThreadRolledBack" in serialized
        ),
    }


def tree_storage_summary(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> dict[str, Any]:
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

    with RollbackAfterCompactionMockServer() as mock_server:
        write_rb05_mock_config(codex_home, mock_server.url)
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-rb05-first",
                FIRST_USER_TEXT,
            )
            second_turn = send_turn_start(
                first_client,
                4,
                thread_id,
                "client-user-message-rb05-second",
                SECOND_USER_TEXT,
            )
            before_compaction_read = send_thread_read(first_client, 5, thread_id)
            compaction = send_thread_compact_start(first_client, 6, thread_id)
            after_compaction_read = send_thread_read(first_client, 7, thread_id)
            rollback = send_thread_rollback(first_client, 8, thread_id, 1)
            after_rollback_read = send_thread_read(first_client, 9, thread_id)
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 10)
            resume_after_rollback = send_thread_resume(second_client, 11, thread_id)
            read_after_resume = send_thread_read(second_client, 12, thread_id)
            followup_turn = send_turn_start(
                second_client,
                13,
                thread_id,
                "client-user-message-rb05-followup",
                FOLLOWUP_USER_TEXT,
            )
            final_read = send_thread_read(second_client, 14, thread_id)
            final_list = send_thread_list(second_client, 15)
        finally:
            second_stderr = second_client.close()

    final_storage = tree_storage_summary(tree_name, codex_home, chat_root)
    storage_detail = (
        chat_storage_detail(final_storage)
        if tree_name == "chat-backend"
        else original_storage_detail(final_storage)
    )
    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "first_process": {
            "command": first_client.command,
            "initialize_response": initialize_response,
            "thread_start_response": thread_start_response,
            "first_turn": first_turn,
            "second_turn": second_turn,
            "before_compaction_read": before_compaction_read,
            "compaction": compaction,
            "after_compaction_read": after_compaction_read,
            "rollback": rollback,
            "after_rollback_read": after_rollback_read,
            "jsonrpc_sent": first_client.sent,
            "jsonrpc_received": first_client.received,
            "stderr_tail": first_stderr[-6000:],
            "process_exit_code": first_client.process.returncode,
        },
        "second_process": {
            "command": second_client.command,
            "initialize_response": second_initialize_response,
            "resume_after_rollback": resume_after_rollback,
            "read_after_resume": read_after_resume,
            "followup_turn": followup_turn,
            "final_read": final_read,
            "final_list": final_list,
            "jsonrpc_sent": second_client.sent,
            "jsonrpc_received": second_client.received,
            "stderr_tail": second_stderr[-6000:],
            "process_exit_code": second_client.process.returncode,
        },
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "final_storage": final_storage,
        "storage_detail": storage_detail,
        "storage_line_counts": storage_line_counts(final_storage, tree_name),
        "rollback_marker_count": count_rollback_markers(
            tree_name,
            codex_home,
            chat_root,
        ),
        "normalized_before_compaction": normalize_thread_response(before_compaction_read),
        "normalized_compaction": normalize_compaction_result(compaction),
        "normalized_after_compaction": normalize_thread_response(after_compaction_read),
        "normalized_rollback": normalize_rollback_result(rollback),
        "normalized_after_rollback": normalize_thread_response(after_rollback_read),
        "normalized_resume_after_rollback": normalize_thread_response(
            resume_after_rollback
        ),
        "normalized_read_after_resume": normalize_thread_response(read_after_resume),
        "normalized_final_read": normalize_thread_response(final_read),
        "normalized_final_list": normalize_thread_list_response(final_list, thread_id),
    }


def compare_keys(
    original: dict[str, Any],
    chat_backend: dict[str, Any],
    keys: list[str],
) -> dict[str, bool]:
    return {key: original[key] == chat_backend[key] for key in keys}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-rollback-after-compaction-smoke-"
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

    normalized_keys = [
        "normalized_before_compaction",
        "normalized_compaction",
        "normalized_after_compaction",
        "normalized_rollback",
        "normalized_after_rollback",
        "normalized_resume_after_rollback",
        "normalized_read_after_resume",
        "normalized_final_read",
        "normalized_final_list",
    ]
    comparisons = compare_keys(original_result, chat_result, normalized_keys)
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_rollback = original_result["normalized_rollback"]
    chat_rollback = chat_result["normalized_rollback"]
    original_after = original_result["normalized_after_rollback"]
    chat_after = chat_result["normalized_after_rollback"]
    original_final = original_result["normalized_final_read"]
    chat_final = chat_result["normalized_final_read"]
    original_storage_detail = original_result["storage_detail"]
    chat_storage_detail_result = chat_result["storage_detail"]

    rollback_visible_history_ok = all(
        [
            original_rollback["turn_count"] == chat_rollback["turn_count"],
            original_after["turn_count"] == chat_after["turn_count"],
            original_rollback["turn_count"] == 2,
            chat_rollback["turn_count"] == 2,
            original_rollback["contains_first_user_text"],
            chat_rollback["contains_first_user_text"],
            original_rollback["contains_first_assistant_text"],
            chat_rollback["contains_first_assistant_text"],
            original_rollback["contains_second_user_text"],
            chat_rollback["contains_second_user_text"],
            original_rollback["contains_second_assistant_text"],
            chat_rollback["contains_second_assistant_text"],
            not original_rollback["contains_context_compaction_item"],
            not chat_rollback["contains_context_compaction_item"],
        ]
    )
    followup_context_ok = all(
        [
            original_mock["response_request_count"]
            == chat_mock["response_request_count"],
            original_mock["followup_response_contains_followup_user_text"],
            chat_mock["followup_response_contains_followup_user_text"],
            original_mock["followup_response_contains_compaction_summary"],
            chat_mock["followup_response_contains_compaction_summary"],
            not original_mock["followup_response_contains_first_user_text"],
            not chat_mock["followup_response_contains_first_user_text"],
            not original_mock["followup_response_contains_first_assistant_text"],
            not chat_mock["followup_response_contains_first_assistant_text"],
            not original_mock["followup_response_contains_second_user_text"],
            not chat_mock["followup_response_contains_second_user_text"],
            not original_mock["followup_response_contains_second_assistant_text"],
            not chat_mock["followup_response_contains_second_assistant_text"],
        ]
    )
    final_history_ok = all(
        [
            original_final["turn_count"] == chat_final["turn_count"],
            original_final["turn_count"] == 3,
            chat_final["turn_count"] == 3,
            original_final["contains_first_user_text"],
            chat_final["contains_first_user_text"],
            original_final["contains_first_assistant_text"],
            chat_final["contains_first_assistant_text"],
            original_final["contains_second_user_text"],
            chat_final["contains_second_user_text"],
            original_final["contains_second_assistant_text"],
            chat_final["contains_second_assistant_text"],
            original_final["contains_followup_user_text"],
            chat_final["contains_followup_user_text"],
            original_final["contains_followup_assistant_text"],
            chat_final["contains_followup_assistant_text"],
            original_final["contains_context_compaction_item"],
            chat_final["contains_context_compaction_item"],
        ]
    )
    storage_preserved_ok = all(
        [
            original_storage_detail["compacted_count"] >= 1,
            chat_storage_detail_result["timeline_compaction_event_count"] >= 1,
            chat_storage_detail_result["timeline_rollback_event_count"] == 1,
            chat_storage_detail_result["journal_compaction_event_count"] >= 1,
            chat_storage_detail_result["journal_rollback_marker_count"] == 1,
            original_storage_detail["has_replacement_history"],
            chat_storage_detail_result["has_replacement_history"],
            original_storage_detail["contains_second_user_text"],
            chat_storage_detail_result["contains_second_user_text"],
            original_storage_detail["contains_compaction_summary"],
            chat_storage_detail_result["contains_compaction_summary"],
            original_storage_detail["contains_rollback_marker"],
            chat_storage_detail_result["contains_rollback_marker"],
        ]
    )
    rollback_marker_counts_ok = all(
        [
            original_result["rollback_marker_count"] == 1,
            chat_result["rollback_marker_count"] == 1,
            original_result["rollback_marker_count"]
            == chat_result["rollback_marker_count"],
        ]
    )
    storage_line_counts_match = (
        original_result["storage_line_counts"] == chat_result["storage_line_counts"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-rollback-after-compaction-smoke",
        "matrix_slice": ["RB05"],
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_rb05_fields_equal": all(comparisons.values()),
        "original_first_turn_ok": "result"
        in original_result["first_process"]["first_turn"]["response"],
        "chat_backend_first_turn_ok": "result"
        in chat_result["first_process"]["first_turn"]["response"],
        "original_second_turn_ok": "result"
        in original_result["first_process"]["second_turn"]["response"],
        "chat_backend_second_turn_ok": "result"
        in chat_result["first_process"]["second_turn"]["response"],
        "original_compaction_ok": "result"
        in original_result["first_process"]["compaction"]["response"],
        "chat_backend_compaction_ok": "result"
        in chat_result["first_process"]["compaction"]["response"],
        "original_rollback_ok": "result"
        in original_result["first_process"]["rollback"]["response"],
        "chat_backend_rollback_ok": "result"
        in chat_result["first_process"]["rollback"]["response"],
        "original_resume_ok": "result"
        in original_result["second_process"]["resume_after_rollback"],
        "chat_backend_resume_ok": "result"
        in chat_result["second_process"]["resume_after_rollback"],
        "original_followup_ok": "result"
        in original_result["second_process"]["followup_turn"]["response"],
        "chat_backend_followup_ok": "result"
        in chat_result["second_process"]["followup_turn"]["response"],
        "rollback_visible_history_removed_visible_compaction_turn": (
            rollback_visible_history_ok
        ),
        "followup_context_uses_compaction_baseline": followup_context_ok,
        "final_history_after_followup_ok": final_history_ok,
        "storage_preserved_compaction_and_rollback_ok": storage_preserved_ok,
        "rollback_marker_counts_ok": rollback_marker_counts_ok,
        "chat_backend_timeline_rollback_event_count": (
            chat_storage_detail_result["timeline_rollback_event_count"]
        ),
        "chat_backend_timeline_rollback_event_count_matches_marker_count": (
            chat_storage_detail_result["timeline_rollback_event_count"]
            == chat_result["rollback_marker_count"]
        ),
        "storage_line_counts_match": storage_line_counts_match,
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "original_storage_line_counts": original_result["storage_line_counts"],
        "chat_backend_storage_line_counts": chat_result["storage_line_counts"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original": {key: original_result[key] for key in normalized_keys},
        "chat_backend": {key: chat_result[key] for key in normalized_keys},
        "original_storage_detail": original_storage_detail,
        "chat_backend_storage_detail": chat_storage_detail_result,
        "original_storage": original_result["final_storage"],
        "chat_package": chat_result["final_storage"],
        "not_yet_proven": [
            "automatic compaction K01",
            "world state full/patch K04",
            "legacy compaction fallback K05",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/rollback-after-compaction-response.json", original_result)
    write_json(
        output_dir / "chat-backend/rollback-after-compaction-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Rollback After Compaction Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, data-fidelity report, and
relevant vendored compaction/rollback/replay source were read.

## Scope

This smoke covers the first RB05 slice. Original Codex is the oracle: after
manual compaction, `thread/rollback numTurns=1` removes the visible compaction
turn from the thread view, but follow-up replay still uses the compacted context
baseline rather than re-expanding the pre-compaction turns.

```text
thread/start
turn/start x2
thread/compact/start
thread/rollback numTurns=1
thread/read after rollback
cold process restart
thread/resume
turn/start follow-up
thread/read final
thread/list active
```

It proves only rollback-after-manual-compaction for this harness. It does not
prove automatic compaction, world-state full/patch restore, legacy compaction
fallback, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability.

## Result

- all normalized RB05 fields equal: `{summary['all_normalized_rb05_fields_equal']}`
- original compaction succeeded: `{summary['original_compaction_ok']}`
- `.chat` compaction succeeded: `{summary['chat_backend_compaction_ok']}`
- original rollback succeeded: `{summary['original_rollback_ok']}`
- `.chat` rollback succeeded: `{summary['chat_backend_rollback_ok']}`
- original cold resume succeeded: `{summary['original_resume_ok']}`
- `.chat` cold resume succeeded: `{summary['chat_backend_resume_ok']}`
- rollback visible history removed the visible compaction turn: `{summary['rollback_visible_history_removed_visible_compaction_turn']}`
- follow-up model context uses the compaction baseline: `{summary['followup_context_uses_compaction_baseline']}`
- final history after follow-up ok: `{summary['final_history_after_followup_ok']}`
- compaction checkpoint/source transport and rollback marker preserved on disk: `{summary['storage_preserved_compaction_and_rollback_ok']}`
- rollback marker counts ok: `{summary['rollback_marker_counts_ok']}`
- .chat timeline rollback event count: `{summary['chat_backend_timeline_rollback_event_count']}`
- .chat timeline rollback count matches marker count: `{summary['chat_backend_timeline_rollback_event_count_matches_marker_count']}`
- storage line counts match: `{summary['storage_line_counts_match']}`

## Comparison Booleans

```json
{json.dumps(comparisons, indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## Storage Detail

```json
{json.dumps({'original': original_storage_detail, 'chat_backend': chat_storage_detail_result}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/rollback-after-compaction-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/rollback-after-compaction-response.json
```

## Not Yet Proven

This smoke does not prove automatic compaction, world-state full/patch restore,
legacy compaction fallback, crash recovery, cold history, complete data
fidelity, or user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_rb05_fields_equal"],
            summary["original_first_turn_ok"],
            summary["chat_backend_first_turn_ok"],
            summary["original_second_turn_ok"],
            summary["chat_backend_second_turn_ok"],
            summary["original_compaction_ok"],
            summary["chat_backend_compaction_ok"],
            summary["original_rollback_ok"],
            summary["chat_backend_rollback_ok"],
            summary["original_resume_ok"],
            summary["chat_backend_resume_ok"],
            summary["original_followup_ok"],
            summary["chat_backend_followup_ok"],
            summary["rollback_visible_history_removed_visible_compaction_turn"],
            summary["followup_context_uses_compaction_baseline"],
            summary["final_history_after_followup_ok"],
            summary["storage_preserved_compaction_and_rollback_ok"],
            summary["rollback_marker_counts_ok"],
            summary["chat_backend_timeline_rollback_event_count_matches_marker_count"],
            summary["storage_line_counts_match"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
