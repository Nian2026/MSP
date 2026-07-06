#!/usr/bin/env python3
"""Run stale-index repair app-server parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend. It
covers an L08/H04-adjacent slice where a `.chat` metadata index exists, parses
as JSON, but no longer describes the canonical package it sits inside.
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
    normalize_thread_list_response,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    SEARCH_TERM,
    send_thread_list,
    send_thread_search,
    normalize_thread_search_response,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    normalize_thread_response,
    send_initialize,
    send_thread_read,
    send_thread_start,
    send_turn_start,
)


STALE_THREAD_ID = "00000000-0000-0000-0000-00000000feed"
STALE_PREVIEW = "stale index preview that must not be user visible"


def read_chat_index(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {}
    index_path = chat_root / f"{thread_id}.chat" / "indexes/thread-metadata.json"
    if not index_path.exists():
        return {"exists": False, "path": str(index_path)}
    try:
        index = json.loads(index_path.read_text())
    except json.JSONDecodeError as err:
        return {
            "exists": True,
            "path": str(index_path),
            "decode_error": str(err),
        }
    return {
        "exists": True,
        "path": str(index_path),
        "thread_id": index.get("thread_id"),
        "rollout_path": index.get("rollout_path"),
        "preview": index.get("preview"),
        "first_user_message": index.get("first_user_message"),
    }


def corrupt_chat_metadata_index(
    chat_root: pathlib.Path,
    thread_id: str | None,
) -> dict[str, Any]:
    if thread_id is None:
        return {"corrupted": False, "reason": "missing thread id"}
    package = chat_root / f"{thread_id}.chat"
    index_path = package / "indexes/thread-metadata.json"
    before = read_chat_index(chat_root, thread_id)
    if not index_path.exists():
        return {"corrupted": False, "reason": "index missing", "before": before}
    index = json.loads(index_path.read_text())
    index["thread_id"] = STALE_THREAD_ID
    index["rollout_path"] = str(chat_root / f"{STALE_THREAD_ID}.chat")
    index["preview"] = STALE_PREVIEW
    index["first_user_message"] = STALE_PREVIEW
    index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
    return {
        "corrupted": True,
        "index_path": str(index_path),
        "before": before,
        "after": read_chat_index(chat_root, thread_id),
    }


def chat_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("journal_line_count", 0)


def original_rollout_line_count(summary: dict[str, Any]) -> int | None:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return None
    return rollouts[0].get("line_count", 0)


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
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)
            turn_start_response = send_turn_start(client, 3, thread_id)
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            storage_before_corruption = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            corruption_action = (
                corrupt_chat_metadata_index(chat_root, thread_id)
                if tree_name == "chat-backend"
                else {
                    "corrupted": False,
                    "note": "original backend is the user-visible oracle",
                }
            )
            list_after_corruption_response = send_thread_list(
                client, 10, archived=False
            )
            search_after_corruption_response = send_thread_search(
                client, 11, archived=False
            )
            read_after_corruption_response = send_thread_read(client, 12, thread_id)
            storage_after_repair = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            repaired_index = (
                read_chat_index(chat_root, thread_id)
                if tree_name == "chat-backend"
                else {}
            )
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "thread_id": thread_id,
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_started_notification": turn_started_notification,
        "turn_completed_notification": turn_completed_notification,
        "storage_before_corruption": storage_before_corruption,
        "corruption_action": corruption_action,
        "list_after_corruption_response": list_after_corruption_response,
        "search_after_corruption_response": search_after_corruption_response,
        "read_after_corruption_response": read_after_corruption_response,
        "storage_after_repair": storage_after_repair,
        "repaired_index": repaired_index,
        "normalized_list_after_corruption": normalize_thread_list_response(
            list_after_corruption_response, thread_id
        ),
        "normalized_search_after_corruption": normalize_thread_search_response(
            search_after_corruption_response, thread_id
        ),
        "normalized_read_after_corruption": normalize_thread_response(
            read_after_corruption_response, thread_id
        ),
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
            "app-server-stale-index-repair-smoke-"
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

    original_lines = original_rollout_line_count(original_result["storage_after_repair"])
    chat_lines = chat_journal_line_count(chat_result["storage_after_repair"])
    repaired_index = chat_result["repaired_index"]
    repaired_preview = repaired_index.get("preview") or ""
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-stale-index-repair-smoke",
        "search_term": SEARCH_TERM,
        "stale_thread_id": STALE_THREAD_ID,
        "stale_preview": STALE_PREVIEW,
        "binary_checks": binary_checks,
        "chat_backend_index_was_corrupted": chat_result["corruption_action"].get(
            "corrupted"
        )
        is True,
        "chat_backend_corrupted_index_thread_id": (
            chat_result["corruption_action"].get("after") or {}
        ).get("thread_id"),
        "list_after_corruption_equal": original_result[
            "normalized_list_after_corruption"
        ]
        == chat_result["normalized_list_after_corruption"],
        "search_after_corruption_equal": original_result[
            "normalized_search_after_corruption"
        ]
        == chat_result["normalized_search_after_corruption"],
        "read_after_corruption_equal": original_result[
            "normalized_read_after_corruption"
        ]
        == chat_result["normalized_read_after_corruption"],
        "chat_backend_list_contains_thread_after_corruption": chat_result[
            "normalized_list_after_corruption"
        ]["contains_started_thread"],
        "chat_backend_search_contains_thread_after_corruption": chat_result[
            "normalized_search_after_corruption"
        ]["contains_started_thread"],
        "chat_backend_read_contains_thread_after_corruption": chat_result[
            "normalized_read_after_corruption"
        ]["thread_id_matches"],
        "chat_backend_repaired_index_thread_id_matches": repaired_index.get(
            "thread_id"
        )
        == chat_result["thread_id"],
        "chat_backend_repaired_index_preview_restored": SEARCH_TERM.lower()
        in repaired_preview.lower(),
        "chat_backend_stale_preview_not_visible": STALE_PREVIEW.lower()
        not in json.dumps(
            {
                "list": chat_result["normalized_list_after_corruption"],
                "search": chat_result["normalized_search_after_corruption"],
                "read": chat_result["normalized_read_after_corruption"],
            },
            ensure_ascii=False,
        ).lower(),
        "journal_line_count_matches_original": original_lines is not None
        and original_lines == chat_lines,
        "original_rollout_lines": original_lines,
        "chat_journal_lines": chat_lines,
        "original": {
            "list": original_result["normalized_list_after_corruption"],
            "search": original_result["normalized_search_after_corruption"],
            "read": original_result["normalized_read_after_corruption"],
        },
        "chat_backend": {
            "list": chat_result["normalized_list_after_corruption"],
            "search": chat_result["normalized_search_after_corruption"],
            "read": chat_result["normalized_read_after_corruption"],
            "corruption_action": chat_result["corruption_action"],
            "repaired_index": repaired_index,
        },
        "not_yet_proven": [
            "crash during pending write",
            "crash during archive/delete",
            "cold history parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/stale-index-repair-response.json", original_result)
    write_json(
        output_dir / "chat-backend/stale-index-repair-response.json", chat_result
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Stale Index Repair Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers:

```text
create one durable thread
for the .chat backend, replace indexes/thread-metadata.json with valid but stale metadata
thread/list after stale index
thread/search after stale index
thread/read after stale index, which repairs the derived metadata index
```

The stale index is deliberately valid JSON and carries a different thread id,
wrong rollout path, and wrong preview. This is stronger than the earlier
missing-index repair smoke because the derived file exists and could otherwise
masquerade as canonical metadata.

## Result

- `.chat` index was corrupted before checks: `{summary['chat_backend_index_was_corrupted']}`
- corrupted index thread id: `{summary['chat_backend_corrupted_index_thread_id']}`
- list after corruption equal: `{summary['list_after_corruption_equal']}`
- search after corruption equal: `{summary['search_after_corruption_equal']}`
- read after corruption equal: `{summary['read_after_corruption_equal']}`
- `.chat` list contains thread after corruption: `{summary['chat_backend_list_contains_thread_after_corruption']}`
- `.chat` search contains thread after corruption: `{summary['chat_backend_search_contains_thread_after_corruption']}`
- `.chat` read contains thread after corruption: `{summary['chat_backend_read_contains_thread_after_corruption']}`
- repaired index thread id matches: `{summary['chat_backend_repaired_index_thread_id_matches']}`
- repaired index preview restored: `{summary['chat_backend_repaired_index_preview_restored']}`
- stale preview not visible: `{summary['chat_backend_stale_preview_not_visible']}`
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
{output_dir.relative_to(VALIDATION_DIR)}/original/stale-index-repair-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/stale-index-repair-response.json
```

## Not Yet Proven

This smoke does not prove crash during pending write, crash during archive/delete,
cold history, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["chat_backend_index_was_corrupted"],
            summary["chat_backend_corrupted_index_thread_id"] == STALE_THREAD_ID,
            summary["list_after_corruption_equal"],
            summary["search_after_corruption_equal"],
            summary["read_after_corruption_equal"],
            summary["chat_backend_list_contains_thread_after_corruption"],
            summary["chat_backend_search_contains_thread_after_corruption"],
            summary["chat_backend_read_contains_thread_after_corruption"],
            summary["chat_backend_repaired_index_thread_id_matches"],
            summary["chat_backend_repaired_index_preview_restored"],
            summary["chat_backend_stale_preview_not_visible"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
