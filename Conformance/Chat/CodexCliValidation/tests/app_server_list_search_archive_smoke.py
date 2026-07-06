#!/usr/bin/env python3
"""Run list/search/archive/unarchive/delete app-server parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend. It
covers a narrow L01/L03/L05/L06/L07 lifecycle slice after one durable model
turn.
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
    USER_TEXT,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    normalize_thread_list_response,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    normalize_thread_response,
    send_initialize,
    send_thread_read,
    send_thread_start,
    send_turn_start,
)


SEARCH_TERM = "durable .chat validation"
NO_MATCH_SEARCH_TERM = "absent-list-search-l04-no-match-token"


def send_thread_list(
    client: JsonRpcClient,
    request_id: int,
    archived: bool,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": {
                "limit": 10,
                "modelProviders": [],
                "archived": archived,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_search(
    client: JsonRpcClient,
    request_id: int,
    archived: bool,
    search_term: str = SEARCH_TERM,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/search",
            "params": {
                "limit": 10,
                "archived": archived,
                "searchTerm": search_term,
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
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_unarchive(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/unarchive",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_delete(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/delete",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def normalize_thread_search_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    matched_result = None
    if thread_id is not None:
        matched_result = next(
            (
                item
                for item in data
                if ((item.get("thread") or {}).get("id") == thread_id)
            ),
            None,
        )
    if matched_result is None and data:
        matched_result = data[0]

    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "result_count": len(data),
        "contains_started_thread": matched_result is not None
        and ((matched_result.get("thread") or {}).get("id") == thread_id),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }
    if matched_result is not None:
        thread = matched_result.get("thread") or {}
        snippet = matched_result.get("snippet") or ""
        normalized.update(
            {
                "snippet": snippet,
                "snippet_contains_search_term": SEARCH_TERM.lower()
                in snippet.lower(),
                "thread_preview": thread.get("preview"),
                "thread_source": thread.get("source"),
                "thread_status_type": status_type(thread.get("status")),
                "thread_model": thread.get("model"),
                "thread_model_provider": thread.get("modelProvider"),
                "thread_turn_count": len(thread.get("turns") or []),
            }
        )
    return normalized


def normalize_empty_response(response: dict[str, Any]) -> dict[str, Any]:
    return {
        "has_error": "error" in response,
        "result_keys": sorted((response.get("result") or {}).keys()),
    }


def normalize_archive_notification(
    notification: dict[str, Any] | None,
    thread_id: str | None,
) -> dict[str, Any]:
    params = (notification or {}).get("params") or {}
    return {
        "seen": notification is not None,
        "thread_id_matches": thread_id is not None and params.get("threadId") == thread_id,
    }


def normalize_delete_error(response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error") or {}
    message = error.get("message") or ""
    if "thread not loaded" in message:
        message_class = "thread_not_loaded"
    elif "thread not found" in message:
        message_class = "thread_not_found"
    else:
        message_class = message
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message_class": message_class,
    }


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def chat_package_lifecycle_state(
    summary: dict[str, Any],
    expected_archived: bool | None,
) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    if package.get("manifest_format") != "msp.chat":
        return False
    if package.get("timeline_line_count", 0) < 5:
        return False
    if package.get("journal_line_count", 0) < 5:
        return False
    if expected_archived is None:
        return True
    lifecycle = package.get("manifest_lifecycle") or {}
    return lifecycle.get("archived") is expected_archived


def summarize_chat_packages_with_lifecycle(chat_root: pathlib.Path) -> dict[str, Any]:
    summary = summarize_chat_packages(chat_root)
    for package in summary.get("packages") or []:
        manifest_path = pathlib.Path(package["package"]) / "manifest.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        lifecycle = manifest.get("lifecycle")
        archived_at = manifest.get("archived_at")
        if not isinstance(lifecycle, dict):
            lifecycle = {
                "archived": archived_at is not None,
                "archived_at": archived_at,
                "source": "manifest.archived_at",
            }
        package["manifest_lifecycle"] = lifecycle
        package["manifest_archived_at"] = archived_at
    return summary


def remove_chat_metadata_index(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    removed = []
    for package in packages:
        index_path = package / "indexes/thread-metadata.json"
        if index_path.exists():
            index_path.unlink()
            removed.append(str(index_path))
    return {
        "package_count": len(packages),
        "removed_index_count": len(removed),
        "removed_indexes": removed,
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
            started_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )
            turn_start_response = send_turn_start(client, 3, started_thread_id)
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            active_list_before_archive_response = send_thread_list(
                client, 4, archived=False
            )
            active_search_before_archive_response = send_thread_search(
                client, 5, archived=False
            )
            no_match_search_before_archive_response = send_thread_search(
                client, 20, archived=False, search_term=NO_MATCH_SEARCH_TERM
            )

            pre_archive_storage = (
                summarize_chat_packages_with_lifecycle(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            metadata_repair_action = (
                remove_chat_metadata_index(chat_root)
                if tree_name == "chat-backend"
                else {
                    "package_count": 0,
                    "removed_index_count": 0,
                    "removed_indexes": [],
                    "note": "original backend is the user-visible oracle for this probe",
                }
            )
            metadata_repair_read_response = send_thread_read(
                client, 21, started_thread_id
            )
            metadata_repair_list_response = send_thread_list(
                client, 22, archived=False
            )
            metadata_repair_search_response = send_thread_search(
                client, 23, archived=False
            )
            metadata_repair_storage = (
                summarize_chat_packages_with_lifecycle(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            archive_response = send_thread_archive(client, 6, started_thread_id)
            archive_notification = client.receive_until_method(
                "thread/archived", timeout_seconds=30
            )
            active_list_after_archive_response = send_thread_list(
                client, 7, archived=False
            )
            archived_list_after_archive_response = send_thread_list(
                client, 8, archived=True
            )
            active_search_after_archive_response = send_thread_search(
                client, 9, archived=False
            )
            archived_search_after_archive_response = send_thread_search(
                client, 10, archived=True
            )

            post_archive_storage = (
                summarize_chat_packages_with_lifecycle(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            unarchive_response = send_thread_unarchive(client, 11, started_thread_id)
            unarchive_notification = client.receive_until_method(
                "thread/unarchived", timeout_seconds=30
            )
            active_list_after_unarchive_response = send_thread_list(
                client, 12, archived=False
            )
            archived_list_after_unarchive_response = send_thread_list(
                client, 13, archived=True
            )
            final_thread_read_before_delete_response = send_thread_read(
                client, 14, started_thread_id
            )

            post_unarchive_storage = (
                summarize_chat_packages_with_lifecycle(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            delete_response = send_thread_delete(client, 15, started_thread_id)
            delete_notification = client.receive_until_method(
                "thread/deleted", timeout_seconds=30
            )
            active_list_after_delete_response = send_thread_list(
                client, 16, archived=False
            )
            archived_list_after_delete_response = send_thread_list(
                client, 17, archived=True
            )
            search_after_delete_response = send_thread_search(
                client, 18, archived=False
            )
            read_after_delete_response = send_thread_read(client, 19, started_thread_id)

            post_delete_storage = (
                summarize_chat_packages_with_lifecycle(chat_root)
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
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_started_notification": turn_started_notification,
        "turn_completed_notification": turn_completed_notification,
        "active_list_before_archive_response": active_list_before_archive_response,
        "active_search_before_archive_response": active_search_before_archive_response,
        "no_match_search_before_archive_response": no_match_search_before_archive_response,
        "metadata_repair_action": metadata_repair_action,
        "metadata_repair_read_response": metadata_repair_read_response,
        "metadata_repair_list_response": metadata_repair_list_response,
        "metadata_repair_search_response": metadata_repair_search_response,
        "archive_response": archive_response,
        "archive_notification": archive_notification,
        "active_list_after_archive_response": active_list_after_archive_response,
        "archived_list_after_archive_response": archived_list_after_archive_response,
        "active_search_after_archive_response": active_search_after_archive_response,
        "archived_search_after_archive_response": archived_search_after_archive_response,
        "unarchive_response": unarchive_response,
        "unarchive_notification": unarchive_notification,
        "active_list_after_unarchive_response": active_list_after_unarchive_response,
        "archived_list_after_unarchive_response": archived_list_after_unarchive_response,
        "final_thread_read_before_delete_response": final_thread_read_before_delete_response,
        "delete_response": delete_response,
        "delete_notification": delete_notification,
        "active_list_after_delete_response": active_list_after_delete_response,
        "archived_list_after_delete_response": archived_list_after_delete_response,
        "search_after_delete_response": search_after_delete_response,
        "read_after_delete_response": read_after_delete_response,
        "normalized_active_list_before_archive": normalize_thread_list_response(
            active_list_before_archive_response, started_thread_id
        ),
        "normalized_active_search_before_archive": normalize_thread_search_response(
            active_search_before_archive_response, started_thread_id
        ),
        "normalized_no_match_search_before_archive": normalize_thread_search_response(
            no_match_search_before_archive_response, started_thread_id
        ),
        "normalized_metadata_repair_read": normalize_thread_response(
            metadata_repair_read_response, started_thread_id
        ),
        "normalized_metadata_repair_list": normalize_thread_list_response(
            metadata_repair_list_response, started_thread_id
        ),
        "normalized_metadata_repair_search": normalize_thread_search_response(
            metadata_repair_search_response, started_thread_id
        ),
        "normalized_archive_response": normalize_empty_response(archive_response),
        "normalized_archive_notification": normalize_archive_notification(
            archive_notification, started_thread_id
        ),
        "normalized_active_list_after_archive": normalize_thread_list_response(
            active_list_after_archive_response, started_thread_id
        ),
        "normalized_archived_list_after_archive": normalize_thread_list_response(
            archived_list_after_archive_response, started_thread_id
        ),
        "normalized_active_search_after_archive": normalize_thread_search_response(
            active_search_after_archive_response, started_thread_id
        ),
        "normalized_archived_search_after_archive": normalize_thread_search_response(
            archived_search_after_archive_response, started_thread_id
        ),
        "normalized_unarchive_response": normalize_thread_response(
            unarchive_response, started_thread_id
        ),
        "normalized_unarchive_notification": normalize_archive_notification(
            unarchive_notification, started_thread_id
        ),
        "normalized_active_list_after_unarchive": normalize_thread_list_response(
            active_list_after_unarchive_response, started_thread_id
        ),
        "normalized_archived_list_after_unarchive": normalize_thread_list_response(
            archived_list_after_unarchive_response, started_thread_id
        ),
        "normalized_final_read_before_delete": normalize_thread_response(
            final_thread_read_before_delete_response, started_thread_id
        ),
        "normalized_delete_response": normalize_empty_response(delete_response),
        "normalized_delete_notification": normalize_archive_notification(
            delete_notification, started_thread_id
        ),
        "normalized_active_list_after_delete": normalize_thread_list_response(
            active_list_after_delete_response, started_thread_id
        ),
        "normalized_archived_list_after_delete": normalize_thread_list_response(
            archived_list_after_delete_response, started_thread_id
        ),
        "normalized_search_after_delete": normalize_thread_search_response(
            search_after_delete_response, started_thread_id
        ),
        "normalized_read_after_delete_error": normalize_delete_error(
            read_after_delete_response
        ),
        "pre_archive_storage_summary": pre_archive_storage,
        "metadata_repair_storage_summary": metadata_repair_storage,
        "post_archive_storage_summary": post_archive_storage,
        "post_unarchive_storage_summary": post_unarchive_storage,
        "post_delete_storage_summary": post_delete_storage,
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
            "app-server-list-search-archive-smoke-"
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
        "normalized_active_list_before_archive",
        "normalized_active_search_before_archive",
        "normalized_no_match_search_before_archive",
        "normalized_metadata_repair_read",
        "normalized_metadata_repair_list",
        "normalized_metadata_repair_search",
        "normalized_archive_response",
        "normalized_archive_notification",
        "normalized_active_list_after_archive",
        "normalized_archived_list_after_archive",
        "normalized_active_search_after_archive",
        "normalized_archived_search_after_archive",
        "normalized_unarchive_response",
        "normalized_unarchive_notification",
        "normalized_active_list_after_unarchive",
        "normalized_archived_list_after_unarchive",
        "normalized_final_read_before_delete",
        "normalized_delete_response",
        "normalized_delete_notification",
        "normalized_active_list_after_delete",
        "normalized_archived_list_after_delete",
        "normalized_search_after_delete",
        "normalized_read_after_delete_error",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    original_pre_lines = line_count(
        original_result["pre_archive_storage_summary"], "rollouts"
    )
    chat_pre_packages = (
        chat_result["pre_archive_storage_summary"].get("packages") or []
    )
    chat_pre_journal_lines = (
        chat_pre_packages[0].get("journal_line_count")
        if len(chat_pre_packages) == 1
        else None
    )
    chat_post_delete_package_count = chat_result["post_delete_storage_summary"].get(
        "package_count"
    )
    chat_metadata_repair_packages = (
        chat_result["metadata_repair_storage_summary"].get("packages") or []
    )
    chat_metadata_index_repaired = (
        len(chat_metadata_repair_packages) == 1
        and chat_metadata_repair_packages[0].get("index_exists") is True
    )
    original_post_delete_rollouts = (
        original_result["post_delete_storage_summary"].get("rollout_files") or []
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-list-search-archive-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_lifecycle_fields_equal": all(comparisons.values()),
        "original_active_list_before_archive_contains_thread": original_result[
            "normalized_active_list_before_archive"
        ]["contains_started_thread"],
        "chat_backend_active_list_before_archive_contains_thread": chat_result[
            "normalized_active_list_before_archive"
        ]["contains_started_thread"],
        "original_active_search_before_archive_contains_thread": original_result[
            "normalized_active_search_before_archive"
        ]["contains_started_thread"],
        "chat_backend_active_search_before_archive_contains_thread": chat_result[
            "normalized_active_search_before_archive"
        ]["contains_started_thread"],
        "original_no_match_search_before_archive_empty": original_result[
            "normalized_no_match_search_before_archive"
        ]["result_count"]
        == 0,
        "chat_backend_no_match_search_before_archive_empty": chat_result[
            "normalized_no_match_search_before_archive"
        ]["result_count"]
        == 0,
        "chat_backend_metadata_repair_removed_index": chat_result[
            "metadata_repair_action"
        ]["removed_index_count"]
        == 1,
        "chat_backend_metadata_repair_index_recreated": chat_metadata_index_repaired,
        "original_metadata_repair_read_contains_thread": original_result[
            "normalized_metadata_repair_read"
        ]["thread_id_matches"],
        "chat_backend_metadata_repair_read_contains_thread": chat_result[
            "normalized_metadata_repair_read"
        ]["thread_id_matches"],
        "original_metadata_repair_list_contains_thread": original_result[
            "normalized_metadata_repair_list"
        ]["contains_started_thread"],
        "chat_backend_metadata_repair_list_contains_thread": chat_result[
            "normalized_metadata_repair_list"
        ]["contains_started_thread"],
        "original_metadata_repair_search_contains_thread": original_result[
            "normalized_metadata_repair_search"
        ]["contains_started_thread"],
        "chat_backend_metadata_repair_search_contains_thread": chat_result[
            "normalized_metadata_repair_search"
        ]["contains_started_thread"],
        "original_active_list_after_archive_hides_thread": not original_result[
            "normalized_active_list_after_archive"
        ]["contains_started_thread"],
        "chat_backend_active_list_after_archive_hides_thread": not chat_result[
            "normalized_active_list_after_archive"
        ]["contains_started_thread"],
        "original_archived_list_after_archive_contains_thread": original_result[
            "normalized_archived_list_after_archive"
        ]["contains_started_thread"],
        "chat_backend_archived_list_after_archive_contains_thread": chat_result[
            "normalized_archived_list_after_archive"
        ]["contains_started_thread"],
        "original_active_search_after_archive_hides_thread": not original_result[
            "normalized_active_search_after_archive"
        ]["contains_started_thread"],
        "chat_backend_active_search_after_archive_hides_thread": not chat_result[
            "normalized_active_search_after_archive"
        ]["contains_started_thread"],
        "original_archived_search_after_archive_contains_thread": original_result[
            "normalized_archived_search_after_archive"
        ]["contains_started_thread"],
        "chat_backend_archived_search_after_archive_contains_thread": chat_result[
            "normalized_archived_search_after_archive"
        ]["contains_started_thread"],
        "original_active_list_after_unarchive_contains_thread": original_result[
            "normalized_active_list_after_unarchive"
        ]["contains_started_thread"],
        "chat_backend_active_list_after_unarchive_contains_thread": chat_result[
            "normalized_active_list_after_unarchive"
        ]["contains_started_thread"],
        "original_archived_list_after_unarchive_hides_thread": not original_result[
            "normalized_archived_list_after_unarchive"
        ]["contains_started_thread"],
        "chat_backend_archived_list_after_unarchive_hides_thread": not chat_result[
            "normalized_archived_list_after_unarchive"
        ]["contains_started_thread"],
        "original_delete_notification_seen": original_result[
            "normalized_delete_notification"
        ]["seen"],
        "chat_backend_delete_notification_seen": chat_result[
            "normalized_delete_notification"
        ]["seen"],
        "original_active_list_after_delete_hides_thread": not original_result[
            "normalized_active_list_after_delete"
        ]["contains_started_thread"],
        "chat_backend_active_list_after_delete_hides_thread": not chat_result[
            "normalized_active_list_after_delete"
        ]["contains_started_thread"],
        "original_archived_list_after_delete_hides_thread": not original_result[
            "normalized_archived_list_after_delete"
        ]["contains_started_thread"],
        "chat_backend_archived_list_after_delete_hides_thread": not chat_result[
            "normalized_archived_list_after_delete"
        ]["contains_started_thread"],
        "original_search_after_delete_hides_thread": not original_result[
            "normalized_search_after_delete"
        ]["contains_started_thread"],
        "chat_backend_search_after_delete_hides_thread": not chat_result[
            "normalized_search_after_delete"
        ]["contains_started_thread"],
        "original_read_after_delete_thread_not_loaded": original_result[
            "normalized_read_after_delete_error"
        ]["message_class"]
        == "thread_not_loaded",
        "chat_backend_read_after_delete_thread_not_loaded": chat_result[
            "normalized_read_after_delete_error"
        ]["message_class"]
        == "thread_not_loaded",
        "chat_package_pre_archive_ok": chat_package_lifecycle_state(
            chat_result["pre_archive_storage_summary"], expected_archived=False
        ),
        "chat_package_post_archive_archived": chat_package_lifecycle_state(
            chat_result["post_archive_storage_summary"], expected_archived=True
        ),
        "chat_package_post_unarchive_active": chat_package_lifecycle_state(
            chat_result["post_unarchive_storage_summary"], expected_archived=False
        ),
        "chat_package_removed_after_delete": chat_post_delete_package_count == 0,
        "original_rollout_removed_after_delete": len(original_post_delete_rollouts) == 0,
        "journal_line_count_matches_original_before_delete": (
            original_pre_lines is not None and original_pre_lines == chat_pre_journal_lines
        ),
        "original_rollout_line_count_before_delete": original_pre_lines,
        "chat_journal_line_count_before_delete": chat_pre_journal_lines,
        "original": {
            key: original_result[key] for key in comparison_keys
        },
        "chat_backend": {
            key: chat_result[key] for key in comparison_keys
        },
        "original_storage": {
            "pre_archive": original_result["pre_archive_storage_summary"],
            "post_archive": original_result["post_archive_storage_summary"],
            "post_unarchive": original_result["post_unarchive_storage_summary"],
            "post_delete": original_result["post_delete_storage_summary"],
        },
        "chat_package": {
            "pre_archive": chat_result["pre_archive_storage_summary"],
            "metadata_repair": chat_result["metadata_repair_storage_summary"],
            "post_archive": chat_result["post_archive_storage_summary"],
            "post_unarchive": chat_result["post_unarchive_storage_summary"],
            "post_delete": chat_result["post_delete_storage_summary"],
        },
        "not_yet_proven": [
            "relation-filter list parity",
            "pagination and cursor parity",
            "archive descendant ordering",
            "delete descendant ordering",
            "fork/rollback/compaction parity",
            "command execution parity",
            "crash recovery parity",
            "cold history parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/list-search-archive-response.json", original_result)
    write_json(output_dir / "chat-backend/list-search-archive-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server List/Search/Archive Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server list/search/archive/unarchive/delete source and upstream
tests were also read.

## Scope

This smoke covers one durable completed turn followed by:

```text
thread/list active
thread/search active
thread/search no-match
remove .chat metadata index
thread/read metadata repair
thread/list/search after metadata repair
thread/archive
thread/list active/archived
thread/search active/archived
thread/unarchive
thread/list active/archived
thread/read
thread/delete
thread/list active/archived
thread/search active
thread/read deleted id
```

It proves only a narrow L01/L03/L04/L05/L06/L07/L08 slice. It does not prove
relation filters, pagination/cursors, descendant archive/delete ordering, fork,
rollback, compaction, command execution, crash recovery, cold history, complete
data fidelity, or final user-indistinguishability.

## Result

- all normalized lifecycle/list/search fields equal: `{summary['all_normalized_lifecycle_fields_equal']}`
- original active list before archive contains thread: `{summary['original_active_list_before_archive_contains_thread']}`
- `.chat` active list before archive contains thread: `{summary['chat_backend_active_list_before_archive_contains_thread']}`
- original active search before archive contains thread: `{summary['original_active_search_before_archive_contains_thread']}`
- `.chat` active search before archive contains thread: `{summary['chat_backend_active_search_before_archive_contains_thread']}`
- original no-match search before archive is empty: `{summary['original_no_match_search_before_archive_empty']}`
- `.chat` no-match search before archive is empty: `{summary['chat_backend_no_match_search_before_archive_empty']}`
- `.chat` metadata repair removed index first: `{summary['chat_backend_metadata_repair_removed_index']}`
- `.chat` metadata repair recreated index: `{summary['chat_backend_metadata_repair_index_recreated']}`
- original metadata repair read/list/search contain thread: `{summary['original_metadata_repair_read_contains_thread']}` / `{summary['original_metadata_repair_list_contains_thread']}` / `{summary['original_metadata_repair_search_contains_thread']}`
- `.chat` metadata repair read/list/search contain thread: `{summary['chat_backend_metadata_repair_read_contains_thread']}` / `{summary['chat_backend_metadata_repair_list_contains_thread']}` / `{summary['chat_backend_metadata_repair_search_contains_thread']}`
- original active list after archive hides thread: `{summary['original_active_list_after_archive_hides_thread']}`
- `.chat` active list after archive hides thread: `{summary['chat_backend_active_list_after_archive_hides_thread']}`
- original archived list after archive contains thread: `{summary['original_archived_list_after_archive_contains_thread']}`
- `.chat` archived list after archive contains thread: `{summary['chat_backend_archived_list_after_archive_contains_thread']}`
- original archived search after archive contains thread: `{summary['original_archived_search_after_archive_contains_thread']}`
- `.chat` archived search after archive contains thread: `{summary['chat_backend_archived_search_after_archive_contains_thread']}`
- original active list after unarchive contains thread: `{summary['original_active_list_after_unarchive_contains_thread']}`
- `.chat` active list after unarchive contains thread: `{summary['chat_backend_active_list_after_unarchive_contains_thread']}`
- original delete notification seen: `{summary['original_delete_notification_seen']}`
- `.chat` delete notification seen: `{summary['chat_backend_delete_notification_seen']}`
- original read after delete reports thread_not_loaded: `{summary['original_read_after_delete_thread_not_loaded']}`
- `.chat` read after delete reports thread_not_loaded: `{summary['chat_backend_read_after_delete_thread_not_loaded']}`
- `.chat` package pre-archive active lifecycle ok: `{summary['chat_package_pre_archive_ok']}`
- `.chat` package post-archive archived lifecycle ok: `{summary['chat_package_post_archive_archived']}`
- `.chat` package post-unarchive active lifecycle ok: `{summary['chat_package_post_unarchive_active']}`
- `.chat` package removed after delete: `{summary['chat_package_removed_after_delete']}`
- original rollout removed after delete: `{summary['original_rollout_removed_after_delete']}`
- `.chat` journal line count matched original rollout before delete: `{summary['journal_line_count_matches_original_before_delete']}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/list-search-archive-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/list-search-archive-response.json
```

## Not Yet Proven

This smoke does not prove relation filters, pagination/cursors, descendant
archive/delete ordering, fork, rollback, compaction, command execution, crash
recovery, cold history, complete data fidelity, or final user-indistinguishability
under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_lifecycle_fields_equal"],
            summary["original_active_list_before_archive_contains_thread"],
            summary["chat_backend_active_list_before_archive_contains_thread"],
            summary["original_active_search_before_archive_contains_thread"],
            summary["chat_backend_active_search_before_archive_contains_thread"],
            summary["original_no_match_search_before_archive_empty"],
            summary["chat_backend_no_match_search_before_archive_empty"],
            summary["chat_backend_metadata_repair_removed_index"],
            summary["chat_backend_metadata_repair_index_recreated"],
            summary["original_metadata_repair_read_contains_thread"],
            summary["chat_backend_metadata_repair_read_contains_thread"],
            summary["original_metadata_repair_list_contains_thread"],
            summary["chat_backend_metadata_repair_list_contains_thread"],
            summary["original_metadata_repair_search_contains_thread"],
            summary["chat_backend_metadata_repair_search_contains_thread"],
            summary["original_active_list_after_archive_hides_thread"],
            summary["chat_backend_active_list_after_archive_hides_thread"],
            summary["original_archived_list_after_archive_contains_thread"],
            summary["chat_backend_archived_list_after_archive_contains_thread"],
            summary["original_active_search_after_archive_hides_thread"],
            summary["chat_backend_active_search_after_archive_hides_thread"],
            summary["original_archived_search_after_archive_contains_thread"],
            summary["chat_backend_archived_search_after_archive_contains_thread"],
            summary["original_active_list_after_unarchive_contains_thread"],
            summary["chat_backend_active_list_after_unarchive_contains_thread"],
            summary["original_archived_list_after_unarchive_hides_thread"],
            summary["chat_backend_archived_list_after_unarchive_hides_thread"],
            summary["original_delete_notification_seen"],
            summary["chat_backend_delete_notification_seen"],
            summary["original_active_list_after_delete_hides_thread"],
            summary["chat_backend_active_list_after_delete_hides_thread"],
            summary["original_archived_list_after_delete_hides_thread"],
            summary["chat_backend_archived_list_after_delete_hides_thread"],
            summary["original_search_after_delete_hides_thread"],
            summary["chat_backend_search_after_delete_hides_thread"],
            summary["original_read_after_delete_thread_not_loaded"],
            summary["chat_backend_read_after_delete_thread_not_loaded"],
            summary["chat_package_pre_archive_ok"],
            summary["chat_package_post_archive_archived"],
            summary["chat_package_post_unarchive_active"],
            summary["chat_package_removed_after_delete"],
            summary["original_rollout_removed_after_delete"],
            summary["journal_line_count_matches_original_before_delete"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
