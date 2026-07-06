#!/usr/bin/env python3
"""Run app-server fork parity smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers a narrow F01/F03 plus
`excludeTurns` slice after a two-turn durable source thread.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import hashlib
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


FIRST_USER_TEXT = "Fork parity source first turn."
SECOND_USER_TEXT = "Fork parity source second turn."


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_path_content(path_string: str | None) -> dict[str, Any]:
    if path_string is None:
        return {
            "path": None,
            "exists": False,
            "kind": None,
            "files": [],
        }
    path = pathlib.Path(path_string)
    if not path.exists():
        return {
            "path": str(path),
            "exists": False,
            "kind": None,
            "files": [],
        }
    if path.is_file():
        return {
            "path": str(path),
            "exists": True,
            "kind": "file",
            "files": [
                {
                    "relative_path": path.name,
                    "size": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            ],
        }
    files = []
    for file_path in sorted(item for item in path.rglob("*") if item.is_file()):
        files.append(
            {
                "relative_path": file_path.relative_to(path).as_posix(),
                "size": file_path.stat().st_size,
                "sha256": sha256_file(file_path),
            }
        )
    return {
        "path": str(path),
        "exists": True,
        "kind": "directory",
        "files": files,
    }


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "first_response_contains_first_user_text": response_input_contains(
            bodies[0] if len(bodies) > 0 else {}, FIRST_USER_TEXT
        ),
        "first_response_contains_second_user_text": response_input_contains(
            bodies[0] if len(bodies) > 0 else {}, SECOND_USER_TEXT
        ),
        "second_response_contains_first_user_text": response_input_contains(
            bodies[1] if len(bodies) > 1 else {}, FIRST_USER_TEXT
        ),
        "second_response_contains_second_user_text": response_input_contains(
            bodies[1] if len(bodies) > 1 else {}, SECOND_USER_TEXT
        ),
        "third_response_present": len(bodies) > 2,
    }


def send_initialize(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "msp-chat-validation",
                    "title": "MSP Chat Validation",
                    "version": "0.0.0",
                },
                "capabilities": {
                    "experimentalApi": True,
                    "requestAttestation": False,
                    "optOutNotificationMethods": ["account/rateLimits/updated"],
                    "mcpServerOpenaiFormElicitation": False,
                },
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    client.send({"jsonrpc": "2.0", "method": "initialized"})
    return response


def send_thread_start(
    client: JsonRpcClient,
    request_id: int,
    workspace: pathlib.Path,
) -> tuple[str | None, dict[str, Any]]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/start",
            "params": {
                "cwd": str(workspace),
                "ephemeral": False,
                "historyMode": "legacy",
                "model": "mock-model",
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    thread_id = ((response.get("result") or {}).get("thread") or {}).get("id")
    return thread_id, response


def send_turn_start(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    client_user_message_id: str,
    text: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": client_user_message_id,
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
    response = client.receive_until_response(request_id, timeout_seconds=30)
    notifications: list[dict[str, Any]] = []
    notification_errors: list[str] = []
    if "error" not in response:
        for method, timeout_seconds in [
            ("turn/started", 30),
            ("turn/completed", 60),
        ]:
            try:
                notifications.append(
                    client.receive_until_method(method, timeout_seconds=timeout_seconds)
                )
            except TimeoutError as exc:
                notification_errors.append(str(exc))
                break
    return {
        "response": response,
        "notifications": notifications,
        "notification_errors": notification_errors,
    }


def send_thread_read(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/read",
            "params": {
                "threadId": thread_id,
                "includeTurns": True,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_list(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": {
                "limit": 10,
                "modelProviders": [],
                "archived": False,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_fork(
    client: JsonRpcClient,
    request_id: int,
    source_thread_id: str | None,
    exclude_turns: bool = False,
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


def thread_from_response(response: dict[str, Any]) -> dict[str, Any]:
    return (response.get("result") or {}).get("thread") or {}


def normalize_thread_response(
    response: dict[str, Any],
    expected_thread_id: str | None,
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
    source_thread_id: str | None,
    source_path: str | None,
    expect_turns: bool,
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
        "path_present": thread_path is not None,
        "path_differs_from_source": thread_path is not None and thread_path != source_path,
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
        "expected_turn_presence": bool(turns) == expect_turns,
        "thread_started_seen": fork_result.get("thread_started_notification") is not None,
        "started_thread_id_matches": started_thread.get("id") == thread.get("id"),
        "started_thread_turn_count": len(started_thread.get("turns") or []),
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    expected_thread_ids: list[str | None],
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    ids = {thread.get("id") for thread in threads}
    expected = [thread_id for thread_id in expected_thread_ids if thread_id is not None]
    return {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_all_expected_threads": all(thread_id in ids for thread_id in expected),
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
        "expected_thread_count": len(expected),
    }


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def package_line_counts(summary: dict[str, Any]) -> list[int]:
    return sorted(
        package.get("journal_line_count")
        for package in (summary.get("packages") or [])
        if package.get("journal_line_count") is not None
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

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            source_thread_id, thread_start_response = send_thread_start(
                client, 2, workspace
            )
            first_turn = send_turn_start(
                client,
                3,
                source_thread_id,
                "client-user-message-fork-source-1",
                FIRST_USER_TEXT,
            )
            second_turn = send_turn_start(
                client,
                4,
                source_thread_id,
                "client-user-message-fork-source-2",
                SECOND_USER_TEXT,
            )
            source_read_before_fork_response = send_thread_read(
                client, 5, source_thread_id
            )
            source_thread = thread_from_response(source_read_before_fork_response)
            source_path = source_thread.get("path")
            source_snapshot_before_fork = snapshot_path_content(source_path)

            pre_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            persistent_fork = send_thread_fork(
                client,
                6,
                source_thread_id,
                exclude_turns=False,
            )
            persistent_fork_thread = thread_from_response(persistent_fork["response"])
            persistent_fork_thread_id = persistent_fork_thread.get("id")
            persistent_fork_read_response = send_thread_read(
                client,
                7,
                persistent_fork_thread_id,
            )

            source_snapshot_after_persistent_fork = snapshot_path_content(source_path)
            post_persistent_fork_storage = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            exclude_turns_fork = send_thread_fork(
                client,
                8,
                source_thread_id,
                exclude_turns=True,
            )
            exclude_turns_thread = thread_from_response(exclude_turns_fork["response"])
            exclude_turns_thread_id = exclude_turns_thread.get("id")
            source_snapshot_after_exclude_turns_fork = snapshot_path_content(source_path)
            final_list_response = send_thread_list(client, 9)

            post_exclude_turns_fork_storage = (
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
        "first_turn": first_turn,
        "second_turn": second_turn,
        "source_read_before_fork_response": source_read_before_fork_response,
        "persistent_fork": persistent_fork,
        "persistent_fork_read_response": persistent_fork_read_response,
        "exclude_turns_fork": exclude_turns_fork,
        "final_list_response": final_list_response,
        "normalized_source_before_fork": normalize_thread_response(
            source_read_before_fork_response,
            source_thread_id,
        ),
        "normalized_persistent_fork": normalize_fork_response(
            persistent_fork,
            source_thread_id,
            source_path,
            expect_turns=True,
        ),
        "normalized_persistent_fork_read": normalize_thread_response(
            persistent_fork_read_response,
            persistent_fork_thread_id,
        ),
        "normalized_exclude_turns_fork": normalize_fork_response(
            exclude_turns_fork,
            source_thread_id,
            source_path,
            expect_turns=False,
        ),
        "normalized_final_list": normalize_thread_list_response(
            final_list_response,
            [source_thread_id, persistent_fork_thread_id, exclude_turns_thread_id],
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-fork-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
        "normalized_final_list",
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

    original_post_persistent_line_counts = sorted(
        item.get("line_count")
        for item in (
            original_result["post_persistent_fork_storage_summary"].get("rollouts") or []
        )
        if item.get("line_count") is not None
    )
    chat_post_persistent_line_counts = package_line_counts(
        chat_result["post_persistent_fork_storage_summary"]
    )

    original_post_exclude_line_counts = sorted(
        item.get("line_count")
        for item in (
            original_result["post_exclude_turns_fork_storage_summary"].get("rollouts") or []
        )
        if item.get("line_count") is not None
    )
    chat_post_exclude_line_counts = package_line_counts(
        chat_result["post_exclude_turns_fork_storage_summary"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-fork-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparisons,
        "all_normalized_fork_fields_equal": all(comparisons.values()),
        "original_source_has_two_turns": original_result["normalized_source_before_fork"][
            "turn_count"
        ]
        == 2,
        "chat_backend_source_has_two_turns": chat_result["normalized_source_before_fork"][
            "turn_count"
        ]
        == 2,
        "original_persistent_fork_has_history": original_result[
            "normalized_persistent_fork"
        ]["turn_count"]
        == 2,
        "chat_backend_persistent_fork_has_history": chat_result[
            "normalized_persistent_fork"
        ]["turn_count"]
        == 2,
        "original_persistent_fork_read_has_history": original_result[
            "normalized_persistent_fork_read"
        ]["turn_count"]
        == 2,
        "chat_backend_persistent_fork_read_has_history": chat_result[
            "normalized_persistent_fork_read"
        ]["turn_count"]
        == 2,
        "original_exclude_turns_fork_omits_history": original_result[
            "normalized_exclude_turns_fork"
        ]["turn_count"]
        == 0,
        "chat_backend_exclude_turns_fork_omits_history": chat_result[
            "normalized_exclude_turns_fork"
        ]["turn_count"]
        == 0,
        "original_source_unchanged_after_forks": original_result[
            "source_snapshot_unchanged_after_exclude_turns_fork"
        ],
        "chat_backend_source_unchanged_after_forks": chat_result[
            "source_snapshot_unchanged_after_exclude_turns_fork"
        ],
        "original_final_list_contains_source_and_forks": original_result[
            "normalized_final_list"
        ]["contains_all_expected_threads"],
        "chat_backend_final_list_contains_source_and_forks": chat_result[
            "normalized_final_list"
        ]["contains_all_expected_threads"],
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
            "fork by lastTurnId truncation parity",
            "path-addressed fork parity",
            "ephemeral pathless fork parity",
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

    write_json(output_dir / "original/fork-response.json", original_result)
    write_json(output_dir / "chat-backend/fork-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Fork Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server `thread/fork` source, protocol definitions, and upstream
fork tests were also read.

## Scope

This smoke covers:

```text
thread/start
turn/start x2
thread/read source includeTurns=true
thread/fork includeTurns=true
thread/read persistent fork includeTurns=true
thread/fork excludeTurns=true
thread/list active
```

It proves only a narrow F01/F03 plus `excludeTurns` slice. It does not prove
lastTurnId truncation, path-addressed fork, ephemeral pathless fork, title/name
inheritance, token usage replay ordering, interrupted active-turn fork,
rollback, compaction, command execution, crash recovery, cold history, complete
data fidelity, or final user-indistinguishability.

## Result

- all normalized fork fields equal: `{summary['all_normalized_fork_fields_equal']}`
- original source has two turns: `{summary['original_source_has_two_turns']}`
- `.chat` source has two turns: `{summary['chat_backend_source_has_two_turns']}`
- original persistent fork has copied history: `{summary['original_persistent_fork_has_history']}`
- `.chat` persistent fork has copied history: `{summary['chat_backend_persistent_fork_has_history']}`
- original persistent fork read has copied history: `{summary['original_persistent_fork_read_has_history']}`
- `.chat` persistent fork read has copied history: `{summary['chat_backend_persistent_fork_read_has_history']}`
- original excludeTurns fork omits history: `{summary['original_exclude_turns_fork_omits_history']}`
- `.chat` excludeTurns fork omits history: `{summary['chat_backend_exclude_turns_fork_omits_history']}`
- original source content unchanged after forks: `{summary['original_source_unchanged_after_forks']}`
- `.chat` source package unchanged after forks: `{summary['chat_backend_source_unchanged_after_forks']}`
- original final list contains source and forks: `{summary['original_final_list_contains_source_and_forks']}`
- `.chat` final list contains source and forks: `{summary['chat_backend_final_list_contains_source_and_forks']}`
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
{output_dir.relative_to(VALIDATION_DIR)}/original/fork-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/fork-response.json
```

## Not Yet Proven

This smoke does not prove lastTurnId truncation, path-addressed fork, ephemeral
pathless fork, forked title/name inheritance, fork token usage replay ordering,
interrupted active-turn fork, rollback, compaction/context restore, command
execution, crash recovery, cold history, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_fork_fields_equal"],
            summary["original_source_has_two_turns"],
            summary["chat_backend_source_has_two_turns"],
            summary["original_persistent_fork_has_history"],
            summary["chat_backend_persistent_fork_has_history"],
            summary["original_persistent_fork_read_has_history"],
            summary["chat_backend_persistent_fork_read_has_history"],
            summary["original_exclude_turns_fork_omits_history"],
            summary["chat_backend_exclude_turns_fork_omits_history"],
            summary["original_source_unchanged_after_forks"],
            summary["chat_backend_source_unchanged_after_forks"],
            summary["original_final_list_contains_source_and_forks"],
            summary["chat_backend_final_list_contains_source_and_forks"],
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
