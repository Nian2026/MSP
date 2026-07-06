#!/usr/bin/env python3
"""Run automatic compaction parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers a first K01 slice: trigger pre-turn
automatic compaction through token usage, observe context-compaction item
notifications, cold-resume the compacted thread, and verify both backends keep
matching model-context and storage evidence.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_resume_smoke import send_thread_resume  # noqa: E402
from app_server_compaction_smoke import (  # noqa: E402
    send_initialize,
    send_thread_read,
    send_thread_start,
    send_turn_start,
)
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


FIRST_USER_TEXT = "Auto compaction first turn."
SECOND_USER_TEXT = "Auto compaction second turn over budget."
THIRD_USER_TEXT = "Auto compaction third turn after pre-turn compact."
FOLLOWUP_USER_TEXT = "Auto compaction follow-up after cold resume."
FIRST_ASSISTANT_TEXT = "Auto compaction first answer."
SECOND_ASSISTANT_TEXT = "Auto compaction second answer."
AUTO_COMPACTION_SUMMARY_TEXT = "Auto compaction local summary."
THIRD_ASSISTANT_TEXT = "Auto compaction third answer."
FOLLOWUP_ASSISTANT_TEXT = "Auto compaction follow-up answer."
COMPACT_PROMPT = "Summarize the conversation for automatic compaction."


def sse_response_with_tokens(
    response_id: str,
    message_id: str,
    text: str,
    total_tokens: int,
) -> bytes:
    events = [
        {
            "type": "response.created",
            "response": {
                "id": response_id,
            },
        },
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message",
                "role": "assistant",
                "id": message_id,
                "content": [{"type": "output_text", "text": text}],
            },
        },
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": total_tokens,
                    "input_tokens_details": None,
                    "output_tokens": 0,
                    "output_tokens_details": None,
                    "total_tokens": total_tokens,
                },
            },
        },
    ]
    chunks: list[str] = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


class AutoCompactionMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(FIRST_ASSISTANT_TEXT)
        self._answers = [
            (FIRST_ASSISTANT_TEXT, 70_000),
            (AUTO_COMPACTION_SUMMARY_TEXT, 200),
            (SECOND_ASSISTANT_TEXT, 120),
            (THIRD_ASSISTANT_TEXT, 80),
            (FOLLOWUP_ASSISTANT_TEXT, 60),
        ]

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text, total_tokens = self._answers[
            min(counter - 1, len(self._answers) - 1)
        ]
        return sse_response_with_tokens(
            f"resp-auto-compaction-smoke-{counter}",
            f"msg-auto-compaction-smoke-{counter}",
            answer_text,
            total_tokens,
        )

    def _make_handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def do_GET(self) -> None:
                if self.path.endswith("/models"):
                    body = json.dumps({"models": []}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_error(404)

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length)
                try:
                    body_json = json.loads(raw_body.decode() or "{}")
                except json.JSONDecodeError:
                    body_json = {"_decode_error": raw_body.decode(errors="replace")}
                server: AutoCompactionMockResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
                server.record_request(
                    {
                        "method": "POST",
                        "path": self.path,
                        "headers": {key.lower(): value for key, value in self.headers.items()},
                        "json": body_json,
                    }
                )
                if not self.path.endswith("/responses"):
                    self.send_error(404)
                    return
                body = server.next_sse_body()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        return Handler


def write_auto_compaction_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"
model_provider = "mock_provider"
compact_prompt = "{COMPACT_PROMPT}"
model_auto_compact_token_limit = 1000

[model_providers.mock_provider]
name = "Mock provider for automatic compaction smoke"
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


def response_request_path_counts(requests: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for request in requests:
        path = request.get("path", "")
        counts[path] = counts.get(path, 0) + 1
    return counts


def turn_metadata_from_request(request: dict[str, Any]) -> dict[str, Any]:
    header = (request.get("headers") or {}).get("x-codex-turn-metadata")
    if not header:
        return {}
    try:
        return json.loads(header)
    except json.JSONDecodeError:
        return {"_decode_error": header}


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    response_requests = [
        request for request in requests if str(request.get("path", "")).endswith("/responses")
    ]
    bodies = response_request_bodies(response_requests)
    first_body = body_for_user_text(bodies, FIRST_USER_TEXT)
    second_body = body_for_user_text(bodies, SECOND_USER_TEXT)
    third_body = body_for_user_text(bodies, THIRD_USER_TEXT)
    followup_body = body_for_user_text(bodies, FOLLOWUP_USER_TEXT)
    compaction_indexes = [
        index
        for index, body in enumerate(bodies)
        if response_input_contains(body, COMPACT_PROMPT)
    ]
    compaction_body = bodies[compaction_indexes[0]] if compaction_indexes else {}
    compaction_request = (
        response_requests[compaction_indexes[0]] if compaction_indexes else {}
    )
    compaction_metadata = turn_metadata_from_request(compaction_request)
    return {
        "request_count": len(requests),
        "response_request_count": len(response_requests),
        "paths": [request.get("path") for request in requests],
        "path_counts": response_request_path_counts(requests),
        "compaction_request_count": len(compaction_indexes),
        "compaction_request_index": compaction_indexes[0] if compaction_indexes else None,
        "compaction_metadata_request_kind": compaction_metadata.get("request_kind"),
        "compaction_metadata": compaction_metadata.get("compaction"),
        "first_response_contains_first_user_text": response_input_contains(
            first_body,
            FIRST_USER_TEXT,
        ),
        "second_response_contains_first_user_text": response_input_contains(
            second_body,
            FIRST_USER_TEXT,
        ),
        "second_response_contains_second_user_text": response_input_contains(
            second_body,
            SECOND_USER_TEXT,
        ),
        "compaction_response_contains_prompt": response_input_contains(
            compaction_body,
            COMPACT_PROMPT,
        ),
        "compaction_response_contains_first_user_text": response_input_contains(
            compaction_body,
            FIRST_USER_TEXT,
        ),
        "compaction_response_contains_second_user_text": response_input_contains(
            compaction_body,
            SECOND_USER_TEXT,
        ),
        "compaction_response_contains_third_user_text": response_input_contains(
            compaction_body,
            THIRD_USER_TEXT,
        ),
        "third_response_contains_auto_summary": response_input_contains(
            third_body,
            AUTO_COMPACTION_SUMMARY_TEXT,
        ),
        "third_response_contains_third_user_text": response_input_contains(
            third_body,
            THIRD_USER_TEXT,
        ),
        "followup_response_contains_second_user_text": response_input_contains(
            followup_body,
            SECOND_USER_TEXT,
        ),
        "followup_response_contains_auto_summary": response_input_contains(
            followup_body,
            AUTO_COMPACTION_SUMMARY_TEXT,
        ),
        "followup_response_contains_third_user_text": response_input_contains(
            followup_body,
            THIRD_USER_TEXT,
        ),
        "followup_response_contains_followup_user_text": response_input_contains(
            followup_body,
            FOLLOWUP_USER_TEXT,
        ),
    }


def summarize_turn_notifications(
    client: JsonRpcClient,
    received_start_index: int,
) -> dict[str, Any]:
    new_messages = client.received[received_start_index:]
    notifications = [message for message in new_messages if "method" in message]
    context_compaction_item_ids: list[str] = []
    for notification in notifications:
        item = (notification.get("params") or {}).get("item") or {}
        if item.get("type") == "contextCompaction" and item.get("id"):
            context_compaction_item_ids.append(item["id"])
    return {
        "notification_methods": [notification.get("method") for notification in notifications],
        "context_compaction_item_ids": context_compaction_item_ids,
        "context_compaction_notification_count": len(context_compaction_item_ids),
        "context_compaction_started_completed_same_id": (
            len(context_compaction_item_ids) >= 2
            and context_compaction_item_ids[0] == context_compaction_item_ids[1]
        ),
    }


def send_observed_turn_start(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    client_user_message_id: str,
    text: str,
) -> dict[str, Any]:
    received_start_index = len(client.received)
    result = send_turn_start(
        client,
        request_id,
        thread_id,
        client_user_message_id,
        text,
    )
    result["notification_summary"] = summarize_turn_notifications(
        client,
        received_start_index,
    )
    return result


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
        "contains_context_compaction_item": "contextCompaction" in json.dumps(item_types),
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_third_user_text": THIRD_USER_TEXT in serialized_turns,
        "contains_followup_user_text": FOLLOWUP_USER_TEXT in serialized_turns,
        "contains_first_assistant_text": FIRST_ASSISTANT_TEXT in serialized_turns,
        "contains_second_assistant_text": SECOND_ASSISTANT_TEXT in serialized_turns,
        "contains_auto_compaction_summary": AUTO_COMPACTION_SUMMARY_TEXT
        in serialized_turns,
        "contains_third_assistant_text": THIRD_ASSISTANT_TEXT in serialized_turns,
        "contains_followup_assistant_text": FOLLOWUP_ASSISTANT_TEXT
        in serialized_turns,
    }


def original_rollout_lines(summary: dict[str, Any]) -> list[dict[str, Any]]:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return []
    rollout_path = pathlib.Path(summary["codex_home"]) / rollouts[0]["path"]
    return read_json_lines(rollout_path)


def original_auto_compaction_summary(summary: dict[str, Any]) -> dict[str, Any]:
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
        "contains_auto_compaction_summary": AUTO_COMPACTION_SUMMARY_TEXT in serialized,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
        "contains_second_user_text": SECOND_USER_TEXT in serialized,
        "contains_third_user_text": THIRD_USER_TEXT in serialized,
    }


def chat_auto_compaction_summary(summary: dict[str, Any]) -> dict[str, Any]:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return {
            "package_count": len(packages),
            "timeline_compaction_event_count": 0,
            "journal_compaction_event_count": 0,
            "has_replacement_history": False,
            "contains_auto_compaction_summary": False,
            "contains_first_user_text": False,
            "contains_second_user_text": False,
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
        "contains_auto_compaction_summary": AUTO_COMPACTION_SUMMARY_TEXT
        in journal_serialized,
        "contains_first_user_text": FIRST_USER_TEXT in journal_serialized,
        "contains_second_user_text": SECOND_USER_TEXT in journal_serialized,
        "contains_third_user_text": THIRD_USER_TEXT in journal_serialized,
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

    with AutoCompactionMockResponsesServer() as mock_server:
        write_auto_compaction_mock_config(codex_home, mock_server.url)
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn_start_response = send_observed_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-auto-compaction-first",
                FIRST_USER_TEXT,
            )
            second_turn_start_response = send_observed_turn_start(
                first_client,
                4,
                thread_id,
                "client-user-message-auto-compaction-second",
                SECOND_USER_TEXT,
            )
            third_turn_start_response = send_observed_turn_start(
                first_client,
                5,
                thread_id,
                "client-user-message-auto-compaction-third",
                THIRD_USER_TEXT,
            )
            after_auto_compaction_read_response = send_thread_read(
                first_client,
                6,
                thread_id,
            )
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 7)
            thread_resume_response = send_thread_resume(second_client, 8, thread_id)
            post_resume_read_response = send_thread_read(second_client, 9, thread_id)
            followup_turn_start_response = send_observed_turn_start(
                second_client,
                10,
                thread_id,
                "client-user-message-auto-compaction-followup",
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
                "second_turn_start_response": second_turn_start_response,
                "third_turn_start_response": third_turn_start_response,
                "after_auto_compaction_thread_read_response": after_auto_compaction_read_response,
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
            "normalized_after_auto_compaction_read": normalize_thread_response(
                after_auto_compaction_read_response
            ),
            "normalized_resume": normalize_thread_response(thread_resume_response),
            "normalized_post_resume_read": normalize_thread_response(
                post_resume_read_response
            ),
            "normalized_final_read": normalize_thread_response(final_thread_read_response),
            "thread_read_path_observations": {
                "after_auto_compaction": summarize_path_observation(
                    after_auto_compaction_read_response,
                    thread_id,
                ),
                "post_resume": summarize_path_observation(
                    post_resume_read_response,
                    thread_id,
                ),
                "final": summarize_path_observation(
                    final_thread_read_response,
                    thread_id,
                ),
            },
        }
        if tree_name == "chat-backend":
            chat_package_summary = summarize_chat_packages(chat_root)
            result["chat_package_summary"] = chat_package_summary
            result["chat_auto_compaction_summary"] = chat_auto_compaction_summary(
                chat_package_summary
            )
        else:
            original_storage_summary = summarize_original_storage(codex_home)
            result["original_storage_summary"] = original_storage_summary
            result["original_auto_compaction_summary"] = original_auto_compaction_summary(
                original_storage_summary
            )
        return result


def turn_response_ok(result: dict[str, Any], process_name: str, response_name: str) -> bool:
    return "result" in result[process_name][response_name]["response"]


def turn_notifications_ok(
    result: dict[str, Any],
    process_name: str,
    response_name: str,
) -> bool:
    return not result[process_name][response_name]["notification_errors"]


def context_compaction_notifications_ok(turn_result: dict[str, Any]) -> bool:
    summary = turn_result.get("notification_summary") or {}
    return all(
        [
            summary.get("context_compaction_notification_count", 0) >= 2,
            summary.get("context_compaction_started_completed_same_id"),
        ]
    )


def first_auto_compaction_turn_summary(result: dict[str, Any]) -> dict[str, Any]:
    candidates = [
        ("first", result["first_process"]["first_turn_start_response"]),
        ("second", result["first_process"]["second_turn_start_response"]),
        ("third", result["first_process"]["third_turn_start_response"]),
    ]
    for turn_name, turn_result in candidates:
        notification_summary = turn_result.get("notification_summary") or {}
        if notification_summary.get("context_compaction_notification_count", 0) > 0:
            normalized = {
                "turn": turn_name,
                "notification_methods": notification_summary.get("notification_methods"),
                "context_compaction_notification_count": notification_summary.get(
                    "context_compaction_notification_count"
                ),
                "context_compaction_started_completed_same_id": notification_summary.get(
                    "context_compaction_started_completed_same_id"
                ),
            }
            return {
                "raw": notification_summary,
                "normalized": normalized,
                "ok": context_compaction_notifications_ok(turn_result),
            }
    return {
        "raw": {},
        "normalized": {
            "turn": None,
            "notification_methods": [],
            "context_compaction_notification_count": 0,
            "context_compaction_started_completed_same_id": False,
        },
        "ok": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-auto-compaction-smoke-"
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

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_compaction_storage = original_result["original_auto_compaction_summary"]
    chat_compaction_storage = chat_result["chat_auto_compaction_summary"]
    original_auto_compaction_turn = first_auto_compaction_turn_summary(original_result)
    chat_auto_compaction_turn = first_auto_compaction_turn_summary(chat_result)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-auto-compaction-smoke",
        "matrix_slice": ["K01", "K03-adjacent"],
        "binary_checks": binary_checks,
        "original_first_turn_exit_ok": turn_response_ok(
            original_result,
            "first_process",
            "first_turn_start_response",
        ),
        "chat_backend_first_turn_exit_ok": turn_response_ok(
            chat_result,
            "first_process",
            "first_turn_start_response",
        ),
        "original_second_turn_exit_ok": turn_response_ok(
            original_result,
            "first_process",
            "second_turn_start_response",
        ),
        "chat_backend_second_turn_exit_ok": turn_response_ok(
            chat_result,
            "first_process",
            "second_turn_start_response",
        ),
        "original_third_turn_exit_ok": turn_response_ok(
            original_result,
            "first_process",
            "third_turn_start_response",
        ),
        "chat_backend_third_turn_exit_ok": turn_response_ok(
            chat_result,
            "first_process",
            "third_turn_start_response",
        ),
        "original_turn_notifications_ok": all(
            [
                turn_notifications_ok(
                    original_result,
                    "first_process",
                    "first_turn_start_response",
                ),
                turn_notifications_ok(
                    original_result,
                    "first_process",
                    "second_turn_start_response",
                ),
                turn_notifications_ok(
                    original_result,
                    "first_process",
                    "third_turn_start_response",
                ),
            ]
        ),
        "chat_backend_turn_notifications_ok": all(
            [
                turn_notifications_ok(
                    chat_result,
                    "first_process",
                    "first_turn_start_response",
                ),
                turn_notifications_ok(
                    chat_result,
                    "first_process",
                    "second_turn_start_response",
                ),
                turn_notifications_ok(
                    chat_result,
                    "first_process",
                    "third_turn_start_response",
                ),
            ]
        ),
        "original_auto_compaction_notifications_ok": original_auto_compaction_turn["ok"],
        "chat_backend_auto_compaction_notifications_ok": chat_auto_compaction_turn["ok"],
        "auto_compaction_notification_summary_equal": (
            original_auto_compaction_turn["normalized"]
            == chat_auto_compaction_turn["normalized"]
        ),
        "original_resume_exit_ok": "result"
        in original_result["second_process"]["thread_resume_response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_result["second_process"]["thread_resume_response"],
        "original_followup_turn_exit_ok": turn_response_ok(
            original_result,
            "second_process",
            "followup_turn_start_response",
        ),
        "chat_backend_followup_turn_exit_ok": turn_response_ok(
            chat_result,
            "second_process",
            "followup_turn_start_response",
        ),
        "original_followup_notifications_ok": turn_notifications_ok(
            original_result,
            "second_process",
            "followup_turn_start_response",
        ),
        "chat_backend_followup_notifications_ok": turn_notifications_ok(
            chat_result,
            "second_process",
            "followup_turn_start_response",
        ),
        "normalized_after_auto_compaction_read_equal": (
            original_result["normalized_after_auto_compaction_read"]
            == chat_result["normalized_after_auto_compaction_read"]
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
        "mock_auto_compaction_context_ok": all(
            [
                original_mock == chat_mock,
                original_mock["response_request_count"] >= 5,
                original_mock["compaction_request_count"] == 1,
                original_mock["compaction_metadata_request_kind"] == "compaction",
                (original_mock["compaction_metadata"] or {}).get("trigger") == "auto",
                (original_mock["compaction_metadata"] or {}).get("reason")
                == "context_limit",
                original_mock["compaction_response_contains_prompt"],
                original_mock["compaction_response_contains_first_user_text"],
                not original_mock["compaction_response_contains_second_user_text"],
                not original_mock["compaction_response_contains_third_user_text"],
                original_mock["third_response_contains_auto_summary"],
                original_mock["third_response_contains_third_user_text"],
                original_mock["followup_response_contains_second_user_text"],
                original_mock["followup_response_contains_auto_summary"],
                original_mock["followup_response_contains_followup_user_text"],
            ]
        ),
        "original_auto_compaction_storage_ok": all(
            [
                original_compaction_storage["compacted_count"] >= 1,
                original_compaction_storage["has_replacement_history"],
                original_compaction_storage["contains_auto_compaction_summary"],
                original_compaction_storage["contains_first_user_text"],
            ]
        ),
        "chat_backend_auto_compaction_storage_ok": all(
            [
                chat_compaction_storage["timeline_compaction_event_count"] >= 1,
                chat_compaction_storage["journal_compaction_event_count"] >= 1,
                chat_compaction_storage["has_replacement_history"],
                chat_compaction_storage["contains_auto_compaction_summary"],
                chat_compaction_storage["contains_first_user_text"],
            ]
        ),
        "original_auto_compaction_notification_summary": original_auto_compaction_turn[
            "normalized"
        ],
        "chat_backend_auto_compaction_notification_summary": chat_auto_compaction_turn[
            "normalized"
        ],
        "original_normalized_final_read": original_result["normalized_final_read"],
        "chat_backend_normalized_final_read": chat_result["normalized_final_read"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_auto_compaction_summary": original_compaction_storage,
        "chat_backend_auto_compaction_summary": chat_compaction_storage,
        "original_storage_summary": original_result["original_storage_summary"],
        "chat_package_summary": chat_result["chat_package_summary"],
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observations"],
            "chat-backend": chat_result["thread_read_path_observations"],
        },
        "not_yet_proven": [
            "remote automatic compaction",
            "world state full/patch K04",
            "legacy compaction fallback K05",
            "broader compaction-boundary rollback variants",
            "full context-window lineage parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/auto-compaction-response.json", original_result)
    write_json(output_dir / "chat-backend/auto-compaction-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Auto Compaction Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, data-fidelity report, and
relevant vendored automatic compaction source/tests were read.

## Scope

This smoke covers a first K01 automatic compaction slice:

- complete two durable turns with high token usage;
- start a third turn that triggers pre-turn automatic compaction;
- observe `contextCompaction` `item/started` and `item/completed` notifications;
- verify the mock model saw a compaction request with `trigger=auto` and
  `reason=context_limit`;
- cold-start a new app-server process;
- `thread/resume`;
- start a follow-up turn and verify model-context markers match original Codex;
- verify original rollout and `.chat` package both preserved compaction storage.

It is not a complete compaction proof. It does not cover remote automatic
compaction, world-state full/patch restore, legacy compaction fallback,
crash recovery, performance, complete data fidelity, or final
user-indistinguishability.

## Result

- original third turn triggered automatic compaction notifications: `{summary['original_auto_compaction_notifications_ok']}`
- `.chat` third turn triggered automatic compaction notifications: `{summary['chat_backend_auto_compaction_notifications_ok']}`
- automatic compaction notification summaries equal: `{summary['auto_compaction_notification_summary_equal']}`
- original cold resume succeeded: `{summary['original_resume_exit_ok']}`
- `.chat` cold resume succeeded: `{summary['chat_backend_resume_exit_ok']}`
- normalized final thread read equal: `{summary['normalized_final_read_equal']}`
- mock request counts equal: `{summary['mock_response_request_counts_equal']}`
- mock request context markers matched original: `{summary['mock_context_markers_equal']}`
- automatic compaction context checks passed: `{summary['mock_auto_compaction_context_ok']}`
- original rollout preserved compacted replacement history: `{summary['original_auto_compaction_storage_ok']}`
- `.chat` timeline/journal preserved compaction checkpoint/source transport: `{summary['chat_backend_auto_compaction_storage_ok']}`

## Notification Summary

```json
{json.dumps({'original': summary['original_auto_compaction_notification_summary'], 'chat-backend': summary['chat_backend_auto_compaction_notification_summary']}, indent=2, sort_keys=True)}
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
{output_dir.relative_to(VALIDATION_DIR)}/original/auto-compaction-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/auto-compaction-response.json
```

## Not Yet Proven

This smoke does not prove remote automatic compaction, world-state full/patch
restore, legacy compaction fallback, crash recovery, complete data fidelity, or
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_first_turn_exit_ok"],
            summary["chat_backend_first_turn_exit_ok"],
            summary["original_second_turn_exit_ok"],
            summary["chat_backend_second_turn_exit_ok"],
            summary["original_third_turn_exit_ok"],
            summary["chat_backend_third_turn_exit_ok"],
            summary["original_turn_notifications_ok"],
            summary["chat_backend_turn_notifications_ok"],
            summary["original_auto_compaction_notifications_ok"],
            summary["chat_backend_auto_compaction_notifications_ok"],
            summary["auto_compaction_notification_summary_equal"],
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_followup_turn_exit_ok"],
            summary["chat_backend_followup_turn_exit_ok"],
            summary["original_followup_notifications_ok"],
            summary["chat_backend_followup_notifications_ok"],
            summary["normalized_after_auto_compaction_read_equal"],
            summary["normalized_resume_equal"],
            summary["normalized_post_resume_read_equal"],
            summary["normalized_final_read_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_auto_compaction_context_ok"],
            summary["original_auto_compaction_storage_ok"],
            summary["chat_backend_auto_compaction_storage_ok"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
