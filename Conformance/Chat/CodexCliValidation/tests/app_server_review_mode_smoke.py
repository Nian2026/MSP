#!/usr/bin/env python3
"""Run app-server review-mode persistence parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers source-backed persisted
`EventMsg::EnteredReviewMode` and `EventMsg::ExitedReviewMode`, proving that the
original backend and the `.chat` backend keep the same durable review-mode facts
and expose the same app-server-visible review items.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import threading
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
    normalize_thread_list_response,
    read_json_lines,
    summarize_chat_packages,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_fork_smoke import (  # noqa: E402
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_start,
)


CUSTOM_REVIEW_INSTRUCTIONS = "Review-mode parity custom instructions for .chat validation."
REVIEW_OVERALL_EXPLANATION = "Review mode persistence looks solid in this fixture."
REVIEW_OUTPUT = {
    "findings": [],
    "overall_correctness": "patch is correct",
    "overall_explanation": REVIEW_OVERALL_EXPLANATION,
    "overall_confidence_score": 0.91,
}


def sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def review_sse_response(response_id: str) -> bytes:
    review_text = json.dumps(REVIEW_OUTPUT, separators=(",", ":"))
    return sse(
        [
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
                    "id": "msg-review-mode-smoke-final",
                    "content": [{"type": "output_text", "text": review_text}],
                },
            },
            {
                "type": "response.completed",
                "response": {
                    "id": response_id,
                    "usage": {
                        "input_tokens": 11,
                        "input_tokens_details": {"cached_tokens": 0},
                        "output_tokens": 13,
                        "output_tokens_details": {"reasoning_tokens": 0},
                        "total_tokens": 24,
                    },
                },
            },
        ]
    )


class ReviewResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(REVIEW_OVERALL_EXPLANATION)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        return review_sse_response(f"resp-review-mode-smoke-{counter}")

    def summary(self) -> dict[str, Any]:
        base = super().summary()
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        serialized = [
            json.dumps(request["json"], ensure_ascii=False)
            for request in response_requests
        ]
        base.update(
            {
                "response_request_count": len(response_requests),
                "first_response_input_contains_review_instructions": any(
                    CUSTOM_REVIEW_INSTRUCTIONS in body for body in serialized[:1]
                ),
                "first_response_input_mentions_review": any(
                    "review" in body.lower() for body in serialized[:1]
                ),
            }
        )
        return base


def write_review_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write('\nreview_model = "mock-model"\n')


def item_type_from_message(message: dict[str, Any]) -> str | None:
    params = message.get("params") or {}
    item = params.get("item") or {}
    return item.get("type")


def item_review_text(message: dict[str, Any]) -> str | None:
    params = message.get("params") or {}
    item = params.get("item") or {}
    return item.get("review")


def collect_until_turn_completed(
    client: JsonRpcClient,
    start_index: int,
    timeout_seconds: int,
) -> list[dict[str, Any]]:
    deadline = time.time() + timeout_seconds
    while not any(
        message.get("method") == "turn/completed"
        for message in client.received[start_index:]
    ):
        remaining = max(1, int(deadline - time.time()))
        if remaining <= 0:
            raise TimeoutError("timed out waiting for review turn/completed")
        client.receive_until(
            lambda message: message.get("method") == "turn/completed",
            remaining,
            "review turn/completed",
        )
        if time.time() > deadline:
            break
    return [
        message for message in client.received[start_index:] if message.get("method")
    ]


def send_review_start(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    start_index = len(client.received)
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "review/start",
            "params": {
                "threadId": thread_id,
                "delivery": "inline",
                "target": {
                    "type": "custom",
                    "instructions": CUSTOM_REVIEW_INSTRUCTIONS,
                },
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notification_errors: list[str] = []
    notifications: list[dict[str, Any]] = [
        message for message in client.received[start_index:] if message.get("method")
    ]
    if "error" not in response:
        try:
            notifications = collect_until_turn_completed(
                client,
                start_index,
                timeout_seconds=90,
            )
        except TimeoutError as exc:
            notification_errors.append(str(exc))
            notifications = [
                message
                for message in client.received[start_index:]
                if message.get("method")
            ]
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def normalize_review_start_result(result: dict[str, Any]) -> dict[str, Any]:
    response = result.get("response") or {}
    response_result = response.get("result") or {}
    turn = response_result.get("turn") or {}
    items = turn.get("items") or []
    notifications = result.get("notifications") or []
    started_items = [
        item_type_from_message(message)
        for message in notifications
        if message.get("method") == "item/started"
    ]
    completed_items = [
        item_type_from_message(message)
        for message in notifications
        if message.get("method") == "item/completed"
    ]
    review_texts = [
        item_review_text(message)
        for message in notifications
        if item_type_from_message(message) in {"enteredReviewMode", "exitedReviewMode"}
    ]
    return {
        "has_error": "error" in response,
        "review_thread_id_present": response_result.get("reviewThreadId") is not None,
        "turn_status": turn.get("status"),
        "turn_item_types": [item.get("type") for item in items],
        "notification_methods": [message.get("method") for message in notifications],
        "started_item_types": started_items,
        "completed_item_types": completed_items,
        "entered_review_started_count": started_items.count("enteredReviewMode"),
        "exited_review_completed_count": completed_items.count("exitedReviewMode"),
        "turn_completed_count": sum(
            1 for message in notifications if message.get("method") == "turn/completed"
        ),
        "review_text_contains_hint": any(
            CUSTOM_REVIEW_INSTRUCTIONS in (text or "") for text in review_texts
        ),
        "review_text_contains_output": any(
            REVIEW_OVERALL_EXPLANATION in (text or "") for text in review_texts
        ),
        "notification_errors": result.get("notification_errors") or [],
    }


def normalize_thread_read_for_review(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    item_types_by_turn = []
    item_count_by_turn = []
    serialized = json.dumps(turns, ensure_ascii=False)
    for turn in turns:
        items = turn.get("items") or []
        item_count_by_turn.append(len(items))
        item_types_by_turn.append([item.get("type") for item in items])
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "item_count_by_turn": item_count_by_turn,
        "item_types_by_turn": item_types_by_turn,
        "contains_review_instructions": CUSTOM_REVIEW_INSTRUCTIONS in serialized,
        "contains_review_output": REVIEW_OVERALL_EXPLANATION in serialized,
        "contains_entered_review_mode": "enteredReviewMode" in serialized,
        "contains_exited_review_mode": "exitedReviewMode" in serialized,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_review_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    event_msg_types: list[str] = []
    response_types: list[str] = []
    entered: list[dict[str, Any]] = []
    exited: list[dict[str, Any]] = []
    for item in items:
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        if item.get("type") == "event_msg":
            event_msg_types.append(nested_type)
            if nested_type == "entered_review_mode":
                entered.append(payload)
            elif nested_type == "exited_review_mode":
                exited.append(payload)
        elif item.get("type") == "response_item":
            response_types.append(nested_type)

    serialized_entered = json.dumps(entered, ensure_ascii=False)
    serialized_exited = json.dumps(exited, ensure_ascii=False)
    return {
        "line_count": len(items),
        "event_msg_types": event_msg_types,
        "response_types": response_types,
        "entered_review_mode_count": len(entered),
        "exited_review_mode_count": len(exited),
        "entered_contains_hint": CUSTOM_REVIEW_INSTRUCTIONS in serialized_entered,
        "exited_contains_output": REVIEW_OVERALL_EXPLANATION in serialized_exited,
        "review_response_message_count": sum(
            1 for response_type in response_types if response_type == "message"
        ),
    }


def summarize_original_review_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    rollout_paths = sorted(codex_home.rglob("*.jsonl"))
    all_items: list[dict[str, Any]] = []
    rollouts = []
    for path in rollout_paths:
        items = read_json_lines(path)
        all_items.extend(items)
        rollouts.append(
            {
                "path": path.relative_to(codex_home).as_posix(),
                "line_count": len(items),
            }
        )
    summary = summarize_review_sources(all_items)
    summary.update(
        {
            "codex_home": str(codex_home),
            "rollouts": rollouts,
        }
    )
    return summary


def summarize_chat_review_storage(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_review_sources([]),
            "timeline": {
                "line_count": 0,
                "event_types": [],
                "source_response_types": [],
                "review_status_event_count": 0,
            },
            "packages": [],
        }
    journal_lines: list[dict[str, Any]] = []
    timeline_lines: list[dict[str, Any]] = []
    package_summaries = []
    for package in packages:
        package_journal = read_json_lines(package / "journal.ndjson")
        package_timeline = read_json_lines(package / "timeline.ndjson")
        journal_lines.extend(package_journal)
        timeline_lines.extend(package_timeline)
        package_summaries.append(
            {
                "package": str(package),
                "journal_line_count": len(package_journal),
                "timeline_line_count": len(package_timeline),
                "timeline_event_types": [line.get("type") for line in package_timeline],
            }
        )
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_source_types = [
        (line.get("body") or {}).get("source_response_type")
        for line in timeline_lines
    ]
    review_status_event_count = sum(
        1
        for line in timeline_lines
        if line.get("type") == "status_changed"
        and (line.get("body") or {}).get("source_response_type")
        in {"entered_review_mode", "exited_review_mode"}
    )
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "packages": package_summaries,
        "journal": summarize_review_sources(source_items),
        "timeline": {
            "line_count": len(timeline_lines),
            "event_types": [line.get("type") for line in timeline_lines],
            "source_response_types": timeline_source_types,
            "review_status_event_count": review_status_event_count,
        },
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

    with ReviewResponsesServer() as mock_server:
        write_review_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)
            review_start = send_review_start(client, 3, thread_id)
            thread_read_response = send_thread_read(client, 4, thread_id)
            thread_list_response = send_thread_list(client, 5)
            storage = (
                summarize_chat_review_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_review_storage(codex_home)
            )
            package_summary = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else None
            )
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "review_start": review_start,
        "thread_read_response": thread_read_response,
        "thread_list_response": thread_list_response,
        "mock_server_summary": mock_server.summary(),
        "storage": storage,
        "package_summary": package_summary,
        "stderr": stderr,
    }


def assert_success(summary: dict[str, Any]) -> None:
    required_booleans = [
        "original_review_start_exit_ok",
        "chat_backend_review_start_exit_ok",
        "normalized_review_start_equal",
        "normalized_thread_read_equal",
        "normalized_thread_list_equal",
        "mock_response_request_counts_equal",
        "line_counts_equal",
        "review_mode_counts_equal",
        "original_has_entered_and_exited_review",
        "chat_journal_has_entered_and_exited_review",
        "chat_timeline_has_review_status_mapping",
    ]
    failed = [key for key in required_booleans if not summary.get(key)]
    if failed:
        raise AssertionError(f"review-mode smoke failed: {failed}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=(
            validation_results_root()
            / f"app-server-review-mode-smoke-{dt.datetime.now().strftime('%Y-%m-%d-%H%M%S')}"
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir: pathlib.Path = args.output_dir.resolve()
    if output_dir.exists():
        raise SystemExit(f"output dir already exists: {output_dir}")
    run_root = output_dir / "run"
    run_root.mkdir(parents=True, exist_ok=True)

    binary_checks = {
        "original": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat_backend": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

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
            f"experimental_thread_store={{ type = \"chat\", root = \"{run_root / 'chat-backend' / 'chat-store'}\" }}"
        ],
    )

    original_norm_review = normalize_review_start_result(original_result["review_start"])
    chat_norm_review = normalize_review_start_result(chat_result["review_start"])
    original_norm_read = normalize_thread_read_for_review(
        original_result["thread_read_response"]
    )
    chat_norm_read = normalize_thread_read_for_review(chat_result["thread_read_response"])
    started_thread_id = (
        ((original_result["thread_start_response"].get("result") or {}).get("thread") or {}).get("id")
    )
    chat_started_thread_id = (
        ((chat_result["thread_start_response"].get("result") or {}).get("thread") or {}).get("id")
    )
    original_norm_list = normalize_thread_list_response(
        original_result["thread_list_response"],
        started_thread_id,
    )
    chat_norm_list = normalize_thread_list_response(
        chat_result["thread_list_response"],
        chat_started_thread_id,
    )

    original_storage = original_result["storage"]
    chat_storage = chat_result["storage"]
    original_line_count = original_storage["line_count"]
    chat_line_count = chat_storage["journal"]["line_count"]
    original_review_counts = {
        "entered": original_storage["entered_review_mode_count"],
        "exited": original_storage["exited_review_mode_count"],
    }
    chat_review_counts = {
        "entered": chat_storage["journal"]["entered_review_mode_count"],
        "exited": chat_storage["journal"]["exited_review_mode_count"],
    }

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    summary = {
        "scope": "app-server-review-mode-smoke",
        "generated_at": utc_now_iso(),
        "binary_checks": binary_checks,
        "original_normalized_review_start": original_norm_review,
        "chat_backend_normalized_review_start": chat_norm_review,
        "original_normalized_thread_read": original_norm_read,
        "chat_backend_normalized_thread_read": chat_norm_read,
        "original_review_storage": original_storage,
        "chat_review_storage": chat_storage,
        "chat_package_summary": chat_result["package_summary"],
        "original_review_start_exit_ok": not original_norm_review["has_error"]
        and not original_norm_review["notification_errors"],
        "chat_backend_review_start_exit_ok": not chat_norm_review["has_error"]
        and not chat_norm_review["notification_errors"],
        "normalized_review_start_equal": original_norm_review == chat_norm_review,
        "normalized_thread_read_equal": original_norm_read == chat_norm_read,
        "normalized_thread_list_equal": original_norm_list == chat_norm_list,
        "mock_response_request_counts_equal": original_mock.get("response_request_count")
        == chat_mock.get("response_request_count"),
        "line_counts_equal": original_line_count == chat_line_count,
        "review_mode_counts_equal": original_review_counts == chat_review_counts,
        "original_has_entered_and_exited_review": original_review_counts
        == {"entered": 1, "exited": 1}
        and original_storage["entered_contains_hint"]
        and original_storage["exited_contains_output"],
        "chat_journal_has_entered_and_exited_review": chat_review_counts
        == {"entered": 1, "exited": 1}
        and chat_storage["journal"]["entered_contains_hint"]
        and chat_storage["journal"]["exited_contains_output"],
        "chat_timeline_has_review_status_mapping": chat_storage["timeline"][
            "review_status_event_count"
        ]
        == 2,
        "not_yet_proven": [
            "detached review threads",
            "interrupted review exit path",
            "semantic promotion beyond neutral status_changed",
            "review-mode behavior through interactive TUI",
            "final user-indistinguishability",
        ],
    }

    assert_success(summary)

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/review-mode-response.json", original_result)
    write_json(output_dir / "chat-backend/review-mode-response.json", chat_result)

    report = f"""# App-Server Review Mode Smoke - {summary['generated_at']}

