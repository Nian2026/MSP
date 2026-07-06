#!/usr/bin/env python3
"""Run app-server compaction parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers a first K02/K03 slice: complete one
durable turn, trigger manual `thread/compact/start`, cold-resume the thread,
then start a follow-up turn and verify both backends match original follow-up
context behavior while preserving compacted replacement history on disk.
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
    MockResponsesServer,
    ensure_binary,
    read_json_lines,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    summarize_path_observation,
    utc_now_iso,
    write_json,
)
from app_server_fork_smoke import response_request_bodies  # noqa: E402


FIRST_USER_TEXT = "Compaction parity first durable turn."
FOLLOWUP_USER_TEXT = "Compaction parity follow-up after cold resume."
FIRST_ASSISTANT_TEXT = "Compaction first answer from mock model."
COMPACTION_SUMMARY_SUFFIX = "Manual compact summary from mock model."
FOLLOWUP_ASSISTANT_TEXT = "Compaction follow-up answer from mock model."
SUMMARY_PREFIX = "We need summarize the conversation so far."


class CompactionMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FIRST_ASSISTANT_TEXT)
        self._answers = [
            FIRST_ASSISTANT_TEXT,
            COMPACTION_SUMMARY_SUFFIX,
            FOLLOWUP_ASSISTANT_TEXT,
        ]

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text = self._answers[min(counter - 1, len(self._answers) - 1)]
        return sse_response(
            f"resp-compaction-smoke-{counter}",
            f"msg-compaction-smoke-{counter}",
            answer_text,
        )


def write_compaction_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"
model_provider = "mock_provider"
compact_prompt = "{SUMMARY_PREFIX}"
model_auto_compact_token_limit = 1000

[model_providers.mock_provider]
name = "Mock provider for compaction smoke"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def response_request_path_counts(requests: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for request in requests:
        path = request.get("path", "")
        counts[path] = counts.get(path, 0) + 1
    return counts


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    middle_bodies = bodies[1:-1] if len(bodies) > 2 else bodies[1:]
    followup_body = bodies[-1] if len(bodies) > 0 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request.get("path") for request in requests],
        "path_counts": response_request_path_counts(requests),
        "first_response_contains_first_user_text": response_input_contains(
            first_body, FIRST_USER_TEXT
        ),
        "first_response_contains_followup_user_text": response_input_contains(
            first_body, FOLLOWUP_USER_TEXT
        ),
        "any_middle_response_contains_prompt": any(
            response_input_contains(body, SUMMARY_PREFIX) for body in middle_bodies
        ),
        "any_middle_response_contains_first_user_text": any(
            response_input_contains(body, FIRST_USER_TEXT) for body in middle_bodies
        ),
        "any_middle_response_contains_followup_user_text": any(
            response_input_contains(body, FOLLOWUP_USER_TEXT) for body in middle_bodies
        ),
        "middle_response_count": len(middle_bodies),
        "followup_response_contains_first_user_text": response_input_contains(
            followup_body, FIRST_USER_TEXT
        ),
        "followup_response_contains_first_assistant_text": response_input_contains(
            followup_body, FIRST_ASSISTANT_TEXT
        ),
        "followup_response_contains_compaction_summary": response_input_contains(
            followup_body, COMPACTION_SUMMARY_SUFFIX
        ),
        "followup_response_contains_followup_user_text": response_input_contains(
            followup_body, FOLLOWUP_USER_TEXT
        ),
    }


def send_initialize(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "msp-chat-validation",
                    "title": "MSP Chat Validation",
                    "version": "0.0.0",
                },
                "capabilities": {
                    "experimentalApi": True,
                    "requestAttestation": False,
                    "optOutNotificationMethods": ["account/rateLimits/updated"],
                    "mcpServerOpenaiFormElicitation": False,
                },
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    client.send({"jsonrpc": "2.0", "method": "initialized"})
    return response


def send_thread_start(
    client: JsonRpcClient,
    request_id: int,
    workspace: pathlib.Path,
) -> tuple[str | None, dict[str, Any]]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/start",
            "params": {
                "cwd": str(workspace),
                "ephemeral": False,
                "historyMode": "legacy",
                "model": "mock-model",
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    thread_id = ((response.get("result") or {}).get("thread") or {}).get("id")
    return thread_id, response


def send_turn_start(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    client_user_message_id: str,
    text: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": client_user_message_id,
                "input": [
                    {
                        "type": "text",
                        "text": text,
                        "textElements": [],
                    }
                ],
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications: list[dict[str, Any]] = []
    notification_errors: list[str] = []
    if "error" not in response:
        for method, timeout_seconds in [
            ("turn/started", 30),
            ("turn/completed", 60),
        ]:
            try:
                notifications.append(
                    client.receive_until_method(method, timeout_seconds=timeout_seconds)
                )
            except TimeoutError as exc:
                notification_errors.append(str(exc))
                break
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def send_thread_compact_start(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/compact/start",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications: list[dict[str, Any]] = []
    notification_errors: list[str] = []
    context_compaction_item_ids: list[str] = []
    if "error" not in response:
        for method, timeout_seconds in [
            ("turn/started", 30),
            ("item/started", 60),
            ("item/completed", 60),
            ("turn/completed", 60),
        ]:
            try:
                notification = client.receive_until_method(
                    method, timeout_seconds=timeout_seconds
                )
                notifications.append(notification)
                item = (notification.get("params") or {}).get("item") or {}
                if item.get("type") == "contextCompaction" and item.get("id"):
                    context_compaction_item_ids.append(item["id"])
            except TimeoutError as exc:
                notification_errors.append(str(exc))
                break
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
        "notification_methods": [
            notification.get("method") for notification in notifications
        ],
        "context_compaction_item_ids": context_compaction_item_ids,
    }


def send_thread_read(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/read",
            "params": {
                "threadId": thread_id,
                "includeTurns": True,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


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
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": item_types,
        "contains_context_compaction_item": "contextCompaction" in json.dumps(item_types),
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_followup_user_text": FOLLOWUP_USER_TEXT in serialized_turns,
        "contains_first_assistant_text": FIRST_ASSISTANT_TEXT in serialized_turns,
        "contains_compaction_summary": COMPACTION_SUMMARY_SUFFIX in serialized_turns,
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


def original_rollout_lines(summary: dict[str, Any]) -> list[dict[str, Any]]:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return []
    rollout_path = pathlib.Path(summary["codex_home"]) / rollouts[0]["path"]
    return read_json_lines(rollout_path)


def original_compaction_summary(summary: dict[str, Any]) -> dict[str, Any]:
    lines = original_rollout_lines(summary)
    compacted = [line for line in lines if line.get("type") == "compacted"]
    serialized = json.dumps(compacted, ensure_ascii=False)
    replacement_history_counts = [
        len(((line.get("payload") or {}).get("replacement_history") or []))
        for line in compacted
    ]
    return {
        "rollout_line_count": len(lines),
        "compacted_count": len(compacted),
        "has_replacement_history": any(count > 0 for count in replacement_history_counts),
        "replacement_history_counts": replacement_history_counts,
        "contains_compaction_summary": COMPACTION_SUMMARY_SUFFIX in serialized,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
    }


def chat_compaction_summary(summary: dict[str, Any]) -> dict[str, Any]:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return {
            "package_count": len(packages),
            "timeline_compaction_event_count": 0,
            "journal_compaction_event_count": 0,
            "has_replacement_history": False,
            "contains_compaction_summary": False,
            "contains_first_user_text": False,
        }
    package = pathlib.Path(packages[0]["package"])
    timeline = read_json_lines(package / "timeline.ndjson")
    journal = read_json_lines(package / "journal.ndjson")
    timeline_compaction = [
        line for line in timeline if line.get("type") == "durable_compaction_checkpoint"
    ]
    journal_serialized = json.dumps(journal, ensure_ascii=False)
    journal_compaction = [
        line
        for line in journal
        if ((line.get("source_transport") or {}).get("payload") or {}).get("type")
        == "compacted"
    ]
    return {
        "package_count": len(packages),
        "timeline_line_count": len(timeline),
        "journal_line_count": len(journal),
        "timeline_compaction_event_count": len(timeline_compaction),
        "journal_compaction_event_count": len(journal_compaction),
        "timeline_event_types": [line.get("type") for line in timeline],
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
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client, 2, workspace
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-compaction-first",
                FIRST_USER_TEXT,
            )
            before_compaction_read_response = send_thread_read(first_client, 4, thread_id)
            compaction_result = send_thread_compact_start(first_client, 5, thread_id)
            after_compaction_read_response = send_thread_read(first_client, 6, thread_id)
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 7)
            thread_resume_response = send_thread_resume(second_client, 8, thread_id)
            post_resume_read_response = send_thread_read(second_client, 9, thread_id)
            followup_turn_start_response = send_turn_start(
                second_client,
                10,
                thread_id,
                "client-user-message-compaction-followup",
                FOLLOWUP_USER_TEXT,
            )
            final_thread_read_response = send_thread_read(second_client, 11, thread_id)
        finally:
            second_stderr = second_client.close()

        result = {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "first_process": {
                "command": first_client.command,
                "initialize_response": initialize_response,
                "thread_start_response": thread_start_response,
                "first_turn_start_response": first_turn_start_response,
                "before_compaction_thread_read_response": before_compaction_read_response,
                "compaction_result": compaction_result,
                "after_compaction_thread_read_response": after_compaction_read_response,
                "jsonrpc_sent": first_client.sent,
                "jsonrpc_received": first_client.received,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "command": second_client.command,
                "initialize_response": second_initialize_response,
                "thread_resume_response": thread_resume_response,
                "post_resume_thread_read_response": post_resume_read_response,
                "followup_turn_start_response": followup_turn_start_response,
                "final_thread_read_response": final_thread_read_response,
                "jsonrpc_sent": second_client.sent,
                "jsonrpc_received": second_client.received,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "normalized_before_compaction_read": normalize_thread_response(
                before_compaction_read_response
            ),
            "normalized_compaction": normalize_compaction_result(compaction_result),
            "normalized_after_compaction_read": normalize_thread_response(
                after_compaction_read_response
            ),
            "normalized_resume": normalize_thread_response(thread_resume_response),
            "normalized_post_resume_read": normalize_thread_response(
                post_resume_read_response
            ),
            "normalized_final_read": normalize_thread_response(final_thread_read_response),
            "thread_read_path_observations": {
                "before_compaction": summarize_path_observation(
                    before_compaction_read_response, thread_id
                ),
                "after_compaction": summarize_path_observation(
                    after_compaction_read_response, thread_id
                ),
                "post_resume": summarize_path_observation(
                    post_resume_read_response, thread_id
                ),
                "final": summarize_path_observation(
                    final_thread_read_response, thread_id
                ),
            },
        }
        if tree_name == "chat-backend":
            chat_package_summary = summarize_chat_packages(chat_root)
            result["chat_package_summary"] = chat_package_summary
            result["chat_compaction_summary"] = chat_compaction_summary(
                chat_package_summary
            )
        else:
            original_storage_summary = summarize_original_storage(codex_home)
            result["original_storage_summary"] = original_storage_summary
            result["original_compaction_summary"] = original_compaction_summary(
                original_storage_summary
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-compaction-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_compaction_storage = original_result["original_compaction_summary"]
    chat_compaction_storage = chat_result["chat_compaction_summary"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-compaction-smoke",
        "matrix_slice": ["K02", "K03"],
        "binary_checks": binary_checks,
        "original_first_turn_exit_ok": "result"
        in original_result["first_process"]["first_turn_start_response"]["response"],
        "chat_backend_first_turn_exit_ok": "result"
        in chat_result["first_process"]["first_turn_start_response"]["response"],
        "original_compaction_response_ok": "result"
        in original_result["first_process"]["compaction_result"]["response"],
        "chat_backend_compaction_response_ok": "result"
        in chat_result["first_process"]["compaction_result"]["response"],
        "original_compaction_notifications_ok": not original_result["first_process"][
            "compaction_result"
        ]["notification_errors"],
        "chat_backend_compaction_notifications_ok": not chat_result["first_process"][
            "compaction_result"
        ]["notification_errors"],
        "original_resume_exit_ok": "result"
        in original_result["second_process"]["thread_resume_response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_result["second_process"]["thread_resume_response"],
        "original_followup_turn_exit_ok": "result"
        in original_result["second_process"]["followup_turn_start_response"]["response"],
        "chat_backend_followup_turn_exit_ok": "result"
        in chat_result["second_process"]["followup_turn_start_response"]["response"],
        "original_followup_notifications_ok": not original_result["second_process"][
            "followup_turn_start_response"
        ]["notification_errors"],
        "chat_backend_followup_notifications_ok": not chat_result["second_process"][
            "followup_turn_start_response"
        ]["notification_errors"],
        "normalized_before_compaction_read_equal": (
            original_result["normalized_before_compaction_read"]
            == chat_result["normalized_before_compaction_read"]
        ),
        "normalized_compaction_equal": (
            original_result["normalized_compaction"]
            == chat_result["normalized_compaction"]
        ),
        "normalized_after_compaction_read_equal": (
            original_result["normalized_after_compaction_read"]
            == chat_result["normalized_after_compaction_read"]
        ),
        "normalized_resume_equal": (
            original_result["normalized_resume"] == chat_result["normalized_resume"]
        ),
        "normalized_post_resume_read_equal": (
            original_result["normalized_post_resume_read"]
            == chat_result["normalized_post_resume_read"]
        ),
        "normalized_final_read_equal": (
            original_result["normalized_final_read"]
            == chat_result["normalized_final_read"]
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_context_markers_equal": original_mock == chat_mock,
        "mock_compaction_context_ok": all(
            [
                original_mock == chat_mock,
                original_mock["response_request_count"]
                == chat_mock["response_request_count"],
                original_mock["response_request_count"] >= 3,
                original_mock["any_middle_response_contains_prompt"],
                chat_mock["any_middle_response_contains_prompt"],
                original_mock["any_middle_response_contains_first_user_text"],
                chat_mock["any_middle_response_contains_first_user_text"],
                original_mock["followup_response_contains_followup_user_text"],
                chat_mock["followup_response_contains_followup_user_text"],
            ]
        ),
        "original_compaction_storage_ok": all(
            [
                original_compaction_storage["compacted_count"] >= 1,
                original_compaction_storage["has_replacement_history"],
                original_compaction_storage["contains_compaction_summary"],
                original_compaction_storage["contains_first_user_text"],
            ]
        ),
        "chat_backend_compaction_storage_ok": all(
            [
                chat_compaction_storage["timeline_compaction_event_count"] >= 1,
                chat_compaction_storage["journal_compaction_event_count"] >= 1,
                chat_compaction_storage["has_replacement_history"],
                chat_compaction_storage["contains_compaction_summary"],
                chat_compaction_storage["contains_first_user_text"],
            ]
        ),
        "original_normalized_compaction": original_result["normalized_compaction"],
        "chat_backend_normalized_compaction": chat_result["normalized_compaction"],
        "original_normalized_final_read": original_result["normalized_final_read"],
        "chat_backend_normalized_final_read": chat_result["normalized_final_read"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_compaction_summary": original_compaction_storage,
        "chat_backend_compaction_summary": chat_compaction_storage,
        "original_storage_summary": original_result["original_storage_summary"],
        "chat_package_summary": chat_result["chat_package_summary"],
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observations"],
            "chat-backend": chat_result["thread_read_path_observations"],
        },
        "not_yet_proven": [
            "automatic compaction K01",
            "world state full/patch K04",
            "legacy compaction fallback K05",
            "rollback after compaction RB05",
            "full compaction context-window lineage parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/compaction-response.json", original_result)
    write_json(output_dir / "chat-backend/compaction-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Compaction Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, data-fidelity report, and
relevant vendored compaction source/tests were read.

## Scope

This smoke covers a first K02/K03 slice:

- complete one durable turn;
- call `thread/compact/start`;
- observe `turn/started`, `item/started`, `item/completed`, and `turn/completed`;
- cold-start a new app-server process;
- `thread/resume`;
- start a follow-up turn and verify the mock model request context markers match
  original Codex behavior.

It is not a complete compaction proof. It does not cover automatic compaction,
world-state full/patch restore, legacy compaction fallback, rollback after
compaction, crash recovery, performance, complete data fidelity, or final
user-indistinguishability.

## Result

- original first turn succeeded: `{summary['original_first_turn_exit_ok']}`
- `.chat` first turn succeeded: `{summary['chat_backend_first_turn_exit_ok']}`
- original manual compaction response succeeded: `{summary['original_compaction_response_ok']}`
- `.chat` manual compaction response succeeded: `{summary['chat_backend_compaction_response_ok']}`
- original compaction notifications completed: `{summary['original_compaction_notifications_ok']}`
- `.chat` compaction notifications completed: `{summary['chat_backend_compaction_notifications_ok']}`
- original cold resume succeeded: `{summary['original_resume_exit_ok']}`
- `.chat` cold resume succeeded: `{summary['chat_backend_resume_exit_ok']}`
- normalized compaction response/notification summary equal: `{summary['normalized_compaction_equal']}`
- normalized final thread read equal: `{summary['normalized_final_read_equal']}`
- mock request counts equal: `{summary['mock_response_request_counts_equal']}`
- mock request context markers matched original: `{summary['mock_context_markers_equal']}`
- compaction/follow-up context checks passed: `{summary['mock_compaction_context_ok']}`
- original rollout preserved compacted replacement history: `{summary['original_compaction_storage_ok']}`
- `.chat` timeline/journal preserved compaction checkpoint/source transport: `{summary['chat_backend_compaction_storage_ok']}`

## Normalized Compaction

```json
{json.dumps({'original': summary['original_normalized_compaction'], 'chat-backend': summary['chat_backend_normalized_compaction']}, indent=2, sort_keys=True)}
```

## Final Thread Read

```json
{json.dumps({'original': summary['original_normalized_final_read'], 'chat-backend': summary['chat_backend_normalized_final_read']}, indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat-backend': chat_mock}, indent=2, sort_keys=True)}
```

## Compaction Storage Summary

```json
{json.dumps({'original': original_compaction_storage, 'chat-backend': chat_compaction_storage}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_result['chat_package_summary'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/compaction-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/compaction-response.json
```

## Not Yet Proven

This smoke does not prove automatic compaction, world-state full/patch restore,
legacy compaction fallback, rollback after compaction, crash recovery, complete
data fidelity, or user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_first_turn_exit_ok"],
            summary["chat_backend_first_turn_exit_ok"],
            summary["original_compaction_response_ok"],
            summary["chat_backend_compaction_response_ok"],
            summary["original_compaction_notifications_ok"],
            summary["chat_backend_compaction_notifications_ok"],
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_followup_turn_exit_ok"],
            summary["chat_backend_followup_turn_exit_ok"],
            summary["original_followup_notifications_ok"],
            summary["chat_backend_followup_notifications_ok"],
            summary["normalized_before_compaction_read_equal"],
            summary["normalized_compaction_equal"],
            summary["normalized_after_compaction_read_equal"],
            summary["normalized_resume_equal"],
            summary["normalized_post_resume_read_equal"],
            summary["normalized_final_read_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_compaction_context_ok"],
            summary["original_compaction_storage_ok"],
            summary["chat_backend_compaction_storage_ok"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
