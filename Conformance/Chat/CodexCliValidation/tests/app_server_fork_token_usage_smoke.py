#!/usr/bin/env python3
"""Run app-server fork token-usage replay parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers fork restored-token-usage
ordering and payload fidelity after a two-turn source thread with non-zero,
asymmetric usage values.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import queue
import sys
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_fork_smoke import (  # noqa: E402
    line_count,
    package_line_counts,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_start,
    send_turn_start,
    snapshot_path_content,
    thread_from_response,
)
from app_server_fork_variants_smoke import (  # noqa: E402
    send_thread_fork,
)


FIRST_USER_TEXT = "Fork token usage first source turn."
SECOND_USER_TEXT = "Fork token usage second source turn."
ASSISTANT_TEXT = "Fork token usage answer from mock model."

USAGE_SEQUENCE = [
    {
        "input_tokens": 40,
        "cached_tokens": 5,
        "output_tokens": 20,
        "reasoning_tokens": 2,
        "total_tokens": 60,
    },
    {
        "input_tokens": 70,
        "cached_tokens": 10,
        "output_tokens": 20,
        "reasoning_tokens": 5,
        "total_tokens": 90,
    },
]

EXPECTED_TOTAL_USAGE = {
    "totalTokens": 150,
    "inputTokens": 110,
    "cachedInputTokens": 15,
    "outputTokens": 40,
    "reasoningOutputTokens": 7,
}
EXPECTED_LAST_USAGE = {
    "totalTokens": 90,
    "inputTokens": 70,
    "cachedInputTokens": 10,
    "outputTokens": 20,
    "reasoningOutputTokens": 5,
}


def tokenized_sse_response(
    response_id: str,
    message_id: str,
    text: str,
    usage: dict[str, int],
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
                    "input_tokens": usage["input_tokens"],
                    "input_tokens_details": {
                        "cached_tokens": usage["cached_tokens"],
                    },
                    "output_tokens": usage["output_tokens"],
                    "output_tokens_details": {
                        "reasoning_tokens": usage["reasoning_tokens"],
                    },
                    "total_tokens": usage["total_tokens"],
                },
            },
        },
    ]
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


class TokenUsageMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        usage = USAGE_SEQUENCE[min(counter - 1, len(USAGE_SEQUENCE) - 1)]
        return tokenized_sse_response(
            f"resp-fork-token-usage-{counter}",
            f"msg-fork-token-usage-{counter}",
            self.answer_text,
            usage,
        )


def receive_next_json_message(
    client: JsonRpcClient,
    timeout_seconds: float,
    description: str,
) -> dict[str, Any]:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if client.process.poll() is not None and client._stdout_queue.empty():
            break
        try:
            line = client._stdout_queue.get(timeout=0.1)
        except queue.Empty:
            continue
        payload = line.strip()
        try:
            message = json.loads(payload)
        except json.JSONDecodeError:
            continue
        client.received.append(message)
        return message
    raise TimeoutError(
        f"timed out waiting for {description}; process status={client.process.poll()}"
    )


def drain_available_messages(
    client: JsonRpcClient,
    quiet_seconds: float = 0.5,
    max_seconds: float = 3.0,
) -> list[dict[str, Any]]:
    drained: list[dict[str, Any]] = []
    deadline = time.time() + max_seconds
    quiet_deadline = time.time() + quiet_seconds
    while time.time() < deadline:
        remaining = min(0.1, max(0.0, quiet_deadline - time.time()))
        try:
            line = client._stdout_queue.get(timeout=remaining)
        except queue.Empty:
            if time.time() >= quiet_deadline:
                break
            continue
        try:
            message = json.loads(line.strip())
        except json.JSONDecodeError:
            continue
        client.received.append(message)
        drained.append(message)
        quiet_deadline = time.time() + quiet_seconds
    return drained


def collect_fork_notifications(
    client: JsonRpcClient,
    request_id: int,
    source_thread_id: str | None,
    *,
    exclude_turns: bool,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/fork",
            "params": {
                "threadId": source_thread_id,
                "excludeTurns": exclude_turns,
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications: list[dict[str, Any]] = []
    errors: list[str] = []
    if "error" not in response:
        while True:
            try:
                message = receive_next_json_message(
                    client,
                    timeout_seconds=30,
                    description="fork notification",
                )
            except TimeoutError as exc:
                errors.append(str(exc))
                break
            if "method" not in message:
                continue
            notifications.append(message)
            if message.get("method") == "thread/started":
                break

        # Upstream requires excludeTurns=true to skip restored token-usage
        # replay. Wait briefly after thread/started to catch a late replay bug.
        if exclude_turns:
            try:
                message = client.receive_until_method(
                    "thread/tokenUsage/updated",
                    timeout_seconds=2,
                )
                notifications.append(message)
            except TimeoutError:
                pass

    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": errors,
    }


def token_usage_notifications(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        message
        for message in messages
        if message.get("method") == "thread/tokenUsage/updated"
    ]


def notification_methods(messages: list[dict[str, Any]]) -> list[str | None]:
    return [message.get("method") for message in messages if "method" in message]


def turns_from_response(response: dict[str, Any]) -> list[dict[str, Any]]:
    return thread_from_response(response).get("turns") or []


def normalize_source_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_id_present": thread.get("id") is not None,
        "thread_status_type": status_type(thread.get("status")),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "model": thread.get("model"),
        "model_provider": thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def normalize_fork_response(
    fork_result: dict[str, Any],
    *,
    source_thread_id: str | None,
    source_path: str | None,
    expect_turns: bool,
) -> dict[str, Any]:
    response = fork_result["response"]
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    thread_path = thread.get("path")
    token_notes = token_usage_notifications(fork_result["notifications"])
    restored_token = token_notes[0] if token_notes else None
    restored_params = (restored_token or {}).get("params") or {}
    restored_usage = restored_params.get("tokenUsage") or {}
    expected_turn_id = turns[-1].get("id") if turns and expect_turns else None
    methods = notification_methods(fork_result["notifications"])
    first_two_methods = methods[:2]
    return {
        "has_error": "error" in response,
        "notification_errors": fork_result.get("notification_errors"),
        "notification_methods": methods,
        "first_two_notification_methods": first_two_methods,
        "token_usage_before_thread_started": (
            first_two_methods
            == ["thread/tokenUsage/updated", "thread/started"]
        ),
        "thread_started_seen": "thread/started" in methods,
        "token_usage_notification_count": len(token_notes),
        "restored_token_usage_seen": restored_token is not None,
        "restored_thread_id_matches": restored_params.get("threadId") == thread.get("id"),
        "restored_turn_id_present": restored_params.get("turnId") is not None,
        "restored_turn_id_matches_expected": expected_turn_id is not None
        and restored_params.get("turnId") == expected_turn_id,
        "restored_total_usage": restored_usage.get("total"),
        "restored_last_usage": restored_usage.get("last"),
        "restored_model_context_window": restored_usage.get("modelContextWindow"),
        "restored_total_usage_matches_expected": restored_usage.get("total")
        == EXPECTED_TOTAL_USAGE,
        "restored_last_usage_matches_expected": restored_usage.get("last")
        == EXPECTED_LAST_USAGE,
        "thread_id_present": thread.get("id") is not None,
        "thread_id_differs_from_source": source_thread_id is not None
        and thread.get("id") != source_thread_id,
        "session_id_equals_thread_id": thread.get("sessionId") == thread.get("id"),
        "forked_from_matches_source": source_thread_id is not None
        and thread.get("forkedFromId") == source_thread_id,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread_path is not None,
        "path_differs_from_source": thread_path is not None and thread_path != source_path,
        "turn_count": len(turns),
        "turn_count_matches_expected": len(turns) == (2 if expect_turns else 0),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    response_requests = [
        request for request in requests if request.get("path", "").endswith("/responses")
    ]
    return {
        "request_count": len(requests),
        "response_request_count": len(response_requests),
        "paths": [request.get("path") for request in requests],
        "extra_response_request_after_source_turns": len(response_requests)
        > len(USAGE_SEQUENCE),
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

    with TokenUsageMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            source_thread_id, thread_start_response = send_thread_start(
                client,
                2,
                workspace,
            )

            first_turn = send_turn_start(
                client,
                3,
                source_thread_id,
                "client-user-message-fork-token-usage-1",
                FIRST_USER_TEXT,
            )
            first_turn_drain = drain_available_messages(client)
            second_turn = send_turn_start(
                client,
                4,
                source_thread_id,
                "client-user-message-fork-token-usage-2",
                SECOND_USER_TEXT,
            )
            second_turn_drain = drain_available_messages(client)

            source_read_before_fork_response = send_thread_read(
                client,
                5,
                source_thread_id,
            )
            source_path = thread_from_response(source_read_before_fork_response).get("path")
            source_snapshot_before_fork = snapshot_path_content(source_path)
            pre_fork_storage = (
                summarize_original_storage(codex_home)
                if tree_name == "original"
                else summarize_chat_packages(chat_root)
            )

            persistent_fork = collect_fork_notifications(
                client,
                6,
                source_thread_id,
                exclude_turns=False,
            )
            persistent_fork_thread_id = thread_from_response(
                persistent_fork["response"]
            ).get("id")
            persistent_fork_read_response = send_thread_read(
                client,
                7,
                persistent_fork_thread_id,
            )
            source_snapshot_after_persistent_fork = snapshot_path_content(source_path)
            post_persistent_fork_storage = (
                summarize_original_storage(codex_home)
                if tree_name == "original"
                else summarize_chat_packages(chat_root)
            )

            exclude_turns_fork = collect_fork_notifications(
                client,
                8,
                source_thread_id,
                exclude_turns=True,
            )
            final_list_response = send_thread_list(client, 9)
            source_snapshot_after_exclude_turns_fork = snapshot_path_content(source_path)
            post_exclude_turns_fork_storage = (
                summarize_original_storage(codex_home)
                if tree_name == "original"
                else summarize_chat_packages(chat_root)
            )
        finally:
            stderr = client.close()

    live_token_notes = token_usage_notifications(
        first_turn.get("notifications", [])
        + first_turn_drain
        + second_turn.get("notifications", [])
        + second_turn_drain
    )
    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "first_turn": first_turn,
        "first_turn_drain": first_turn_drain,
        "second_turn": second_turn,
        "second_turn_drain": second_turn_drain,
        "live_token_usage_notifications": live_token_notes,
        "source_read_before_fork_response": source_read_before_fork_response,
        "persistent_fork": persistent_fork,
        "persistent_fork_read_response": persistent_fork_read_response,
        "exclude_turns_fork": exclude_turns_fork,
        "final_list_response": final_list_response,
        "normalized_source_before_fork": normalize_source_response(
            source_read_before_fork_response,
        ),
        "normalized_persistent_fork": normalize_fork_response(
            persistent_fork,
            source_thread_id=source_thread_id,
            source_path=source_path,
            expect_turns=True,
        ),
        "normalized_persistent_fork_read": normalize_source_response(
            persistent_fork_read_response,
        ),
        "normalized_exclude_turns_fork": normalize_fork_response(
            exclude_turns_fork,
            source_thread_id=source_thread_id,
            source_path=source_path,
            expect_turns=False,
        ),
        "source_snapshot_before_fork": source_snapshot_before_fork,
        "source_snapshot_after_persistent_fork": source_snapshot_after_persistent_fork,
        "source_snapshot_after_exclude_turns_fork": source_snapshot_after_exclude_turns_fork,
        "source_snapshot_unchanged_after_persistent_fork": (
            source_snapshot_before_fork == source_snapshot_after_persistent_fork
        ),
        "source_snapshot_unchanged_after_exclude_turns_fork": (
            source_snapshot_before_fork == source_snapshot_after_exclude_turns_fork
        ),
        "pre_fork_storage_summary": pre_fork_storage,
        "post_persistent_fork_storage_summary": post_persistent_fork_storage,
        "post_exclude_turns_fork_storage_summary": post_exclude_turns_fork_storage,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    return result


def active_conversation_line_counts(summary: dict[str, Any]) -> list[int]:
    if "rollouts" in summary:
        return sorted(
            item.get("line_count")
            for item in (summary.get("rollouts") or [])
            if item.get("line_count") is not None
            and item.get("path") != "session_index.jsonl"
        )
    return package_line_counts(summary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-fork-token-usage-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    comparison_keys = [
        "normalized_source_before_fork",
        "normalized_persistent_fork",
        "normalized_persistent_fork_read",
        "normalized_exclude_turns_fork",
        "source_snapshot_unchanged_after_persistent_fork",
        "source_snapshot_unchanged_after_exclude_turns_fork",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    original_pre_line_count = line_count(
        original_result["pre_fork_storage_summary"], "rollouts"
    )
    chat_pre_line_counts = package_line_counts(chat_result["pre_fork_storage_summary"])

    original_post_persistent_line_counts = active_conversation_line_counts(
        original_result["post_persistent_fork_storage_summary"]
    )
    chat_post_persistent_line_counts = active_conversation_line_counts(
        chat_result["post_persistent_fork_storage_summary"]
    )
    original_post_exclude_line_counts = active_conversation_line_counts(
        original_result["post_exclude_turns_fork_storage_summary"]
    )
    chat_post_exclude_line_counts = active_conversation_line_counts(
        chat_result["post_exclude_turns_fork_storage_summary"]
    )

    original_persistent = original_result["normalized_persistent_fork"]
    chat_persistent = chat_result["normalized_persistent_fork"]
    original_exclude = original_result["normalized_exclude_turns_fork"]
    chat_exclude = chat_result["normalized_exclude_turns_fork"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-fork-token-usage-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_fork_token_usage_fields_equal": all(comparisons.values()),
        "original_source_has_two_completed_turns": (
            original_result["normalized_source_before_fork"]["turn_count"] == 2
            and original_result["normalized_source_before_fork"]["turn_statuses"]
            == ["completed", "completed"]
        ),
        "chat_backend_source_has_two_completed_turns": (
            chat_result["normalized_source_before_fork"]["turn_count"] == 2
            and chat_result["normalized_source_before_fork"]["turn_statuses"]
            == ["completed", "completed"]
        ),
        "original_live_token_usage_observed": len(
            original_result["live_token_usage_notifications"]
        )
        >= 2,
        "chat_backend_live_token_usage_observed": len(
            chat_result["live_token_usage_notifications"]
        )
        >= 2,
        "original_restored_token_usage_seen": original_persistent[
            "restored_token_usage_seen"
        ],
        "chat_backend_restored_token_usage_seen": chat_persistent[
            "restored_token_usage_seen"
        ],
        "original_restored_token_usage_before_thread_started": original_persistent[
            "token_usage_before_thread_started"
        ],
        "chat_backend_restored_token_usage_before_thread_started": chat_persistent[
            "token_usage_before_thread_started"
        ],
        "original_restored_turn_id_matches_latest_fork_turn": original_persistent[
            "restored_turn_id_matches_expected"
        ],
        "chat_backend_restored_turn_id_matches_latest_fork_turn": chat_persistent[
            "restored_turn_id_matches_expected"
        ],
        "original_restored_total_usage_matches_expected": original_persistent[
            "restored_total_usage_matches_expected"
        ],
        "chat_backend_restored_total_usage_matches_expected": chat_persistent[
            "restored_total_usage_matches_expected"
        ],
        "original_restored_last_usage_matches_expected": original_persistent[
            "restored_last_usage_matches_expected"
        ],
        "chat_backend_restored_last_usage_matches_expected": chat_persistent[
            "restored_last_usage_matches_expected"
        ],
        "original_exclude_turns_skipped_token_usage": (
            original_exclude["turn_count"] == 0
            and original_exclude["token_usage_notification_count"] == 0
            and "thread/started" in original_exclude["notification_methods"]
        ),
        "chat_backend_exclude_turns_skipped_token_usage": (
            chat_exclude["turn_count"] == 0
            and chat_exclude["token_usage_notification_count"] == 0
            and "thread/started" in chat_exclude["notification_methods"]
        ),
        "original_source_unchanged_after_forks": original_result[
            "source_snapshot_unchanged_after_exclude_turns_fork"
        ],
        "chat_backend_source_unchanged_after_forks": chat_result[
            "source_snapshot_unchanged_after_exclude_turns_fork"
        ],
        "mock_response_request_counts_equal": original_result["mock_server_summary"][
            "response_request_count"
        ]
        == chat_result["mock_server_summary"]["response_request_count"],
        "mock_no_extra_model_request_for_forks": (
            original_result["mock_server_summary"]["response_request_count"] == 2
            and chat_result["mock_server_summary"]["response_request_count"] == 2
        ),
        "journal_line_count_matches_original_before_fork": (
            original_pre_line_count is not None
            and chat_pre_line_counts == [original_pre_line_count]
        ),
        "journal_line_counts_match_original_after_persistent_fork": (
            original_post_persistent_line_counts == chat_post_persistent_line_counts
        ),
        "journal_line_counts_match_original_after_exclude_turns_fork": (
            original_post_exclude_line_counts == chat_post_exclude_line_counts
        ),
        "original": {key: original_result[key] for key in comparison_keys},
        "chat_backend": {key: chat_result[key] for key in comparison_keys},
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_storage": {
            "pre_fork": original_result["pre_fork_storage_summary"],
            "post_persistent_fork": original_result[
                "post_persistent_fork_storage_summary"
            ],
            "post_exclude_turns_fork": original_result[
                "post_exclude_turns_fork_storage_summary"
            ],
        },
        "chat_package": {
            "pre_fork": chat_result["pre_fork_storage_summary"],
            "post_persistent_fork": chat_result[
                "post_persistent_fork_storage_summary"
            ],
            "post_exclude_turns_fork": chat_result[
                "post_exclude_turns_fork_storage_summary"
            ],
        },
        "not_yet_proven": [
            "fork around interrupted active turn",
            "rollback parity",
            "compaction/context restore parity",
            "command execution parity",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/fork-token-usage-response.json", original_result)
    write_json(output_dir / "chat-backend/fork-token-usage-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Fork Token Usage Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with non-zero token usage values.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server fork/token-usage replay source, protocol definitions,
upstream fork/resume token-usage tests, and the current `.chat` backend
implementation were also read.

## Scope

This smoke covers:

```text
thread/start
turn/start x2 with non-zero usage
thread/read source includeTurns=true
thread/fork includeTurns=true
thread/tokenUsage/updated restored replay ordering
thread/started after restored token usage
thread/read persistent fork includeTurns=true
thread/fork excludeTurns=true
thread/list active
```

It proves only a narrow F-token-usage replay slice for completed source turns.
It does not prove interrupted active-turn fork, rollback, compaction, command
execution, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability.

## Result

- all normalized fork token-usage fields equal: `{summary['all_normalized_fork_token_usage_fields_equal']}`
- original source has two completed turns: `{summary['original_source_has_two_completed_turns']}`
- `.chat` source has two completed turns: `{summary['chat_backend_source_has_two_completed_turns']}`
- original live token usage observed during source turns: `{summary['original_live_token_usage_observed']}`
- `.chat` live token usage observed during source turns: `{summary['chat_backend_live_token_usage_observed']}`
- original restored token usage seen: `{summary['original_restored_token_usage_seen']}`
- `.chat` restored token usage seen: `{summary['chat_backend_restored_token_usage_seen']}`
- original restored usage before thread/started: `{summary['original_restored_token_usage_before_thread_started']}`
- `.chat` restored usage before thread/started: `{summary['chat_backend_restored_token_usage_before_thread_started']}`
- original restored turn id matches latest fork turn: `{summary['original_restored_turn_id_matches_latest_fork_turn']}`
- `.chat` restored turn id matches latest fork turn: `{summary['chat_backend_restored_turn_id_matches_latest_fork_turn']}`
- original restored total usage matches expected: `{summary['original_restored_total_usage_matches_expected']}`
- `.chat` restored total usage matches expected: `{summary['chat_backend_restored_total_usage_matches_expected']}`
- original restored last usage matches expected: `{summary['original_restored_last_usage_matches_expected']}`
- `.chat` restored last usage matches expected: `{summary['chat_backend_restored_last_usage_matches_expected']}`
- original excludeTurns skipped token usage: `{summary['original_exclude_turns_skipped_token_usage']}`
- `.chat` excludeTurns skipped token usage: `{summary['chat_backend_exclude_turns_skipped_token_usage']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- no extra model request was made for forks: `{summary['mock_no_extra_model_request_for_forks']}`
- `.chat` journal line counts matched original before fork: `{summary['journal_line_count_matches_original_before_fork']}`
- `.chat` journal line counts matched original after persistent fork: `{summary['journal_line_counts_match_original_after_persistent_fork']}`
- `.chat` journal line counts matched original after excludeTurns fork: `{summary['journal_line_counts_match_original_after_exclude_turns_fork']}`

## Comparison Booleans

```json
{json.dumps(comparisons, indent=2, sort_keys=True)}
```

## Original Normalized Fields

```json
{json.dumps(summary['original'], indent=2, sort_keys=True)}
```

## `.chat` Backend Normalized Fields

```json
{json.dumps(summary['chat_backend'], indent=2, sort_keys=True)}
```

## `.chat` Package Observations

```json
{json.dumps(summary['chat_package'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/fork-token-usage-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/fork-token-usage-response.json
```

## Not Yet Proven

This smoke does not prove interrupted active-turn fork, rollback,
compaction/context restore, command execution, crash recovery, cold history,
complete data fidelity, or final user-indistinguishability under normal Codex
usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_fork_token_usage_fields_equal"],
            summary["original_source_has_two_completed_turns"],
            summary["chat_backend_source_has_two_completed_turns"],
            summary["original_restored_token_usage_seen"],
            summary["chat_backend_restored_token_usage_seen"],
            summary["original_restored_token_usage_before_thread_started"],
            summary["chat_backend_restored_token_usage_before_thread_started"],
            summary["original_restored_turn_id_matches_latest_fork_turn"],
            summary["chat_backend_restored_turn_id_matches_latest_fork_turn"],
            summary["original_restored_total_usage_matches_expected"],
            summary["chat_backend_restored_total_usage_matches_expected"],
            summary["original_restored_last_usage_matches_expected"],
            summary["chat_backend_restored_last_usage_matches_expected"],
            summary["original_exclude_turns_skipped_token_usage"],
            summary["chat_backend_exclude_turns_skipped_token_usage"],
            summary["original_source_unchanged_after_forks"],
            summary["chat_backend_source_unchanged_after_forks"],
            summary["mock_response_request_counts_equal"],
            summary["mock_no_extra_model_request_for_forks"],
            summary["journal_line_count_matches_original_before_fork"],
            summary["journal_line_counts_match_original_after_persistent_fork"],
            summary["journal_line_counts_match_original_after_exclude_turns_fork"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