This source-backed validation covered the source-backed persisted
`EventMsg::EnteredReviewMode` and `EventMsg::ExitedReviewMode` path through the
real `codex app-server` JSON-RPC interface.

## Result

- original review/start path passed: `{summary['original_review_start_exit_ok']}`
- `.chat` backend review/start path passed: `{summary['chat_backend_review_start_exit_ok']}`
- normalized review/start notifications matched: `{summary['normalized_review_start_equal']}`
- normalized thread/read matched: `{summary['normalized_thread_read_equal']}`
- normalized thread/list matched: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts matched: `{summary['mock_response_request_counts_equal']}`
- original rollout and `.chat` journal line counts matched: `{summary['line_counts_equal']}`
- review-mode event counts matched: `{summary['review_mode_counts_equal']}`
- `.chat` timeline contains neutral review status mappings: `{summary['chat_timeline_has_review_status_mapping']}`

## Evidence

- original rollout review storage: `{original_storage}`
- `.chat` review storage: `{chat_storage}`

## Boundaries

This is a focused review-mode persistence smoke. It does not prove detached
review threads, interrupted review exit, semantic promotion beyond neutral
`status_changed`, interactive TUI behavior, or final user-indistinguishability.

## Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/review-mode-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/review-mode-response.json
```
"""
    (output_dir / "report.md").write_text(report)


if __name__ == "__main__":
    main()
