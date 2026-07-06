#!/usr/bin/env python3
"""Run app-server search pagination/cursor parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both the original Codex backend and the adapted `.chat` backend.

It covers L03 search pagination slices:

- three durable threads containing the same search term;
- active `thread/search` with `limit=1` across multiple pages;
- archived `thread/search` with `limit=1` across multiple pages;
- source-kind filtered search pagination;
- recency search cursor shape as user-visible JSON-RPC output;
- final page has no `nextCursor`.
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
from app_server_list_pagination_relation_smoke import (  # noqa: E402
    wait_for_next_unix_second,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_start,
)


SEARCH_TERM = "search pagination validation needle"


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


def send_thread_search(
    client: JsonRpcClient,
    request_id: int,
    *,
    limit: int = 1,
    cursor: str | None = None,
    archived: bool = False,
    sort_key: str = "created_at",
    sort_direction: str = "desc",
    source_kinds: list[str] | None = None,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "limit": limit,
        "archived": archived,
        "searchTerm": SEARCH_TERM,
        "sortKey": sort_key,
        "sortDirection": sort_direction,
    }
    if cursor is not None:
        params["cursor"] = cursor
    if source_kinds is not None:
        params["sourceKinds"] = source_kinds
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/search",
            "params": params,
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_archive(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/archive",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def cursor_from_search(response: dict[str, Any]) -> str | None:
    return (response.get("result") or {}).get("nextCursor")


def search_ids(response: dict[str, Any]) -> list[str]:
    return [
        (item.get("thread") or {}).get("id")
        for item in ((response.get("result") or {}).get("data") or [])
        if (item.get("thread") or {}).get("id") is not None
    ]


def normalize_search_page(
    response: dict[str, Any],
    id_to_label: dict[str, str],
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    cursor = result.get("nextCursor")
    normalized_items = []
    for item in data:
        thread = item.get("thread") or {}
        snippet = item.get("snippet") or ""
        normalized_items.append(
            {
                "label": id_to_label.get(thread.get("id"), "unknown"),
                "snippet_contains_search_term": SEARCH_TERM.lower()
                in snippet.lower(),
                "thread_preview_contains_search_term": SEARCH_TERM.lower()
                in (thread.get("preview") or "").lower(),
                "thread_source": thread.get("source"),
                "thread_model_provider": thread.get("modelProvider"),
                "thread_status_type": (thread.get("status") or {}).get("type"),
            }
        )
    return {
        "has_error": "error" in response,
        "count": len(data),
        "items": normalized_items,
        "next_cursor_present": cursor is not None,
        "next_cursor_has_thread_id_tiebreaker": isinstance(cursor, str)
        and "|" in cursor,
        "next_cursor_has_fractional_seconds": isinstance(cursor, str)
        and "." in cursor.split("|", 1)[0],
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def fetch_search_pages(
    client: JsonRpcClient,
    request_base: int,
    *,
    expected_pages: int,
    archived: bool = False,
    sort_key: str = "created_at",
    source_kinds: list[str] | None = None,
) -> list[dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    cursor: str | None = None
    for index in range(expected_pages):
        page = send_thread_search(
            client,
            request_base + index,
            limit=1,
            cursor=cursor,
            archived=archived,
            sort_key=sort_key,
            source_kinds=source_kinds,
        )
        pages.append(page)
        cursor = cursor_from_search(page)
        if cursor is None:
            break
    return pages


def normalize_search_scenario(
    pages: list[dict[str, Any]],
    id_to_label: dict[str, str],
) -> dict[str, Any]:
    normalized_pages = [normalize_search_page(page, id_to_label) for page in pages]
    labels = [[item["label"] for item in page["items"]] for page in normalized_pages]
    return {
        "page_count": len(normalized_pages),
        "labels": labels,
        "pages": normalized_pages,
    }


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 3:
        return None
    return sum(item.get("line_count", 0) for item in items)


def chat_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("packages") or []
    if len(packages) != 3:
        return None
    return sum(package.get("journal_line_count", 0) for package in packages)


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
                    f"{SEARCH_TERM} thread {index + 1}.",
                )
                turn_started_notification = client.receive_until_method(
                    "turn/started", timeout_seconds=30
                )
                turn_completed_notification = client.receive_until_method(
                    "turn/completed", timeout_seconds=60
                )
                if index < 2:
                    wait_for_next_unix_second()

            active_created_pages = fetch_search_pages(
                client,
                100,
                expected_pages=3,
                sort_key="created_at",
            )
            active_vscode_pages = fetch_search_pages(
                client,
                110,
                expected_pages=3,
                sort_key="created_at",
                source_kinds=["vscode"],
            )
            active_exec_page = send_thread_search(
                client,
                120,
                limit=1,
                sort_key="created_at",
                source_kinds=["exec"],
            )
            active_recency_pages = fetch_search_pages(
                client,
                130,
                expected_pages=3,
                sort_key="recency_at",
            )

            archive_responses = []
            for index, thread_id in enumerate(thread_ids):
                archive_responses.append(
                    send_thread_archive(client, 200 + index, thread_id)
                )

            archived_created_pages = fetch_search_pages(
                client,
                300,
                expected_pages=3,
                archived=True,
                sort_key="created_at",
            )
            archived_recency_pages = fetch_search_pages(
                client,
                310,
                expected_pages=3,
                archived=True,
                sort_key="recency_at",
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
    search_scenarios = {
        "active_created_at": normalize_search_scenario(
            active_created_pages, id_to_label
        ),
        "active_source_vscode": normalize_search_scenario(
            active_vscode_pages, id_to_label
        ),
        "active_source_exec": normalize_search_scenario(
            [active_exec_page], id_to_label
        ),
        "active_recency": normalize_search_scenario(active_recency_pages, id_to_label),
        "archived_created_at": normalize_search_scenario(
            archived_created_pages, id_to_label
        ),
        "archived_recency": normalize_search_scenario(
            archived_recency_pages, id_to_label
        ),
    }
    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_ids": thread_ids,
        "archive_responses": archive_responses,
        "search_scenarios": search_scenarios,
        "storage_summary": storage_summary,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-search-pagination-smoke-"
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

    original_scenarios = original_result["search_scenarios"]
    chat_scenarios = chat_result["search_scenarios"]
    expected_page_labels = [
        ["thread-3"],
        ["thread-2"],
        ["thread-1"],
    ]
    original_total_rollout_lines = line_count(
        original_result["storage_summary"], "rollouts"
    )
    chat_total_journal_lines = chat_journal_line_count(chat_result["storage_summary"])
    active_created = original_scenarios["active_created_at"]["pages"]
    chat_active_created = chat_scenarios["active_created_at"]["pages"]
    active_recency = original_scenarios["active_recency"]["pages"]
    chat_active_recency = chat_scenarios["active_recency"]["pages"]
    archived_created = original_scenarios["archived_created_at"]["pages"]
    chat_archived_created = chat_scenarios["archived_created_at"]["pages"]
    archived_recency = original_scenarios["archived_recency"]["pages"]
    chat_archived_recency = chat_scenarios["archived_recency"]["pages"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-search-pagination-smoke",
        "binary_checks": binary_checks,
        "normalized_search_scenarios_equal": original_scenarios == chat_scenarios,
        "active_created_labels_match_expected": original_scenarios[
            "active_created_at"
        ]["labels"]
        == expected_page_labels
        and chat_scenarios["active_created_at"]["labels"] == expected_page_labels,
        "active_source_vscode_labels_match_expected": original_scenarios[
            "active_source_vscode"
        ]["labels"]
        == expected_page_labels
        and chat_scenarios["active_source_vscode"]["labels"] == expected_page_labels,
        "active_source_exec_empty_equal": original_scenarios["active_source_exec"]
        == chat_scenarios["active_source_exec"]
        and original_scenarios["active_source_exec"]["labels"] == [[]],
        "active_recency_pages_equal": original_scenarios["active_recency"]
        == chat_scenarios["active_recency"],
        "archived_created_pages_equal": original_scenarios["archived_created_at"]
        == chat_scenarios["archived_created_at"],
        "archived_recency_pages_equal": original_scenarios["archived_recency"]
        == chat_scenarios["archived_recency"],
        "active_created_first_two_pages_have_next_cursor": all(
            page["next_cursor_present"]
            for page in active_created[:2] + chat_active_created[:2]
        ),
        "active_created_third_pages_have_no_next_cursor": active_created[2][
            "next_cursor_present"
        ]
        is False
        and chat_active_created[2]["next_cursor_present"] is False,
        "created_at_search_cursors_do_not_use_thread_id_tiebreaker": all(
            page["next_cursor_has_thread_id_tiebreaker"] is False
            for page in active_created[:2]
            + chat_active_created[:2]
            + archived_created[:2]
            + chat_archived_created[:2]
        ),
        "created_at_search_cursors_use_second_precision": all(
            page["next_cursor_has_fractional_seconds"] is False
            for page in active_created[:2]
            + chat_active_created[:2]
            + archived_created[:2]
            + chat_archived_created[:2]
        ),
        "recency_search_cursors_use_thread_id_tiebreaker": all(
            page["next_cursor_has_thread_id_tiebreaker"] is True
            for page in active_recency[:2]
            + chat_active_recency[:2]
            + archived_recency[:2]
            + chat_archived_recency[:2]
        ),
        "archived_search_pages_have_expected_shape": all(
            scenario["page_count"] == 3
            and all(len(page_labels) == 1 for page_labels in scenario["labels"])
            and scenario["pages"][2]["next_cursor_present"] is False
            for scenario in [
                original_scenarios["archived_created_at"],
                chat_scenarios["archived_created_at"],
                original_scenarios["archived_recency"],
                chat_scenarios["archived_recency"],
            ]
        ),
        "all_returned_snippets_contain_search_term": all(
            item["snippet_contains_search_term"]
            for scenario in list(original_scenarios.values())
            + list(chat_scenarios.values())
            for page in scenario["pages"]
            for item in page["items"]
        ),
        "journal_line_count_matches_original": original_total_rollout_lines is not None
        and original_total_rollout_lines == chat_total_journal_lines,
        "original_total_rollout_lines": original_total_rollout_lines,
        "chat_total_journal_lines": chat_total_journal_lines,
        "original": original_scenarios,
        "chat_backend": chat_scenarios,
        "not_yet_proven": [
            "search snippets from non-preview transcript matches",
            "stale-index crash repair",
            "cold history parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/search-pagination-response.json", original_result)
    write_json(
        output_dir / "chat-backend/search-pagination-response.json", chat_result
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Search Pagination Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers:

```text
create three durable threads containing the same search term
active thread/search created_at limit=1 pages 1-3
active thread/search sourceKinds=["vscode"] created_at limit=1 pages 1-3
active thread/search sourceKinds=["exec"] no-match filter
active thread/search recency_at limit=1 pages 1-3
archive all three threads
archived thread/search created_at limit=1 pages 1-3
archived thread/search recency_at limit=1 pages 1-3
created-at and recency search cursor shape
snippet/search-term preservation
```

It proves a bounded L03 search pagination/cursor slice across active, archived,
source-kind-filtered, and recency search paths. It does not prove search
snippets from non-preview transcript matches, stale-index crash repair, cold
history, complete data fidelity, or final user-indistinguishability.

## Result

- normalized search scenarios equal: `{summary['normalized_search_scenarios_equal']}`
- active created-at labels match expected: `{summary['active_created_labels_match_expected']}`
- active sourceKinds=["vscode"] labels match expected: `{summary['active_source_vscode_labels_match_expected']}`
- active sourceKinds=["exec"] empty results equal: `{summary['active_source_exec_empty_equal']}`
- active recency pages equal: `{summary['active_recency_pages_equal']}`
- archived created-at pages equal: `{summary['archived_created_pages_equal']}`
- archived recency pages equal: `{summary['archived_recency_pages_equal']}`
- active created-at first two pages have next cursor: `{summary['active_created_first_two_pages_have_next_cursor']}`
- active created-at third pages have no next cursor: `{summary['active_created_third_pages_have_no_next_cursor']}`
- created-at search cursors avoid thread-id tie-breaker: `{summary['created_at_search_cursors_do_not_use_thread_id_tiebreaker']}`
- created-at search cursors use second precision: `{summary['created_at_search_cursors_use_second_precision']}`
- recency search cursors use thread-id tie-breaker: `{summary['recency_search_cursors_use_thread_id_tiebreaker']}`
- archived search pages have expected shape: `{summary['archived_search_pages_have_expected_shape']}`
- snippets contain search term: `{summary['all_returned_snippets_contain_search_term']}`
- `.chat` journal line count matched original rollout total: `{summary['journal_line_count_matches_original']}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/search-pagination-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/search-pagination-response.json
```

## Not Yet Proven

This smoke does not prove search snippets from non-preview transcript matches,
stale-index crash repair, cold history, complete data fidelity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["normalized_search_scenarios_equal"],
            summary["active_created_labels_match_expected"],
            summary["active_source_vscode_labels_match_expected"],
            summary["active_source_exec_empty_equal"],
            summary["active_recency_pages_equal"],
            summary["archived_created_pages_equal"],
            summary["archived_recency_pages_equal"],
            summary["active_created_first_two_pages_have_next_cursor"],
            summary["active_created_third_pages_have_no_next_cursor"],
            summary["created_at_search_cursors_do_not_use_thread_id_tiebreaker"],
            summary["created_at_search_cursors_use_second_precision"],
            summary["recency_search_cursors_use_thread_id_tiebreaker"],
            summary["archived_search_pages_have_expected_shape"],
            summary["all_returned_snippets_contain_search_term"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
