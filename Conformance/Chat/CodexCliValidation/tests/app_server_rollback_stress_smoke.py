#!/usr/bin/env python3
"""Run rollback stress parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It covers two rollback slices:

- RB02: rollback more turns than exist and verify the visible history clears.
- RB03: apply rollback twice, then verify cumulative markers and future context.
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
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_rollback_smoke import (  # noqa: E402
    count_rollback_markers,
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_rollback,
    send_thread_start,
    send_turn_start,
    storage_line_counts,
    timeline_event_count,
)


RB02_USER_TEXTS = [
    "Rollback many turns seed one.",
    "Rollback many turns seed two.",
    "Rollback many turns seed three.",
]
RB02_ASSISTANT_TEXTS = [
    "Rollback many answer one.",
    "Rollback many answer two.",
    "Rollback many answer three.",
]
RB02_FOLLOWUP_USER_TEXT = "Rollback many follow-up after clearing history."
RB02_FOLLOWUP_ASSISTANT_TEXT = "Rollback many follow-up answer."

RB03_USER_TEXTS = [
    "Cumulative rollback seed one.",
    "Cumulative rollback seed two.",
    "Cumulative rollback seed three.",
]
RB03_ASSISTANT_TEXTS = [
    "Cumulative rollback answer one.",
    "Cumulative rollback answer two.",
    "Cumulative rollback answer three.",
]
RB03_FOLLOWUP_USER_TEXT = "Cumulative rollback follow-up after two markers."
RB03_FOLLOWUP_ASSISTANT_TEXT = "Cumulative rollback follow-up answer."


class RollbackStressMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(RB02_ASSISTANT_TEXTS[0])
        self._answers = [
            *RB02_ASSISTANT_TEXTS,
            RB02_FOLLOWUP_ASSISTANT_TEXT,
            *RB03_ASSISTANT_TEXTS,
            RB03_FOLLOWUP_ASSISTANT_TEXT,
        ]

    def next_sse_body(self) -> bytes:
        from app_server_durable_turn_smoke import sse_response

        with self._lock:
            self._counter += 1
            counter = self._counter
        answer_text = self._answers[min(counter - 1, len(self._answers) - 1)]
        return sse_response(
            f"resp-rollback-stress-{counter}",
            f"msg-rollback-stress-{counter}",
            answer_text,
        )


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


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
    rb02_followup = body_for_user_text(bodies, RB02_FOLLOWUP_USER_TEXT)
    rb03_followup = body_for_user_text(bodies, RB03_FOLLOWUP_USER_TEXT)
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "rb02_followup_contains_followup_user_text": response_input_contains(
            rb02_followup,
            RB02_FOLLOWUP_USER_TEXT,
        ),
        "rb02_followup_contains_any_cleared_user_text": any(
            response_input_contains(rb02_followup, text) for text in RB02_USER_TEXTS
        ),
        "rb02_followup_contains_any_cleared_assistant_text": any(
            response_input_contains(rb02_followup, text) for text in RB02_ASSISTANT_TEXTS
        ),
        "rb03_followup_contains_surviving_user_text": response_input_contains(
            rb03_followup,
            RB03_USER_TEXTS[0],
        ),
        "rb03_followup_contains_surviving_assistant_text": response_input_contains(
            rb03_followup,
            RB03_ASSISTANT_TEXTS[0],
        ),
        "rb03_followup_contains_removed_second_user_text": response_input_contains(
            rb03_followup,
            RB03_USER_TEXTS[1],
        ),
        "rb03_followup_contains_removed_third_user_text": response_input_contains(
            rb03_followup,
            RB03_USER_TEXTS[2],
        ),
        "rb03_followup_contains_removed_second_assistant_text": response_input_contains(
            rb03_followup,
            RB03_ASSISTANT_TEXTS[1],
        ),
        "rb03_followup_contains_removed_third_assistant_text": response_input_contains(
            rb03_followup,
            RB03_ASSISTANT_TEXTS[2],
        ),
        "rb03_followup_contains_followup_user_text": response_input_contains(
            rb03_followup,
            RB03_FOLLOWUP_USER_TEXT,
        ),
    }


def normalize_thread_response(
    response: dict[str, Any],
    user_texts: list[str],
    assistant_texts: list[str],
    followup_user_text: str,
    followup_assistant_text: str,
) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
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
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_user_texts": [
            text in serialized_turns for text in user_texts
        ],
        "contains_assistant_texts": [
            text in serialized_turns for text in assistant_texts
        ],
        "contains_followup_user_text": followup_user_text in serialized_turns,
        "contains_followup_assistant_text": followup_assistant_text
        in serialized_turns,
    }


def normalize_rollback_result(
    rollback_result: dict[str, Any],
    user_texts: list[str],
    assistant_texts: list[str],
    followup_user_text: str,
    followup_assistant_text: str,
) -> dict[str, Any]:
    normalized = normalize_thread_response(
        rollback_result["response"],
        user_texts,
        assistant_texts,
        followup_user_text,
        followup_assistant_text,
    )
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
    thread_ids: list[str | None],
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    ids = {thread.get("id") for thread in threads}
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_threads": [
            thread_id in ids if thread_id is not None else False
            for thread_id in thread_ids
        ],
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def tree_storage_summary(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
) -> dict[str, Any]:
    if tree_name == "chat-backend":
        return summarize_chat_packages(chat_root)
    return summarize_original_storage(codex_home)


def storage_text_presence(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    texts: list[str],
) -> dict[str, bool]:
    if tree_name == "chat-backend":
        files = [
            path
            for path in chat_root.rglob("*")
            if path.is_file() and path.suffix in {".json", ".ndjson"}
        ]
    else:
        files = [path for path in codex_home.rglob("*.jsonl") if path.is_file()]

    haystack = "\n".join(path.read_text(errors="replace") for path in files)
    return {text: text in haystack for text in texts}


def normalize_many(
    response: dict[str, Any],
) -> dict[str, Any]:
    return normalize_thread_response(
        response,
        RB02_USER_TEXTS,
        RB02_ASSISTANT_TEXTS,
        RB02_FOLLOWUP_USER_TEXT,
        RB02_FOLLOWUP_ASSISTANT_TEXT,
    )


def normalize_many_rollback(rollback_result: dict[str, Any]) -> dict[str, Any]:
    return normalize_rollback_result(
        rollback_result,
        RB02_USER_TEXTS,
        RB02_ASSISTANT_TEXTS,
        RB02_FOLLOWUP_USER_TEXT,
        RB02_FOLLOWUP_ASSISTANT_TEXT,
    )


def normalize_cumulative(
    response: dict[str, Any],
) -> dict[str, Any]:
    return normalize_thread_response(
        response,
        RB03_USER_TEXTS,
        RB03_ASSISTANT_TEXTS,
        RB03_FOLLOWUP_USER_TEXT,
        RB03_FOLLOWUP_ASSISTANT_TEXT,
    )


def normalize_cumulative_rollback(rollback_result: dict[str, Any]) -> dict[str, Any]:
    return normalize_rollback_result(
        rollback_result,
        RB03_USER_TEXTS,
        RB03_ASSISTANT_TEXTS,
        RB03_FOLLOWUP_USER_TEXT,
        RB03_FOLLOWUP_ASSISTANT_TEXT,
    )


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

    with RollbackStressMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)

            many_thread_id, many_thread_start_response = send_thread_start(
                client,
                2,
                workspace,
            )
            many_turns = [
                send_turn_start(
                    client,
                    3 + index,
                    many_thread_id,
                    f"client-user-message-rollback-many-{index + 1}",
                    user_text,
                )
                for index, user_text in enumerate(RB02_USER_TEXTS)
            ]
            many_read_before = send_thread_read(client, 10, many_thread_id)
            many_rollback = send_thread_rollback(client, 11, many_thread_id, 99)
            many_read_after = send_thread_read(client, 12, many_thread_id)
            many_resume_after = send_thread_resume(client, 13, many_thread_id)
            many_followup_turn = send_turn_start(
                client,
                14,
                many_thread_id,
                "client-user-message-rollback-many-followup",
                RB02_FOLLOWUP_USER_TEXT,
            )
            many_final_read = send_thread_read(client, 15, many_thread_id)

            cumulative_thread_id, cumulative_thread_start_response = send_thread_start(
                client,
                20,
                workspace,
            )
            cumulative_turns = [
                send_turn_start(
                    client,
                    21 + index,
                    cumulative_thread_id,
                    f"client-user-message-cumulative-rollback-{index + 1}",
                    user_text,
                )
                for index, user_text in enumerate(RB03_USER_TEXTS)
            ]
            cumulative_read_before = send_thread_read(
                client,
                30,
                cumulative_thread_id,
            )
            cumulative_first_rollback = send_thread_rollback(
                client,
                31,
                cumulative_thread_id,
                1,
            )
            cumulative_read_after_first = send_thread_read(
                client,
                32,
                cumulative_thread_id,
            )
            cumulative_second_rollback = send_thread_rollback(
                client,
                33,
                cumulative_thread_id,
                1,
            )
            cumulative_read_after_second = send_thread_read(
                client,
                34,
                cumulative_thread_id,
            )
            cumulative_resume_after_second = send_thread_resume(
                client,
                35,
                cumulative_thread_id,
            )
            cumulative_followup_turn = send_turn_start(
                client,
                36,
                cumulative_thread_id,
                "client-user-message-cumulative-rollback-followup",
                RB03_FOLLOWUP_USER_TEXT,
            )
            cumulative_final_read = send_thread_read(client, 37, cumulative_thread_id)

            final_list = send_thread_list(client, 40)
            final_storage = tree_storage_summary(tree_name, codex_home, chat_root)
            final_line_counts = storage_line_counts(final_storage, tree_name)
            rollback_marker_count = count_rollback_markers(
                tree_name,
                codex_home,
                chat_root,
            )
            storage_presence = storage_text_presence(
                tree_name,
                codex_home,
                chat_root,
                [
                    *RB02_USER_TEXTS,
                    *RB02_ASSISTANT_TEXTS,
                    *RB03_USER_TEXTS,
                    *RB03_ASSISTANT_TEXTS,
                ],
            )
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "initialize_response": initialize_response,
        "many_thread_start_response": many_thread_start_response,
        "many_turns": many_turns,
        "many_read_before": many_read_before,
        "many_rollback": many_rollback,
        "many_read_after": many_read_after,
        "many_resume_after": many_resume_after,
        "many_followup_turn": many_followup_turn,
        "many_final_read": many_final_read,
        "cumulative_thread_start_response": cumulative_thread_start_response,
        "cumulative_turns": cumulative_turns,
        "cumulative_read_before": cumulative_read_before,
        "cumulative_first_rollback": cumulative_first_rollback,
        "cumulative_read_after_first": cumulative_read_after_first,
        "cumulative_second_rollback": cumulative_second_rollback,
        "cumulative_read_after_second": cumulative_read_after_second,
        "cumulative_resume_after_second": cumulative_resume_after_second,
        "cumulative_followup_turn": cumulative_followup_turn,
        "cumulative_final_read": cumulative_final_read,
        "final_list": final_list,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "final_storage": final_storage,
        "final_storage_line_counts": final_line_counts,
        "rollback_marker_count": rollback_marker_count,
        "storage_text_presence": storage_presence,
        "normalized_many_before": normalize_many(many_read_before),
        "normalized_many_rollback": normalize_many_rollback(many_rollback),
        "normalized_many_read_after": normalize_many(many_read_after),
        "normalized_many_resume_after": normalize_many(many_resume_after),
        "normalized_many_final": normalize_many(many_final_read),
        "normalized_cumulative_before": normalize_cumulative(cumulative_read_before),
        "normalized_cumulative_first_rollback": normalize_cumulative_rollback(
            cumulative_first_rollback
        ),
        "normalized_cumulative_after_first": normalize_cumulative(
            cumulative_read_after_first
        ),
        "normalized_cumulative_second_rollback": normalize_cumulative_rollback(
            cumulative_second_rollback
        ),
        "normalized_cumulative_after_second": normalize_cumulative(
            cumulative_read_after_second
        ),
        "normalized_cumulative_resume_after_second": normalize_cumulative(
            cumulative_resume_after_second
        ),
        "normalized_cumulative_final": normalize_cumulative(cumulative_final_read),
        "normalized_final_list": normalize_thread_list_response(
            final_list,
            [many_thread_id, cumulative_thread_id],
        ),
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
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
            "app-server-rollback-stress-smoke-"
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
        "normalized_many_before",
        "normalized_many_rollback",
        "normalized_many_read_after",
        "normalized_many_resume_after",
        "normalized_many_final",
        "normalized_cumulative_before",
        "normalized_cumulative_first_rollback",
        "normalized_cumulative_after_first",
        "normalized_cumulative_second_rollback",
        "normalized_cumulative_after_second",
        "normalized_cumulative_resume_after_second",
        "normalized_cumulative_final",
        "normalized_final_list",
    ]
    comparisons = compare_keys(original_result, chat_result, normalized_keys)
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]

    original_many_rollback = original_result["normalized_many_rollback"]
    chat_many_rollback = chat_result["normalized_many_rollback"]
    original_many_after = original_result["normalized_many_read_after"]
    chat_many_after = chat_result["normalized_many_read_after"]
    original_many_final = original_result["normalized_many_final"]
    chat_many_final = chat_result["normalized_many_final"]
    original_cumulative_first = original_result["normalized_cumulative_after_first"]
    chat_cumulative_first = chat_result["normalized_cumulative_after_first"]
    original_cumulative_second = original_result["normalized_cumulative_after_second"]
    chat_cumulative_second = chat_result["normalized_cumulative_after_second"]
    original_cumulative_final = original_result["normalized_cumulative_final"]
    chat_cumulative_final = chat_result["normalized_cumulative_final"]

    rb02_cleared_history = all(
        [
            original_many_rollback["turn_count"] == 0,
            chat_many_rollback["turn_count"] == 0,
            original_many_after["turn_count"] == 0,
            chat_many_after["turn_count"] == 0,
            not any(original_many_after["contains_user_texts"]),
            not any(chat_many_after["contains_user_texts"]),
            not any(original_many_after["contains_assistant_texts"]),
            not any(chat_many_after["contains_assistant_texts"]),
        ]
    )
    rb02_followup_context_ok = all(
        [
            original_mock["rb02_followup_contains_followup_user_text"],
            chat_mock["rb02_followup_contains_followup_user_text"],
            not original_mock["rb02_followup_contains_any_cleared_user_text"],
            not chat_mock["rb02_followup_contains_any_cleared_user_text"],
            not original_mock["rb02_followup_contains_any_cleared_assistant_text"],
            not chat_mock["rb02_followup_contains_any_cleared_assistant_text"],
        ]
    )
    rb02_final_history_ok = all(
        [
            original_many_final["turn_count"] == 1,
            chat_many_final["turn_count"] == 1,
            not any(original_many_final["contains_user_texts"]),
            not any(chat_many_final["contains_user_texts"]),
            original_many_final["contains_followup_user_text"],
            chat_many_final["contains_followup_user_text"],
            original_many_final["contains_followup_assistant_text"],
            chat_many_final["contains_followup_assistant_text"],
        ]
    )
    rb03_cumulative_visible_history_ok = all(
        [
            original_cumulative_first["turn_count"] == 2,
            chat_cumulative_first["turn_count"] == 2,
            original_cumulative_second["turn_count"] == 1,
            chat_cumulative_second["turn_count"] == 1,
            original_cumulative_second["contains_user_texts"] == [True, False, False],
            chat_cumulative_second["contains_user_texts"] == [True, False, False],
            original_cumulative_second["contains_assistant_texts"]
            == [True, False, False],
            chat_cumulative_second["contains_assistant_texts"] == [True, False, False],
        ]
    )
    rb03_followup_context_ok = all(
        [
            original_mock["rb03_followup_contains_surviving_user_text"],
            chat_mock["rb03_followup_contains_surviving_user_text"],
            original_mock["rb03_followup_contains_surviving_assistant_text"],
            chat_mock["rb03_followup_contains_surviving_assistant_text"],
            original_mock["rb03_followup_contains_followup_user_text"],
            chat_mock["rb03_followup_contains_followup_user_text"],
            not original_mock["rb03_followup_contains_removed_second_user_text"],
            not chat_mock["rb03_followup_contains_removed_second_user_text"],
            not original_mock["rb03_followup_contains_removed_third_user_text"],
            not chat_mock["rb03_followup_contains_removed_third_user_text"],
            not original_mock["rb03_followup_contains_removed_second_assistant_text"],
            not chat_mock["rb03_followup_contains_removed_second_assistant_text"],
            not original_mock["rb03_followup_contains_removed_third_assistant_text"],
            not chat_mock["rb03_followup_contains_removed_third_assistant_text"],
        ]
    )
    rb03_final_history_ok = all(
        [
            original_cumulative_final["turn_count"] == 2,
            chat_cumulative_final["turn_count"] == 2,
            original_cumulative_final["contains_user_texts"] == [True, False, False],
            chat_cumulative_final["contains_user_texts"] == [True, False, False],
            original_cumulative_final["contains_followup_user_text"],
            chat_cumulative_final["contains_followup_user_text"],
            original_cumulative_final["contains_followup_assistant_text"],
            chat_cumulative_final["contains_followup_assistant_text"],
        ]
    )
    rollback_marker_counts_ok = all(
        [
            original_result["rollback_marker_count"] == 3,
            chat_result["rollback_marker_count"] == 3,
            original_result["rollback_marker_count"]
            == chat_result["rollback_marker_count"],
        ]
    )
    chat_timeline_rollback_event_count = timeline_event_count(
        chat_result["final_storage"],
        "timeline_rollback",
    )
    chat_timeline_rollback_event_count_matches_marker_count = (
        chat_timeline_rollback_event_count == chat_result["rollback_marker_count"]
    )
    source_history_preserved_ok = all(
        [
            all(original_result["storage_text_presence"].values()),
            all(chat_result["storage_text_presence"].values()),
        ]
    )
    storage_line_counts_match = (
        original_result["final_storage_line_counts"]
        == chat_result["final_storage_line_counts"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-rollback-stress-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_rollback_stress_fields_equal": all(comparisons.values()),
        "rb02_rollback_many_turns_cleared_visible_history": rb02_cleared_history,
        "rb02_followup_context_excludes_cleared_history": rb02_followup_context_ok,
        "rb02_final_history_after_followup_ok": rb02_final_history_ok,
        "rb03_cumulative_visible_history_ok": rb03_cumulative_visible_history_ok,
        "rb03_followup_context_uses_surviving_history_only": rb03_followup_context_ok,
        "rb03_final_history_after_followup_ok": rb03_final_history_ok,
        "rollback_marker_counts_ok": rollback_marker_counts_ok,
        "original_rollback_marker_count": original_result["rollback_marker_count"],
        "chat_backend_rollback_marker_count": chat_result["rollback_marker_count"],
        "chat_backend_timeline_rollback_event_count": (
            chat_timeline_rollback_event_count
        ),
        "chat_backend_timeline_rollback_event_count_matches_marker_count": (
            chat_timeline_rollback_event_count_matches_marker_count
        ),
        "source_history_preserved_despite_visible_rollback": source_history_preserved_ok,
        "storage_line_counts_match": storage_line_counts_match,
        "original_storage_line_counts": original_result["final_storage_line_counts"],
        "chat_backend_storage_line_counts": chat_result["final_storage_line_counts"],
        "mock_response_request_counts_equal": original_mock["response_request_count"]
        == chat_mock["response_request_count"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original": {key: original_result[key] for key in normalized_keys},
        "chat_backend": {key: chat_result[key] for key in normalized_keys},
        "original_storage": original_result["final_storage"],
        "chat_package": chat_result["final_storage"],
        "original_storage_text_presence": original_result["storage_text_presence"],
        "chat_backend_storage_text_presence": chat_result["storage_text_presence"],
        "not_yet_proven": [
            "rollback after compaction",
            "command/tool execution parity",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/rollback-stress-response.json", original_result)
    write_json(output_dir / "chat-backend/rollback-stress-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Rollback Stress Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server `thread/rollback` source, protocol definitions, and core
rollback replay code were also read.

## Scope

This smoke covers:

```text
RB02: turn/start x3, thread/rollback numTurns=99, read/resume, follow-up turn
RB03: turn/start x3, rollback 1, rollback 1, read/resume, follow-up turn
```

It proves the current rollback-many-turns and cumulative-marker slices only. It
does not prove rollback after compaction, command/tool execution parity, crash
recovery, cold history, complete data fidelity, or final
user-indistinguishability.

## Result

- all normalized rollback stress fields equal: `{summary['all_normalized_rollback_stress_fields_equal']}`
- RB02 visible history cleared: `{summary['rb02_rollback_many_turns_cleared_visible_history']}`
- RB02 follow-up context excludes cleared history: `{summary['rb02_followup_context_excludes_cleared_history']}`
- RB02 final history after follow-up ok: `{summary['rb02_final_history_after_followup_ok']}`
- RB03 cumulative visible history ok: `{summary['rb03_cumulative_visible_history_ok']}`
- RB03 follow-up context uses surviving history only: `{summary['rb03_followup_context_uses_surviving_history_only']}`
- RB03 final history after follow-up ok: `{summary['rb03_final_history_after_followup_ok']}`
- rollback marker counts ok: `{summary['rollback_marker_counts_ok']}`
- `.chat` timeline rollback event count: `{summary['chat_backend_timeline_rollback_event_count']}`
- `.chat` timeline rollback count matches marker count: `{summary['chat_backend_timeline_rollback_event_count_matches_marker_count']}`
- source history preserved despite visible rollback: `{summary['source_history_preserved_despite_visible_rollback']}`
- storage line counts match: `{summary['storage_line_counts_match']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`

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

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat_backend': chat_mock}, indent=2, sort_keys=True)}
```

## Storage Observations

```json
{json.dumps({'original': summary['original_storage'], 'chat_backend': summary['chat_package']}, indent=2, sort_keys=True)}
```

## Storage Text Presence

```json
{json.dumps({'original': summary['original_storage_text_presence'], 'chat_backend': summary['chat_backend_storage_text_presence']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/rollback-stress-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/rollback-stress-response.json
```

## Not Yet Proven

This smoke does not prove rollback after compaction, command/tool execution
parity, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_rollback_stress_fields_equal"],
            summary["rb02_rollback_many_turns_cleared_visible_history"],
            summary["rb02_followup_context_excludes_cleared_history"],
            summary["rb02_final_history_after_followup_ok"],
            summary["rb03_cumulative_visible_history_ok"],
            summary["rb03_followup_context_uses_surviving_history_only"],
            summary["rb03_final_history_after_followup_ok"],
            summary["rollback_marker_counts_ok"],
            summary["chat_backend_timeline_rollback_event_count_matches_marker_count"],
            summary["source_history_preserved_despite_visible_rollback"],
            summary["storage_line_counts_match"],
            summary["mock_response_request_counts_equal"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
