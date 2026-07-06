#!/usr/bin/env python3
"""Run app-server fork variant parity smoke for original vs `.chat` backend.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers additional fork subcases not
covered by `app_server_fork_smoke.py`: `lastTurnId` truncation, path-addressed
fork, and ephemeral pathless fork.
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

from app_server_durable_turn_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
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
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_thread_start,
    send_turn_start,
    snapshot_path_content,
    thread_from_response,
)


USER_TEXTS = [
    "Fork variants source first turn.",
    "Fork variants source second turn.",
    "Fork variants source third turn.",
]


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "request_inputs_contain_expected_texts": [
            response_input_contains(bodies[index] if len(bodies) > index else {}, text)
            for index, text in enumerate(USER_TEXTS)
        ],
        "extra_response_request_after_source_turns": len(bodies) > len(USER_TEXTS),
    }


def send_thread_fork(
    client: JsonRpcClient,
    request_id: int,
    source_thread_id: str | None,
    *,
    last_turn_id: str | None = None,
    path: str | None = None,
    ephemeral: bool = False,
    exclude_turns: bool = False,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "threadId": source_thread_id,
        "excludeTurns": exclude_turns,
        "ephemeral": ephemeral,
    }
    if last_turn_id is not None:
        params["lastTurnId"] = last_turn_id
    if path is not None:
        params["path"] = path
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/fork",
            "params": params,
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    started_notification = None
    notification_error = None
    if "error" not in response:
        try:
            started_notification = client.receive_until_method(
                "thread/started", timeout_seconds=30
            )
        except TimeoutError as exc:
            notification_error = str(exc)
    return {
        "response": response,
        "thread_started_notification": started_notification,
        "notification_error": notification_error,
    }


def turns_from_response(response: dict[str, Any]) -> list[dict[str, Any]]:
    return thread_from_response(response).get("turns") or []


def turn_ids_from_response(response: dict[str, Any]) -> list[str]:
    return [turn.get("id") for turn in turns_from_response(response)]


def normalize_thread_response(
    response: dict[str, Any],
    expected_thread_id: str | None,
    expected_turn_count: int,
) -> dict[str, Any]:
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_id_matches": expected_thread_id is not None
        and thread.get("id") == expected_thread_id,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "expected_turn_count": expected_turn_count,
        "turn_count_matches": len(turns) == expected_turn_count,
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_user_texts": [text in serialized_turns for text in USER_TEXTS],
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def normalize_fork_response(
    fork_result: dict[str, Any],
    *,
    source_thread_id: str | None,
    source_path: str | None,
    expected_turn_ids: list[str],
    expected_ephemeral: bool,
    expected_path_present: bool,
) -> dict[str, Any]:
    response = fork_result["response"]
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
    turn_ids = [turn.get("id") for turn in turns]
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    thread_path = thread.get("path")
    started_thread = (
        ((fork_result.get("thread_started_notification") or {}).get("params") or {}).get("thread")
        or {}
    )
    return {
        "has_error": "error" in response,
        "notification_error": fork_result.get("notification_error"),
        "thread_id_present": thread.get("id") is not None,
        "thread_id_differs_from_source": source_thread_id is not None
        and thread.get("id") != source_thread_id,
        "session_id_equals_thread_id": thread.get("sessionId") == thread.get("id"),
        "forked_from_matches_source": source_thread_id is not None
        and thread.get("forkedFromId") == source_thread_id,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_ephemeral_matches": thread.get("ephemeral") is expected_ephemeral,
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "name": thread.get("name"),
        "path_present": thread_path is not None,
        "path_presence_matches": (thread_path is not None) is expected_path_present,
        "path_differs_from_source": thread_path is not None and thread_path != source_path,
        "turn_count": len(turns),
        "turn_ids_match": turn_ids == expected_turn_ids,
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_user_texts": [text in serialized_turns for text in USER_TEXTS],
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
        "thread_started_seen": fork_result.get("thread_started_notification") is not None,
        "started_thread_id_matches": started_thread.get("id") == thread.get("id"),
        "started_thread_turn_count": len(started_thread.get("turns") or []),
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    *,
    expected_present_thread_ids: list[str | None],
    expected_absent_thread_ids: list[str | None],
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    ids = {thread.get("id") for thread in threads}
    present = [
        thread_id for thread_id in expected_present_thread_ids if thread_id is not None
    ]
    absent = [thread_id for thread_id in expected_absent_thread_ids if thread_id is not None]
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_all_expected_threads": all(thread_id in ids for thread_id in present),
        "omits_all_absent_threads": all(thread_id not in ids for thread_id in absent),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
        "expected_present_thread_count": len(present),
        "expected_absent_thread_count": len(absent),
    }


def line_counts(summary: dict[str, Any]) -> list[int]:
    if "rollouts" in summary:
        return sorted(
            item.get("line_count")
            for item in (summary.get("rollouts") or [])
            if item.get("line_count") is not None
        )
    return sorted(
        package.get("journal_line_count")
        for package in (summary.get("packages") or [])
        if package.get("journal_line_count") is not None
    )


def package_count(summary: dict[str, Any]) -> int:
    if "rollout_files" in summary:
        return len(summary.get("rollout_files") or [])
    return int(summary.get("package_count") or 0)


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

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            source_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )
            turns = [
                send_turn_start(
                    client,
                    request_id,
                    source_thread_id,
                    f"client-user-message-fork-variant-{index + 1}",
                    text,
                )
                for index, (request_id, text) in enumerate(
                    zip([3, 4, 5], USER_TEXTS, strict=True)
                )
            ]
            source_read_before_fork_response = send_thread_read(
                client, 6, source_thread_id
            )
            source_thread = thread_from_response(source_read_before_fork_response)
            source_path = source_thread.get("path")
            source_turn_ids = turn_ids_from_response(source_read_before_fork_response)
            source_snapshot_before_fork = snapshot_path_content(source_path)
            pre_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            last_turn_id = source_turn_ids[1] if len(source_turn_ids) > 1 else None
            last_turn_fork = send_thread_fork(
                client,
                7,
                source_thread_id,
                last_turn_id=last_turn_id,
            )
            last_turn_fork_thread = thread_from_response(last_turn_fork["response"])
            last_turn_fork_thread_id = last_turn_fork_thread.get("id")
            last_turn_fork_read_response = send_thread_read(
                client,
                8,
                last_turn_fork_thread_id,
            )
            source_snapshot_after_last_turn_fork = snapshot_path_content(source_path)
            post_last_turn_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            path_fork = send_thread_fork(
                client,
                9,
                "not-a-valid-thread-id",
                path=source_path,
            )
            path_fork_thread = thread_from_response(path_fork["response"])
            path_fork_thread_id = path_fork_thread.get("id")
            path_fork_read_response = send_thread_read(client, 10, path_fork_thread_id)
            source_snapshot_after_path_fork = snapshot_path_content(source_path)
            post_path_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            ephemeral_fork = send_thread_fork(
                client,
                11,
                source_thread_id,
                ephemeral=True,
            )
            ephemeral_fork_thread = thread_from_response(ephemeral_fork["response"])
            ephemeral_fork_thread_id = ephemeral_fork_thread.get("id")
            source_snapshot_after_ephemeral_fork = snapshot_path_content(source_path)
            final_list_response = send_thread_list(client, 12)
            post_ephemeral_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
        finally:
            stderr = client.close()

    expected_last_turn_ids = source_turn_ids[:2]
    expected_full_turn_ids = source_turn_ids
    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turns": turns,
        "source_read_before_fork_response": source_read_before_fork_response,
        "last_turn_fork": last_turn_fork,
        "last_turn_fork_read_response": last_turn_fork_read_response,
        "path_fork": path_fork,
        "path_fork_read_response": path_fork_read_response,
        "ephemeral_fork": ephemeral_fork,
        "final_list_response": final_list_response,
        "source_turn_ids": source_turn_ids,
        "normalized_source_before_fork": normalize_thread_response(
            source_read_before_fork_response,
            source_thread_id,
            expected_turn_count=3,
        ),
        "normalized_last_turn_fork": normalize_fork_response(
            last_turn_fork,
            source_thread_id=source_thread_id,
            source_path=source_path,
            expected_turn_ids=expected_last_turn_ids,
            expected_ephemeral=False,
            expected_path_present=True,
        ),
        "normalized_last_turn_fork_read": normalize_thread_response(
            last_turn_fork_read_response,
            last_turn_fork_thread_id,
            expected_turn_count=2,
        ),
        "normalized_path_fork": normalize_fork_response(
            path_fork,
            source_thread_id=source_thread_id,
            source_path=source_path,
            expected_turn_ids=expected_full_turn_ids,
            expected_ephemeral=False,
            expected_path_present=True,
        ),
        "normalized_path_fork_read": normalize_thread_response(
            path_fork_read_response,
            path_fork_thread_id,
            expected_turn_count=3,
        ),
        "normalized_ephemeral_fork": normalize_fork_response(
            ephemeral_fork,
            source_thread_id=source_thread_id,
            source_path=source_path,
            expected_turn_ids=expected_full_turn_ids,
            expected_ephemeral=True,
            expected_path_present=False,
        ),
        "normalized_final_list": normalize_thread_list_response(
            final_list_response,
            expected_present_thread_ids=[
                source_thread_id,
                last_turn_fork_thread_id,
                path_fork_thread_id,
            ],
            expected_absent_thread_ids=[ephemeral_fork_thread_id],
        ),
        "source_snapshot_before_fork": source_snapshot_before_fork,
        "source_snapshot_after_last_turn_fork": source_snapshot_after_last_turn_fork,
        "source_snapshot_after_path_fork": source_snapshot_after_path_fork,
        "source_snapshot_after_ephemeral_fork": source_snapshot_after_ephemeral_fork,
        "source_snapshot_unchanged_after_last_turn_fork": (
            source_snapshot_before_fork == source_snapshot_after_last_turn_fork
        ),
        "source_snapshot_unchanged_after_path_fork": (
            source_snapshot_before_fork == source_snapshot_after_path_fork
        ),
        "source_snapshot_unchanged_after_ephemeral_fork": (
            source_snapshot_before_fork == source_snapshot_after_ephemeral_fork
        ),
        "pre_fork_storage_summary": pre_fork_storage,
        "post_last_turn_fork_storage_summary": post_last_turn_storage,
        "post_path_fork_storage_summary": post_path_fork_storage,
        "post_ephemeral_fork_storage_summary": post_ephemeral_fork_storage,
        "pre_fork_line_counts": line_counts(pre_fork_storage),
        "post_last_turn_line_counts": line_counts(post_last_turn_storage),
        "post_path_line_counts": line_counts(post_path_fork_storage),
        "post_ephemeral_line_counts": line_counts(post_ephemeral_fork_storage),
        "pre_fork_package_count": package_count(pre_fork_storage),
        "post_last_turn_package_count": package_count(post_last_turn_storage),
        "post_path_package_count": package_count(post_path_fork_storage),
        "post_ephemeral_package_count": package_count(post_ephemeral_fork_storage),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-fork-variants-smoke-"
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

    comparison_keys = [
        "normalized_source_before_fork",
        "normalized_last_turn_fork",
        "normalized_last_turn_fork_read",
        "normalized_path_fork",
        "normalized_path_fork_read",
        "normalized_ephemeral_fork",
        "normalized_final_list",
        "source_snapshot_unchanged_after_last_turn_fork",
        "source_snapshot_unchanged_after_path_fork",
        "source_snapshot_unchanged_after_ephemeral_fork",
        "pre_fork_line_counts",
        "post_last_turn_line_counts",
        "post_path_line_counts",
        "post_ephemeral_line_counts",
        "pre_fork_package_count",
        "post_last_turn_package_count",
        "post_path_package_count",
        "post_ephemeral_package_count",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-fork-variants-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_fork_variant_fields_equal": all(comparisons.values()),
        "original_source_has_three_turns": original_result["normalized_source_before_fork"][
            "turn_count_matches"
        ],
        "chat_backend_source_has_three_turns": chat_result[
            "normalized_source_before_fork"
        ]["turn_count_matches"],
        "original_last_turn_fork_truncated_to_two_turns": original_result[
            "normalized_last_turn_fork"
        ]["turn_ids_match"],
        "chat_backend_last_turn_fork_truncated_to_two_turns": chat_result[
            "normalized_last_turn_fork"
        ]["turn_ids_match"],
        "original_path_fork_has_full_history": original_result["normalized_path_fork"][
            "turn_ids_match"
        ],
        "chat_backend_path_fork_has_full_history": chat_result["normalized_path_fork"][
            "turn_ids_match"
        ],
        "original_ephemeral_fork_pathless": original_result["normalized_ephemeral_fork"][
            "path_presence_matches"
        ],
        "chat_backend_ephemeral_fork_pathless": chat_result[
            "normalized_ephemeral_fork"
        ]["path_presence_matches"],
        "original_ephemeral_fork_not_listed": original_result["normalized_final_list"][
            "omits_all_absent_threads"
        ],
        "chat_backend_ephemeral_fork_not_listed": chat_result["normalized_final_list"][
            "omits_all_absent_threads"
        ],
        "original_source_unchanged_after_variants": original_result[
            "source_snapshot_unchanged_after_ephemeral_fork"
        ],
        "chat_backend_source_unchanged_after_variants": chat_result[
            "source_snapshot_unchanged_after_ephemeral_fork"
        ],
        "mock_response_request_counts_equal": original_result["mock_server_summary"][
            "response_request_count"
        ]
        == chat_result["mock_server_summary"]["response_request_count"],
        "mock_no_extra_model_request_for_forks": (
            original_result["mock_server_summary"]["response_request_count"]
            == len(USER_TEXTS)
            and chat_result["mock_server_summary"]["response_request_count"]
            == len(USER_TEXTS)
        ),
        "storage_counts_equal_after_each_variant": all(
            comparisons[key]
            for key in [
                "pre_fork_package_count",
                "post_last_turn_package_count",
                "post_path_package_count",
                "post_ephemeral_package_count",
            ]
        ),
        "storage_line_counts_equal_after_each_variant": all(
            comparisons[key]
            for key in [
                "pre_fork_line_counts",
                "post_last_turn_line_counts",
                "post_path_line_counts",
                "post_ephemeral_line_counts",
            ]
        ),
        "original": {key: original_result[key] for key in comparison_keys},
        "chat_backend": {key: chat_result[key] for key in comparison_keys},
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_storage": {
            "pre_fork": original_result["pre_fork_storage_summary"],
            "post_last_turn_fork": original_result[
                "post_last_turn_fork_storage_summary"
            ],
            "post_path_fork": original_result["post_path_fork_storage_summary"],
            "post_ephemeral_fork": original_result[
                "post_ephemeral_fork_storage_summary"
            ],
        },
        "chat_package": {
            "pre_fork": chat_result["pre_fork_storage_summary"],
            "post_last_turn_fork": chat_result[
                "post_last_turn_fork_storage_summary"
            ],
            "post_path_fork": chat_result["post_path_fork_storage_summary"],
            "post_ephemeral_fork": chat_result[
                "post_ephemeral_fork_storage_summary"
            ],
        },
        "not_yet_proven": [
            "forked title/name inheritance parity",
            "fork token usage replay ordering",
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

    write_json(output_dir / "original/fork-variants-response.json", original_result)
    write_json(output_dir / "chat-backend/fork-variants-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Fork Variants Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server `thread/fork` source, protocol definitions, upstream fork
variant tests, and the current `.chat` backend implementation were also read.

## Scope

This smoke covers:

```text
thread/start
turn/start x3
thread/read source includeTurns=true
thread/fork lastTurnId=<second turn>
thread/read lastTurnId fork
thread/fork path=<source path> with invalid threadId
thread/read path-addressed fork
thread/fork ephemeral=true
thread/list active
```

It proves only F02, F04, and path-addressed fork behavior for completed source
turns. It does not prove forked title/name inheritance, token usage replay
ordering, interrupted active-turn fork, rollback, compaction, command
execution, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability.

## Result

- all normalized fork variant fields equal: `{summary['all_normalized_fork_variant_fields_equal']}`
- original source has three completed turns: `{summary['original_source_has_three_turns']}`
- `.chat` source has three completed turns: `{summary['chat_backend_source_has_three_turns']}`
- original lastTurnId fork truncated to two turns: `{summary['original_last_turn_fork_truncated_to_two_turns']}`
- `.chat` lastTurnId fork truncated to two turns: `{summary['chat_backend_last_turn_fork_truncated_to_two_turns']}`
- original path-addressed fork has full history: `{summary['original_path_fork_has_full_history']}`
- `.chat` path-addressed fork has full history: `{summary['chat_backend_path_fork_has_full_history']}`
- original ephemeral fork is pathless: `{summary['original_ephemeral_fork_pathless']}`
- `.chat` ephemeral fork is pathless: `{summary['chat_backend_ephemeral_fork_pathless']}`
- original ephemeral fork omitted from thread/list: `{summary['original_ephemeral_fork_not_listed']}`
- `.chat` ephemeral fork omitted from thread/list: `{summary['chat_backend_ephemeral_fork_not_listed']}`
- original source content unchanged after variants: `{summary['original_source_unchanged_after_variants']}`
- `.chat` source package unchanged after variants: `{summary['chat_backend_source_unchanged_after_variants']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- no extra model request was made for forks: `{summary['mock_no_extra_model_request_for_forks']}`
- storage counts equal after each variant: `{summary['storage_counts_equal_after_each_variant']}`
- storage line counts equal after each variant: `{summary['storage_line_counts_equal_after_each_variant']}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/fork-variants-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/fork-variants-response.json
```

## Not Yet Proven

This smoke does not prove forked title/name inheritance, fork token usage replay
ordering, interrupted active-turn fork, rollback, compaction/context restore,
command execution, crash recovery, cold history, complete data fidelity, or
final user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_fork_variant_fields_equal"],
            summary["original_source_has_three_turns"],
            summary["chat_backend_source_has_three_turns"],
            summary["original_last_turn_fork_truncated_to_two_turns"],
            summary["chat_backend_last_turn_fork_truncated_to_two_turns"],
            summary["original_path_fork_has_full_history"],
            summary["chat_backend_path_fork_has_full_history"],
            summary["original_ephemeral_fork_pathless"],
            summary["chat_backend_ephemeral_fork_pathless"],
            summary["original_ephemeral_fork_not_listed"],
            summary["chat_backend_ephemeral_fork_not_listed"],
            summary["original_source_unchanged_after_variants"],
            summary["chat_backend_source_unchanged_after_variants"],
            summary["mock_response_request_counts_equal"],
            summary["mock_no_extra_model_request_for_forks"],
            summary["storage_counts_equal_after_each_variant"],
            summary["storage_line_counts_equal_after_each_variant"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
