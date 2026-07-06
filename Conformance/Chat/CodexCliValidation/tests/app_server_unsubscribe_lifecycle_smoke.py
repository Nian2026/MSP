#!/usr/bin/env python3
"""Run an unsubscribe lifecycle app-server smoke for original vs `.chat` Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. It covers the lifecycle behavior adjacent to the pending unload race:
after a durable turn, `thread/unsubscribe` should detach the current connection
without immediately unloading the thread, `thread/loaded/list` should still see
the loaded thread, and `thread/resume` should reattach before the idle unload
delay fires.

It does not directly prove R06 pending unload race because upstream Codex uses a
30 minute hard-coded idle unload delay and exposes no runtime config to shorten
that delay for the app-server binary.
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
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)


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
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": "client-user-message-unsubscribe-lifecycle",
                "input": [
                    {
                        "type": "text",
                        "text": USER_TEXT,
                        "textElements": [],
                    }
                ],
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_unsubscribe(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/unsubscribe",
            "params": {
                "threadId": thread_id,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_loaded_list(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/loaded/list",
            "params": {},
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_resume(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    workspace: pathlib.Path,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/resume",
            "params": {
                "threadId": thread_id,
                "cwd": str(workspace),
                "initialTurnsPage": {},
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


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


def receive_thread_closed_with_short_timeout(client: JsonRpcClient) -> dict[str, Any] | None:
    try:
        return client.receive_until_method("thread/closed", timeout_seconds=1)
    except TimeoutError:
        return None


def normalize_unsubscribe_response(response: dict[str, Any]) -> dict[str, Any]:
    result = response.get("result") or {}
    return {
        "has_error": "error" in response,
        "status": result.get("status"),
    }


def normalize_loaded_list_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    return {
        "has_error": "error" in response,
        "thread_count": len(data),
        "contains_started_thread": thread_id in data,
        "next_cursor_present": result.get("nextCursor") is not None,
    }


def normalize_thread_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_id_matches": thread_id is not None and thread.get("id") == thread_id,
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
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_user_text": USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def chat_package_unsubscribe_lifecycle_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 5
        and package.get("journal_line_count", 0) >= 5
        and "runtime_context_snapshot" in event_types
        and "message" in event_types
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
            unsubscribe_response = send_thread_unsubscribe(
                client, 4, started_thread_id
            )
            early_thread_closed_notification = receive_thread_closed_with_short_timeout(
                client
            )
            loaded_list_after_unsubscribe_response = send_thread_loaded_list(client, 5)
            resume_after_unsubscribe_response = send_thread_resume(
                client, 6, started_thread_id, workspace
            )
            final_thread_read_response = send_thread_read(client, 7, started_thread_id)
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
            "unsubscribe_response": unsubscribe_response,
            "early_thread_closed_notification": early_thread_closed_notification,
            "loaded_list_after_unsubscribe_response": loaded_list_after_unsubscribe_response,
            "resume_after_unsubscribe_response": resume_after_unsubscribe_response,
            "final_thread_read_response": final_thread_read_response,
            "normalized_unsubscribe": normalize_unsubscribe_response(
                unsubscribe_response
            ),
            "normalized_loaded_list_after_unsubscribe": normalize_loaded_list_response(
                loaded_list_after_unsubscribe_response, started_thread_id
            ),
            "normalized_resume_after_unsubscribe": normalize_thread_response(
                resume_after_unsubscribe_response, started_thread_id
            ),
            "normalized_final_read": normalize_thread_response(
                final_thread_read_response, started_thread_id
            ),
            "thread_closed_seen_within_one_second": (
                early_thread_closed_notification is not None
            ),
            "jsonrpc_sent": client.sent,
            "jsonrpc_received": client.received,
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }
        if tree_name == "chat-backend":
            result["chat_package_summary"] = summarize_chat_packages(chat_root)
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-unsubscribe-lifecycle-smoke-"
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

    original_unsubscribe = original_result["normalized_unsubscribe"]
    chat_unsubscribe = chat_result["normalized_unsubscribe"]
    original_loaded = original_result["normalized_loaded_list_after_unsubscribe"]
    chat_loaded = chat_result["normalized_loaded_list_after_unsubscribe"]
    original_resume = original_result["normalized_resume_after_unsubscribe"]
    chat_resume = chat_result["normalized_resume_after_unsubscribe"]
    original_final_read = original_result["normalized_final_read"]
    chat_final_read = chat_result["normalized_final_read"]
    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_lines = line_count(original_storage, "rollouts")
    chat_packages = chat_package.get("packages") or []
    chat_journal_lines = (
        chat_packages[0].get("journal_line_count") if len(chat_packages) == 1 else None
    )
    chat_timeline_lines = (
        chat_packages[0].get("timeline_line_count") if len(chat_packages) == 1 else None
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-unsubscribe-lifecycle-smoke",
        "binary_checks": binary_checks,
        "original_unsubscribe_exit_ok": "result"
        in original_result["unsubscribe_response"],
        "chat_backend_unsubscribe_exit_ok": "result"
        in chat_result["unsubscribe_response"],
        "original_no_early_thread_closed": not original_result[
            "thread_closed_seen_within_one_second"
        ],
        "chat_backend_no_early_thread_closed": not chat_result[
            "thread_closed_seen_within_one_second"
        ],
        "original_loaded_list_exit_ok": "result"
        in original_result["loaded_list_after_unsubscribe_response"],
        "chat_backend_loaded_list_exit_ok": "result"
        in chat_result["loaded_list_after_unsubscribe_response"],
        "original_resume_after_unsubscribe_exit_ok": "result"
        in original_result["resume_after_unsubscribe_response"],
        "chat_backend_resume_after_unsubscribe_exit_ok": "result"
        in chat_result["resume_after_unsubscribe_response"],
        "original_final_read_exit_ok": "result"
        in original_result["final_thread_read_response"],
        "chat_backend_final_read_exit_ok": "result"
        in chat_result["final_thread_read_response"],
        "normalized_unsubscribe_equal": original_unsubscribe == chat_unsubscribe,
        "normalized_loaded_list_after_unsubscribe_equal": original_loaded == chat_loaded,
        "normalized_resume_after_unsubscribe_equal": original_resume == chat_resume,
        "normalized_final_read_equal": original_final_read == chat_final_read,
        "original_unsubscribe_status_unsubscribed": (
            original_unsubscribe["status"] == "unsubscribed"
        ),
        "chat_backend_unsubscribe_status_unsubscribed": (
            chat_unsubscribe["status"] == "unsubscribed"
        ),
        "original_loaded_list_contains_thread_after_unsubscribe": original_loaded[
            "contains_started_thread"
        ],
        "chat_backend_loaded_list_contains_thread_after_unsubscribe": chat_loaded[
            "contains_started_thread"
        ],
        "original_resume_after_unsubscribe_thread_idle": (
            original_resume["thread_status_type"] == "idle"
        ),
        "chat_backend_resume_after_unsubscribe_thread_idle": (
            chat_resume["thread_status_type"] == "idle"
        ),
        "chat_package_unsubscribe_lifecycle_ok": chat_package_unsubscribe_lifecycle_ok(
            chat_package
        ),
        "journal_line_count_matches_original": (
            original_lines is not None and original_lines == chat_journal_lines
        ),
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_unsubscribe": original_unsubscribe,
        "chat_backend_normalized_unsubscribe": chat_unsubscribe,
        "original_normalized_loaded_list_after_unsubscribe": original_loaded,
        "chat_backend_normalized_loaded_list_after_unsubscribe": chat_loaded,
        "original_normalized_resume_after_unsubscribe": original_resume,
        "chat_backend_normalized_resume_after_unsubscribe": chat_resume,
        "original_normalized_final_read": original_final_read,
        "chat_backend_normalized_final_read": chat_final_read,
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "r06_direct_pending_unload_race_not_proven": True,
        "r06_direct_blocker": (
            "upstream app-server uses a hard-coded 30 minute THREAD_UNLOADING_DELAY "
            "and exposes no runtime config to shorten it for binary parity smoke tests"
        ),
        "not_yet_proven": [
            "R06 direct pending unload race after idle unload delay fires",
            "fork/rollback/compaction parity",
            "command/tool execution parity",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/unsubscribe-lifecycle-response.json", original_result)
    write_json(output_dir / "chat-backend/unsubscribe-lifecycle-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Unsubscribe Lifecycle Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server lifecycle, unsubscribe, and resume code was also read.

## Scope

This smoke covers a durable completed turn, `thread/unsubscribe`, absence of an
immediate `thread/closed` notification, `thread/loaded/list` before the idle
unload delay fires, `thread/resume` after unsubscribe, and final `thread/read`.

It proves the unsubscribe-before-idle-unload lifecycle slice adjacent to R06.
It does not directly prove R06 pending unload race because upstream Codex uses a
hard-coded 30 minute `THREAD_UNLOADING_DELAY` and exposes no runtime
configuration to shorten that delay for a source-preserving binary parity smoke.

## Result

- original `thread/unsubscribe` response succeeded: `{summary['original_unsubscribe_exit_ok']}`
- `.chat` backend `thread/unsubscribe` response succeeded: `{summary['chat_backend_unsubscribe_exit_ok']}`
- normalized unsubscribe fields equal: `{summary['normalized_unsubscribe_equal']}`
- original unsubscribe status was `unsubscribed`: `{summary['original_unsubscribe_status_unsubscribed']}`
- `.chat` backend unsubscribe status was `unsubscribed`: `{summary['chat_backend_unsubscribe_status_unsubscribed']}`
- original emitted no early `thread/closed`: `{summary['original_no_early_thread_closed']}`
- `.chat` backend emitted no early `thread/closed`: `{summary['chat_backend_no_early_thread_closed']}`
- original loaded list still contained the thread: `{summary['original_loaded_list_contains_thread_after_unsubscribe']}`
- `.chat` backend loaded list still contained the thread: `{summary['chat_backend_loaded_list_contains_thread_after_unsubscribe']}`
- normalized loaded-list fields equal: `{summary['normalized_loaded_list_after_unsubscribe_equal']}`
- original resume after unsubscribe returned idle thread: `{summary['original_resume_after_unsubscribe_thread_idle']}`
- `.chat` backend resume after unsubscribe returned idle thread: `{summary['chat_backend_resume_after_unsubscribe_thread_idle']}`
- normalized resume-after-unsubscribe fields equal: `{summary['normalized_resume_after_unsubscribe_equal']}`
- normalized final `thread/read` fields equal: `{summary['normalized_final_read_equal']}`
- durable `.chat` package remained readable after unsubscribe/resume: `{summary['chat_package_unsubscribe_lifecycle_ok']}`
- `.chat` journal line count matched original rollout line count: `{summary['journal_line_count_matches_original']}`

## R06 Direct Gap

Direct pending-unload race coverage still requires a way to place the app-server
thread id into `pending_thread_unloads` without waiting 30 minutes in wall-clock
time or modifying the original vendored source. This pass found no runtime
configuration or environment override for `THREAD_UNLOADING_DELAY`.

## Normalized Unsubscribe

```json
{json.dumps({'original': original_unsubscribe, 'chat-backend': chat_unsubscribe}, indent=2, sort_keys=True)}
```

## Normalized Loaded List After Unsubscribe

```json
{json.dumps({'original': original_loaded, 'chat-backend': chat_loaded}, indent=2, sort_keys=True)}
```

## Normalized Resume After Unsubscribe

```json
{json.dumps({'original': original_resume, 'chat-backend': chat_resume}, indent=2, sort_keys=True)}
```

## Final Thread Read

```json
{json.dumps({'original': original_final_read, 'chat-backend': chat_final_read}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/unsubscribe-lifecycle-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/unsubscribe-lifecycle-response.json
```

## Not Yet Proven

This smoke does not prove direct R06 pending unload race after the idle unload
delay fires, fork, rollback, compaction, command/tool execution,
archive/search/delete, crash recovery, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_unsubscribe_exit_ok"],
            summary["chat_backend_unsubscribe_exit_ok"],
            summary["original_no_early_thread_closed"],
            summary["chat_backend_no_early_thread_closed"],
            summary["original_loaded_list_exit_ok"],
            summary["chat_backend_loaded_list_exit_ok"],
            summary["original_resume_after_unsubscribe_exit_ok"],
            summary["chat_backend_resume_after_unsubscribe_exit_ok"],
            summary["original_final_read_exit_ok"],
            summary["chat_backend_final_read_exit_ok"],
            summary["normalized_unsubscribe_equal"],
            summary["normalized_loaded_list_after_unsubscribe_equal"],
            summary["normalized_resume_after_unsubscribe_equal"],
            summary["normalized_final_read_equal"],
            summary["original_unsubscribe_status_unsubscribed"],
            summary["chat_backend_unsubscribe_status_unsubscribed"],
            summary["original_loaded_list_contains_thread_after_unsubscribe"],
            summary["chat_backend_loaded_list_contains_thread_after_unsubscribe"],
            summary["original_resume_after_unsubscribe_thread_idle"],
            summary["chat_backend_resume_after_unsubscribe_thread_idle"],
            summary["chat_package_unsubscribe_lifecycle_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
