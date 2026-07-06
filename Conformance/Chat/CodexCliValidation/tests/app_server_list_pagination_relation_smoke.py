#!/usr/bin/env python3
"""Run app-server list pagination and relation-filter parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend.

It covers a narrow L01/L02 pagination slice:

- three durable threads;
- `thread/list` with `limit=1` across multiple pages;
- created-at cursor shape as user-visible JSON-RPC output;
- relation filters with no matching children/descendants;
- mutually exclusive parent/ancestor relation parameter error.

It does not prove positive spawned-child relation results. That needs a later
smoke that creates a real subagent/thread-spawn relationship through Codex.
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

from app_server_durable_turn_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_start,
)


def send_turn_start_with_text(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    text: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": f"client-user-message-{request_id}",
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
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_list(
    client: JsonRpcClient,
    request_id: int,
    *,
    limit: int = 1,
    cursor: str | None = None,
    parent_thread_id: str | None = None,
    ancestor_thread_id: str | None = None,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "limit": limit,
        "modelProviders": [],
        "archived": False,
    }
    if cursor is not None:
        params["cursor"] = cursor
    if parent_thread_id is not None:
        params["parentThreadId"] = parent_thread_id
    if ancestor_thread_id is not None:
        params["ancestorThreadId"] = ancestor_thread_id
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": params,
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def thread_ids_from_list(response: dict[str, Any]) -> list[str]:
    return [
        thread.get("id")
        for thread in ((response.get("result") or {}).get("data") or [])
        if thread.get("id") is not None
    ]


def cursor_from_list(response: dict[str, Any]) -> str | None:
    return (response.get("result") or {}).get("nextCursor")


def normalize_list_page(
    response: dict[str, Any],
    id_to_label: dict[str, str],
) -> dict[str, Any]:
    cursor = cursor_from_list(response)
    ids = thread_ids_from_list(response)
    return {
        "has_error": "error" in response,
        "labels": [id_to_label.get(thread_id, "unknown") for thread_id in ids],
        "count": len(ids),
        "next_cursor_present": cursor is not None,
        "next_cursor_has_thread_id_tiebreaker": isinstance(cursor, str)
        and "|" in cursor,
        "next_cursor_has_fractional_seconds": isinstance(cursor, str)
        and "." in cursor.split("|", 1)[0],
        "backwards_cursor_present": (response.get("result") or {}).get("backwardsCursor")
        is not None,
    }


def normalize_relation_empty(response: dict[str, Any]) -> dict[str, Any]:
    result = response.get("result") or {}
    return {
        "has_error": "error" in response,
        "count": len(result.get("data") or []),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def normalize_error(response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error") or {}
    message = error.get("message") or ""
    if "parentThreadId and ancestorThreadId are mutually exclusive" in message:
        message_class = "relation_params_mutually_exclusive"
    else:
        message_class = message
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message_class": message_class,
    }


def wait_for_next_unix_second() -> None:
    current_second = int(time.time())
    deadline = time.time() + 3
    while int(time.time()) <= current_second and time.time() < deadline:
        time.sleep(0.02)
    time.sleep(0.05)


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

    thread_ids: list[str | None] = []
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            for index in range(3):
                request_base = 10 + index * 10
                thread_id, thread_start_response = send_thread_start(
                    client, request_base, workspace
                )
                thread_ids.append(thread_id)
                turn_start_response = send_turn_start_with_text(
                    client,
                    request_base + 1,
                    thread_id,
                    f"List pagination validation thread {index + 1}.",
                )
                turn_started_notification = client.receive_until_method(
                    "turn/started", timeout_seconds=30
                )
                turn_completed_notification = client.receive_until_method(
                    "turn/completed", timeout_seconds=60
                )
                if index < 2:
                    wait_for_next_unix_second()

            first_page = send_thread_list(client, 100, limit=1)
            first_cursor = cursor_from_list(first_page)
            second_page = send_thread_list(client, 101, limit=1, cursor=first_cursor)
            second_cursor = cursor_from_list(second_page)
            third_page = send_thread_list(client, 102, limit=1, cursor=second_cursor)

            parent_for_empty_relation = thread_ids[0]
            direct_children_empty = send_thread_list(
                client,
                104,
                limit=2,
                parent_thread_id=parent_for_empty_relation,
            )
            descendants_empty = send_thread_list(
                client,
                105,
                limit=2,
                ancestor_thread_id=parent_for_empty_relation,
            )
            mutually_exclusive_relation_error = send_thread_list(
                client,
                106,
                limit=2,
                parent_thread_id=parent_for_empty_relation,
                ancestor_thread_id=parent_for_empty_relation,
            )

            storage_summary = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
        finally:
            stderr = client.close()

    id_to_label = {
        thread_id: f"thread-{index + 1}"
        for index, thread_id in enumerate(thread_ids)
        if thread_id is not None
    }
    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_ids": thread_ids,
        "pagination_pages": [first_page, second_page, third_page],
        "direct_children_empty_response": direct_children_empty,
        "descendants_empty_response": descendants_empty,
        "mutually_exclusive_relation_error": mutually_exclusive_relation_error,
        "normalized_pages": [
            normalize_list_page(first_page, id_to_label),
            normalize_list_page(second_page, id_to_label),
            normalize_list_page(third_page, id_to_label),
        ],
        "normalized_direct_children_empty": normalize_relation_empty(
            direct_children_empty
        ),
        "normalized_descendants_empty": normalize_relation_empty(descendants_empty),
        "normalized_mutually_exclusive_relation_error": normalize_error(
            mutually_exclusive_relation_error
        ),
        "storage_summary": storage_summary,
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
            "app-server-list-pagination-relation-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)
    (output_dir / "original").mkdir()
    (output_dir / "chat-backend").mkdir()

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

    original_pages = original_result["normalized_pages"]
    chat_pages = chat_result["normalized_pages"]
    expected_page_labels = [
        ["thread-3"],
        ["thread-2"],
        ["thread-1"],
    ]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-list-pagination-relation-smoke",
        "binary_checks": binary_checks,
        "normalized_pagination_equal": original_pages == chat_pages,
        "original_page_labels_match_expected": [
            page["labels"] for page in original_pages
        ]
        == expected_page_labels,
        "chat_backend_page_labels_match_expected": [
            page["labels"] for page in chat_pages
        ]
        == expected_page_labels,
        "created_at_cursors_do_not_use_thread_id_tiebreaker": all(
            page["next_cursor_has_thread_id_tiebreaker"] is False
            for page in original_pages[:2] + chat_pages[:2]
        ),
        "created_at_cursors_use_second_precision": all(
            page["next_cursor_has_fractional_seconds"] is False
            for page in original_pages[:2] + chat_pages[:2]
        ),
        "final_pages_have_no_next_cursor": original_pages[2]["next_cursor_present"]
        is False
        and chat_pages[2]["next_cursor_present"] is False,
        "direct_children_empty_equal": original_result[
            "normalized_direct_children_empty"
        ]
        == chat_result["normalized_direct_children_empty"],
        "descendants_empty_equal": original_result["normalized_descendants_empty"]
        == chat_result["normalized_descendants_empty"],
        "mutually_exclusive_relation_error_equal": original_result[
            "normalized_mutually_exclusive_relation_error"
        ]
        == chat_result["normalized_mutually_exclusive_relation_error"],
        "original": {
            "normalized_pages": original_pages,
            "normalized_direct_children_empty": original_result[
                "normalized_direct_children_empty"
            ],
            "normalized_descendants_empty": original_result[
                "normalized_descendants_empty"
            ],
            "normalized_mutually_exclusive_relation_error": original_result[
                "normalized_mutually_exclusive_relation_error"
            ],
        },
        "chat_backend": {
            "normalized_pages": chat_pages,
            "normalized_direct_children_empty": chat_result[
                "normalized_direct_children_empty"
            ],
            "normalized_descendants_empty": chat_result[
                "normalized_descendants_empty"
            ],
            "normalized_mutually_exclusive_relation_error": chat_result[
                "normalized_mutually_exclusive_relation_error"
            ],
        },
        "not_yet_proven": [
            "positive spawned-child relation-filter app-server results",
            "relation-filter pagination with matching spawned descendants",
            "relation-filter archive/delete descendant ordering",
            "search pagination cursor parity",
            "cold history parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/list-pagination-relation-response.json", original_result)
    write_json(
        output_dir / "chat-backend/list-pagination-relation-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server List Pagination/Relation Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers:

```text
create three durable threads
thread/list limit=1 page 1
thread/list limit=1 page 2 with nextCursor
thread/list limit=1 page 3 with nextCursor
thread/list page 3 has no nextCursor
thread/list parentThreadId with no children
thread/list ancestorThreadId with no descendants
thread/list parentThreadId + ancestorThreadId mutual-exclusion error
```

It proves a narrow L01 pagination/cursor slice and an L02 empty relation-filter
slice. It does not prove positive spawned-child relation-filter results.

## Result

- normalized pagination equal: `{summary['normalized_pagination_equal']}`
- original page labels match expected: `{summary['original_page_labels_match_expected']}`
- `.chat` page labels match expected: `{summary['chat_backend_page_labels_match_expected']}`
- created-at cursors avoid thread-id tie-breaker: `{summary['created_at_cursors_do_not_use_thread_id_tiebreaker']}`
- created-at cursors use second precision: `{summary['created_at_cursors_use_second_precision']}`
- final pages have no next cursor: `{summary['final_pages_have_no_next_cursor']}`
- direct-children empty relation equal: `{summary['direct_children_empty_equal']}`
- descendants empty relation equal: `{summary['descendants_empty_equal']}`
- mutual-exclusion relation error equal: `{summary['mutually_exclusive_relation_error_equal']}`

## Original Normalized Fields

```json
{json.dumps(summary['original'], indent=2, sort_keys=True)}
```

## `.chat` Backend Normalized Fields

```json
{json.dumps(summary['chat_backend'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/list-pagination-relation-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/list-pagination-relation-response.json
```

## Not Yet Proven

This smoke does not prove positive spawned-child relation-filter results,
relation-filter pagination with matching descendants, descendant lifecycle
ordering, search pagination cursor parity, cold history, complete data fidelity,
or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["normalized_pagination_equal"],
            summary["original_page_labels_match_expected"],
            summary["chat_backend_page_labels_match_expected"],
            summary["created_at_cursors_do_not_use_thread_id_tiebreaker"],
            summary["created_at_cursors_use_second_precision"],
            summary["final_pages_have_no_next_cursor"],
            summary["direct_children_empty_equal"],
            summary["descendants_empty_equal"],
            summary["mutually_exclusive_relation_error_equal"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
