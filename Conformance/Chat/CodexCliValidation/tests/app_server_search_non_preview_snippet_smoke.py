#!/usr/bin/env python3
"""Run app-server search snippet parity smoke for non-preview transcript matches.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both the original Codex backend and the adapted `.chat` backend.

It covers an L03 slice not covered by the pagination smoke:

- the search term appears in a persisted assistant transcript item;
- the thread preview / first user message does not contain the search term;
- active and archived `thread/search` snippets come from the matching
  transcript text, not from preview fallback.
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
from app_server_search_pagination_smoke import (  # noqa: E402
    send_turn_start_with_text,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_start,
)


SEARCH_TERM = "non-preview transcript validation needle"
USER_TEXT = "Open a search snippet thread without the target phrase."
ASSISTANT_TEXT = (
    "Assistant transcript carries the non-preview transcript validation needle "
    "for search parity."
)


def send_thread_search(
    client: JsonRpcClient,
    request_id: int,
    *,
    archived: bool = False,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/search",
            "params": {
                "limit": 10,
                "archived": archived,
                "searchTerm": SEARCH_TERM,
                "sortKey": "created_at",
                "sortDirection": "desc",
            },
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
            "params": {"threadId": thread_id},
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def normalize_search_response(response: dict[str, Any], thread_id: str | None) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    items = []
    for item in data:
        thread = item.get("thread") or {}
        if thread.get("id") != thread_id:
            continue
        snippet = item.get("snippet") or ""
        preview = thread.get("preview") or ""
        items.append(
            {
                "snippet": snippet,
                "snippet_contains_search_term": SEARCH_TERM.lower() in snippet.lower(),
                "preview_contains_search_term": SEARCH_TERM.lower() in preview.lower(),
                "thread_source": thread.get("source"),
                "thread_status_type": (thread.get("status") or {}).get("type"),
                "thread_model_provider": thread.get("modelProvider"),
            }
        )
    return {
        "has_error": "error" in response,
        "matching_count": len(items),
        "items": items,
        "next_cursor_present": result.get("nextCursor") is not None,
    }


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count", 0)


def chat_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("journal_line_count", 0)


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
            thread_id, thread_start_response = send_thread_start(client, 10, workspace)
            turn_start_response = send_turn_start_with_text(
                client, 11, thread_id, USER_TEXT
            )
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )
            active_search_response = send_thread_search(client, 20, archived=False)
            archive_response = send_thread_archive(client, 30, thread_id)
            archived_search_response = send_thread_search(client, 40, archived=True)
            storage_summary = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_id": thread_id,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_started_notification": turn_started_notification,
        "turn_completed_notification": turn_completed_notification,
        "active_search_response": active_search_response,
        "archive_response": archive_response,
        "archived_search_response": archived_search_response,
        "active_search": normalize_search_response(active_search_response, thread_id),
        "archived_search": normalize_search_response(archived_search_response, thread_id),
        "storage_summary": storage_summary,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def first_snippet(search: dict[str, Any]) -> str | None:
    items = search.get("items") or []
    if not items:
        return None
    return items[0].get("snippet")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-search-non-preview-snippet-smoke-"
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_active = original_result["active_search"]
    chat_active = chat_result["active_search"]
    original_archived = original_result["archived_search"]
    chat_archived = chat_result["archived_search"]
    original_active_snippet = first_snippet(original_active)
    chat_active_snippet = first_snippet(chat_active)
    original_archived_snippet = first_snippet(original_archived)
    chat_archived_snippet = first_snippet(chat_archived)
    original_rollout_lines = line_count(original_result["storage_summary"], "rollouts")
    chat_journal_lines = chat_journal_line_count(chat_result["storage_summary"])

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-search-non-preview-snippet-smoke",
        "search_term": SEARCH_TERM,
        "user_text_contains_search_term": SEARCH_TERM.lower() in USER_TEXT.lower(),
        "assistant_text_contains_search_term": SEARCH_TERM.lower()
        in ASSISTANT_TEXT.lower(),
        "binary_checks": binary_checks,
        "active_normalized_equal": original_active == chat_active,
        "archived_normalized_equal": original_archived == chat_archived,
        "active_snippets_equal": original_active_snippet == chat_active_snippet,
        "archived_snippets_equal": original_archived_snippet == chat_archived_snippet,
        "active_snippet_contains_search_term": all(
            item["snippet_contains_search_term"]
            for item in original_active["items"] + chat_active["items"]
        ),
        "archived_snippet_contains_search_term": all(
            item["snippet_contains_search_term"]
            for item in original_archived["items"] + chat_archived["items"]
        ),
        "active_preview_excludes_search_term": all(
            item["preview_contains_search_term"] is False
            for item in original_active["items"] + chat_active["items"]
        ),
        "archived_preview_excludes_search_term": all(
            item["preview_contains_search_term"] is False
            for item in original_archived["items"] + chat_archived["items"]
        ),
        "active_search_has_one_match_each": original_active["matching_count"] == 1
        and chat_active["matching_count"] == 1,
        "archived_search_has_one_match_each": original_archived["matching_count"] == 1
        and chat_archived["matching_count"] == 1,
        "journal_line_count_matches_original": original_rollout_lines is not None
        and original_rollout_lines == chat_journal_lines,
        "original_rollout_lines": original_rollout_lines,
        "chat_journal_lines": chat_journal_lines,
        "original": {
            "active_search": original_active,
            "archived_search": original_archived,
        },
        "chat_backend": {
            "active_search": chat_active,
            "archived_search": chat_archived,
        },
        "not_yet_proven": [
            "stale-index crash repair",
            "cold history parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/search-non-preview-response.json", original_result)
    write_json(
        output_dir / "chat-backend/search-non-preview-response.json", chat_result
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Search Non-Preview Snippet Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers:

```text
create one durable thread whose first user message does not contain the search term
persist an assistant transcript message that contains the search term
active thread/search verifies snippet comes from the non-preview transcript match
archive the thread
archived thread/search verifies the same non-preview transcript snippet
```

It proves only the L03 snippet slice where the match is in transcript content
outside the thread preview. It does not prove stale-index crash repair, cold
history, complete data fidelity, or final user-indistinguishability.

## Result

- active normalized fields equal: `{summary['active_normalized_equal']}`
- archived normalized fields equal: `{summary['archived_normalized_equal']}`
- active snippets exactly equal: `{summary['active_snippets_equal']}`
- archived snippets exactly equal: `{summary['archived_snippets_equal']}`
- active snippets contain search term: `{summary['active_snippet_contains_search_term']}`
- archived snippets contain search term: `{summary['archived_snippet_contains_search_term']}`
- active previews exclude search term: `{summary['active_preview_excludes_search_term']}`
- archived previews exclude search term: `{summary['archived_preview_excludes_search_term']}`
- active search has one match in each backend: `{summary['active_search_has_one_match_each']}`
- archived search has one match in each backend: `{summary['archived_search_has_one_match_each']}`
- `.chat` journal line count matched original rollout: `{summary['journal_line_count_matches_original']}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/search-non-preview-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/search-non-preview-response.json
```

## Not Yet Proven

This smoke does not prove stale-index crash repair, cold history, complete data
fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["user_text_contains_search_term"] is False,
            summary["assistant_text_contains_search_term"],
            summary["active_normalized_equal"],
            summary["archived_normalized_equal"],
            summary["active_snippets_equal"],
            summary["archived_snippets_equal"],
            summary["active_snippet_contains_search_term"],
            summary["archived_snippet_contains_search_term"],
            summary["active_preview_excludes_search_term"],
            summary["archived_preview_excludes_search_term"],
            summary["active_search_has_one_match_each"],
            summary["archived_search_has_one_match_each"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
