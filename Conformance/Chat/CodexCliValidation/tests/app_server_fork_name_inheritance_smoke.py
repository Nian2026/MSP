#!/usr/bin/env python3
"""Run app-server fork name-inheritance parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers F05 after a completed durable
source thread whose name was set through the public `thread/name/set` API.
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
from app_server_fork_variants_smoke import (  # noqa: E402
    send_thread_fork,
)


USER_TEXT = "Fork name inheritance source turn."
SOURCE_NAME = "Named source for fork parity"


def conversation_line_counts(summary: dict[str, Any]) -> list[int]:
    if "rollouts" in summary:
        return sorted(
            item.get("line_count")
            for item in (summary.get("rollouts") or [])
            if item.get("line_count") is not None
            and item.get("path") != "session_index.jsonl"
        )
    return sorted(
        package.get("journal_line_count")
        for package in (summary.get("packages") or [])
        if package.get("journal_line_count") is not None
    )


def conversation_count(summary: dict[str, Any]) -> int:
    if "rollout_files" in summary:
        return len(
            [
                path
                for path in (summary.get("rollout_files") or [])
                if path != "session_index.jsonl"
            ]
        )
    return int(summary.get("package_count") or 0)


def legacy_name_index_line_count(summary: dict[str, Any]) -> int | None:
    for item in summary.get("rollouts") or []:
        if item.get("path") == "session_index.jsonl":
            return item.get("line_count")
    return None


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
        "first_response_contains_user_text": response_input_contains(
            bodies[0] if bodies else {}, USER_TEXT
        ),
        "extra_response_request_after_source_turn": len(bodies) > 1,
    }


def send_thread_set_name(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    name: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/name/set",
            "params": {
                "threadId": thread_id,
                "name": name,
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notification = None
    notification_error = None
    if "error" not in response:
        try:
            notification = client.receive_until_method(
                "thread/name/updated", timeout_seconds=30
            )
        except TimeoutError as exc:
            notification_error = str(exc)
    return {
        "response": response,
        "notification": notification,
        "notification_error": notification_error,
    }


def turns_from_response(response: dict[str, Any]) -> list[dict[str, Any]]:
    return thread_from_response(response).get("turns") or []


def normalize_thread_response(
    response: dict[str, Any],
    expected_thread_id: str | None,
    expected_name: str | None,
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
        "name": thread.get("name"),
        "name_matches_expected": thread.get("name") == expected_name,
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
        "contains_user_text": USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def normalize_set_name_result(
    result: dict[str, Any],
    expected_thread_id: str | None,
    expected_name: str,
) -> dict[str, Any]:
    notification = result.get("notification") or {}
    params = notification.get("params") or {}
    return {
        "has_error": "error" in result.get("response", {}),
        "notification_error": result.get("notification_error"),
        "notification_seen": result.get("notification") is not None,
        "notification_method": notification.get("method"),
        "notification_thread_id_matches": expected_thread_id is not None
        and params.get("threadId") == expected_thread_id,
        "notification_name_matches": params.get("threadName") == expected_name,
    }


def normalize_fork_response(
    fork_result: dict[str, Any],
    *,
    source_thread_id: str | None,
    source_path: str | None,
    expected_name: str,
    expected_turn_count: int,
) -> dict[str, Any]:
    response = fork_result["response"]
    thread = thread_from_response(response)
    turns = thread.get("turns") or []
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
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "name": thread.get("name"),
        "name_matches_expected": thread.get("name") == expected_name,
        "path_present": thread_path is not None,
        "path_differs_from_source": thread_path is not None and thread_path != source_path,
        "turn_count": len(turns),
        "expected_turn_count": expected_turn_count,
        "turn_count_matches": len(turns) == expected_turn_count,
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_user_text": USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
        "thread_started_seen": fork_result.get("thread_started_notification") is not None,
        "started_thread_id_matches": started_thread.get("id") == thread.get("id"),
        "started_thread_name": started_thread.get("name"),
        "started_thread_name_matches_expected": started_thread.get("name") == expected_name,
        "started_thread_turn_count": len(started_thread.get("turns") or []),
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    *,
    source_thread_id: str | None,
    fork_thread_id: str | None,
    expected_name: str,
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    by_id = {thread.get("id"): thread for thread in threads}
    source = by_id.get(source_thread_id)
    fork = by_id.get(fork_thread_id)
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "source_present": source is not None,
        "fork_present": fork is not None,
        "source_name": (source or {}).get("name"),
        "fork_name": (fork or {}).get("name"),
        "source_name_matches_expected": (source or {}).get("name") == expected_name,
        "fork_name_matches_expected": (fork or {}).get("name") == expected_name,
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

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            source_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )
            source_turn = send_turn_start(
                client,
                3,
                source_thread_id,
                "client-user-message-fork-name-1",
                USER_TEXT,
            )
            source_read_before_name_response = send_thread_read(
                client, 4, source_thread_id
            )
            source_thread_before_name = thread_from_response(
                source_read_before_name_response
            )
            source_path = source_thread_before_name.get("path")
            set_name_result = send_thread_set_name(
                client, 5, source_thread_id, SOURCE_NAME
            )
            source_read_after_name_response = send_thread_read(
                client, 6, source_thread_id
            )
            source_snapshot_before_fork = snapshot_path_content(source_path)
            pre_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            fork = send_thread_fork(client, 7, source_thread_id)
            fork_thread = thread_from_response(fork["response"])
            fork_thread_id = fork_thread.get("id")
            fork_read_response = send_thread_read(client, 8, fork_thread_id)
            final_list_response = send_thread_list(client, 9)
            source_snapshot_after_fork = snapshot_path_content(source_path)
            post_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
        finally:
            stderr = client.close()

    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "source_turn": source_turn,
        "source_read_before_name_response": source_read_before_name_response,
        "set_name_result": set_name_result,
        "source_read_after_name_response": source_read_after_name_response,
        "fork": fork,
        "fork_read_response": fork_read_response,
        "final_list_response": final_list_response,
        "normalized_source_before_name": normalize_thread_response(
            source_read_before_name_response,
            source_thread_id,
            expected_name=None,
            expected_turn_count=1,
        ),
        "normalized_set_name": normalize_set_name_result(
            set_name_result, source_thread_id, SOURCE_NAME
        ),
        "normalized_source_after_name": normalize_thread_response(
            source_read_after_name_response,
            source_thread_id,
            expected_name=SOURCE_NAME,
            expected_turn_count=1,
        ),
        "normalized_fork": normalize_fork_response(
            fork,
            source_thread_id=source_thread_id,
            source_path=source_path,
            expected_name=SOURCE_NAME,
            expected_turn_count=1,
        ),
        "normalized_fork_read": normalize_thread_response(
            fork_read_response,
            fork_thread_id,
            expected_name=SOURCE_NAME,
            expected_turn_count=1,
        ),
        "normalized_final_list": normalize_thread_list_response(
            final_list_response,
            source_thread_id=source_thread_id,
            fork_thread_id=fork_thread_id,
            expected_name=SOURCE_NAME,
        ),
        "source_snapshot_before_fork": source_snapshot_before_fork,
        "source_snapshot_after_fork": source_snapshot_after_fork,
        "source_snapshot_unchanged_after_fork": (
            source_snapshot_before_fork == source_snapshot_after_fork
        ),
        "pre_fork_storage_summary": pre_fork_storage,
        "post_fork_storage_summary": post_fork_storage,
        "pre_fork_conversation_line_counts": conversation_line_counts(
            pre_fork_storage
        ),
        "post_fork_conversation_line_counts": conversation_line_counts(
            post_fork_storage
        ),
        "pre_fork_conversation_count": conversation_count(pre_fork_storage),
        "post_fork_conversation_count": conversation_count(post_fork_storage),
        "pre_fork_legacy_name_index_line_count": legacy_name_index_line_count(
            pre_fork_storage
        ),
        "post_fork_legacy_name_index_line_count": legacy_name_index_line_count(
            post_fork_storage
        ),
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
            "app-server-fork-name-inheritance-smoke-"
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
        "normalized_source_before_name",
        "normalized_set_name",
        "normalized_source_after_name",
        "normalized_fork",
        "normalized_fork_read",
        "normalized_final_list",
        "source_snapshot_unchanged_after_fork",
        "pre_fork_conversation_line_counts",
        "post_fork_conversation_line_counts",
        "pre_fork_conversation_count",
        "post_fork_conversation_count",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-fork-name-inheritance-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_fork_name_fields_equal": all(comparisons.values()),
        "original_set_name_notification_matches": original_result["normalized_set_name"][
            "notification_name_matches"
        ],
        "chat_backend_set_name_notification_matches": chat_result["normalized_set_name"][
            "notification_name_matches"
        ],
        "original_source_name_visible_after_set": original_result[
            "normalized_source_after_name"
        ]["name_matches_expected"],
        "chat_backend_source_name_visible_after_set": chat_result[
            "normalized_source_after_name"
        ]["name_matches_expected"],
        "original_fork_inherited_name": original_result["normalized_fork"][
            "name_matches_expected"
        ],
        "chat_backend_fork_inherited_name": chat_result["normalized_fork"][
            "name_matches_expected"
        ],
        "original_fork_read_inherited_name": original_result["normalized_fork_read"][
            "name_matches_expected"
        ],
        "chat_backend_fork_read_inherited_name": chat_result["normalized_fork_read"][
            "name_matches_expected"
        ],
        "original_list_names_match": (
            original_result["normalized_final_list"]["source_name_matches_expected"]
            and original_result["normalized_final_list"]["fork_name_matches_expected"]
        ),
        "chat_backend_list_names_match": (
            chat_result["normalized_final_list"]["source_name_matches_expected"]
            and chat_result["normalized_final_list"]["fork_name_matches_expected"]
        ),
        "original_source_unchanged_after_named_fork": original_result[
            "source_snapshot_unchanged_after_fork"
        ],
        "chat_backend_source_unchanged_after_named_fork": chat_result[
            "source_snapshot_unchanged_after_fork"
        ],
        "mock_response_request_counts_equal": original_result["mock_server_summary"][
            "response_request_count"
        ]
        == chat_result["mock_server_summary"]["response_request_count"],
        "mock_no_extra_model_request_for_name_or_fork": (
            original_result["mock_server_summary"]["response_request_count"] == 1
            and chat_result["mock_server_summary"]["response_request_count"] == 1
        ),
        "conversation_storage_counts_equal_after_named_fork": comparisons[
            "post_fork_conversation_count"
        ],
        "conversation_storage_line_counts_equal_after_named_fork": comparisons[
            "post_fork_conversation_line_counts"
        ],
        "original_legacy_name_index_line_count_before_fork": original_result[
            "pre_fork_legacy_name_index_line_count"
        ],
        "original_legacy_name_index_line_count_after_fork": original_result[
            "post_fork_legacy_name_index_line_count"
        ],
        "original": {key: original_result[key] for key in comparison_keys},
        "chat_backend": {key: chat_result[key] for key in comparison_keys},
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "original_storage": {
            "pre_fork": original_result["pre_fork_storage_summary"],
            "post_fork": original_result["post_fork_storage_summary"],
        },
        "chat_package": {
            "pre_fork": chat_result["pre_fork_storage_summary"],
            "post_fork": chat_result["post_fork_storage_summary"],
        },
        "not_yet_proven": [
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

    write_json(output_dir / "original/fork-name-inheritance-response.json", original_result)
    write_json(output_dir / "chat-backend/fork-name-inheritance-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Fork Name Inheritance Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server `thread/fork`, `thread/name/set`, protocol definitions,
upstream fork/name tests, and the current `.chat` backend implementation were
also read.

## Scope

This smoke covers:

```text
thread/start
turn/start
thread/read source before name
thread/name/set
thread/read source after name
thread/fork
thread/read fork
thread/list active
```

It proves only F05 for a completed source thread whose name is set through the
public app-server API. Existing fork smokes cover unnamed source forks,
`excludeTurns`, `lastTurnId`, path-addressed fork, and ephemeral fork.

## Result

- all normalized fork name fields equal: `{summary['all_normalized_fork_name_fields_equal']}`
- original set-name notification matches: `{summary['original_set_name_notification_matches']}`
- `.chat` set-name notification matches: `{summary['chat_backend_set_name_notification_matches']}`
- original source name visible after set: `{summary['original_source_name_visible_after_set']}`
- `.chat` source name visible after set: `{summary['chat_backend_source_name_visible_after_set']}`
- original fork inherited name: `{summary['original_fork_inherited_name']}`
- `.chat` fork inherited name: `{summary['chat_backend_fork_inherited_name']}`
- original fork read inherited name: `{summary['original_fork_read_inherited_name']}`
- `.chat` fork read inherited name: `{summary['chat_backend_fork_read_inherited_name']}`
- original list names match: `{summary['original_list_names_match']}`
- `.chat` list names match: `{summary['chat_backend_list_names_match']}`
- original source unchanged after named fork: `{summary['original_source_unchanged_after_named_fork']}`
- `.chat` source package unchanged after named fork: `{summary['chat_backend_source_unchanged_after_named_fork']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- no extra model request for name or fork: `{summary['mock_no_extra_model_request_for_name_or_fork']}`
- conversation storage counts equal after named fork: `{summary['conversation_storage_counts_equal_after_named_fork']}`
- conversation storage line counts equal after named fork: `{summary['conversation_storage_line_counts_equal_after_named_fork']}`
- original legacy name-index line count before fork: `{summary['original_legacy_name_index_line_count_before_fork']}`
- original legacy name-index line count after fork: `{summary['original_legacy_name_index_line_count_after_fork']}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/fork-name-inheritance-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/fork-name-inheritance-response.json
```

## Not Yet Proven

This smoke does not prove fork token usage replay ordering, interrupted
active-turn fork, rollback, compaction/context restore, command execution,
crash recovery, cold history, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_fork_name_fields_equal"],
            summary["original_set_name_notification_matches"],
            summary["chat_backend_set_name_notification_matches"],
            summary["original_source_name_visible_after_set"],
            summary["chat_backend_source_name_visible_after_set"],
            summary["original_fork_inherited_name"],
            summary["chat_backend_fork_inherited_name"],
            summary["original_fork_read_inherited_name"],
            summary["chat_backend_fork_read_inherited_name"],
            summary["original_list_names_match"],
            summary["chat_backend_list_names_match"],
            summary["original_source_unchanged_after_named_fork"],
            summary["chat_backend_source_unchanged_after_named_fork"],
            summary["mock_response_request_counts_equal"],
            summary["mock_no_extra_model_request_for_name_or_fork"],
            summary["conversation_storage_counts_equal_after_named_fork"],
            summary["conversation_storage_line_counts_equal_after_named_fork"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
