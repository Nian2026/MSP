#!/usr/bin/env python3
"""Run a cold-resume app-server smoke for original vs `.chat` backend Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. Each tree completes one durable turn, shuts down the app-server process,
starts a fresh app-server process against the same CODEX_HOME, resumes the
thread, and starts a second turn. The mock Responses API lets the script check
that the second model request receives prior conversation context.
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
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    summarize_path_observation,
    utc_now_iso,
    write_json,
    write_mock_config,
)


FIRST_USER_TEXT = "Persist this cold resume validation turn."
SECOND_USER_TEXT = "Continue after cold resume with the prior context."
ASSISTANT_TEXT = "Cold resume answer from mock model."


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
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "first_response_model": first_body.get("model"),
        "second_response_model": second_body.get("model"),
        "first_response_input_contains_first_user_text": response_input_contains(
            first_body, FIRST_USER_TEXT
        ),
        "first_response_input_contains_second_user_text": response_input_contains(
            first_body, SECOND_USER_TEXT
        ),
        "second_response_input_contains_first_user_text": response_input_contains(
            second_body, FIRST_USER_TEXT
        ),
        "second_response_input_contains_first_assistant_text": response_input_contains(
            second_body, ASSISTANT_TEXT
        ),
        "second_response_input_contains_second_user_text": response_input_contains(
            second_body, SECOND_USER_TEXT
        ),
    }


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
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
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [
            len(turn.get("items") or [])
            for turn in turns
        ],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_assistant_text": ASSISTANT_TEXT in serialized_turns,
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    started_thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result", {})
    threads = result.get("data") or []
    listed_thread = None
    if started_thread_id is not None:
        listed_thread = next(
            (thread for thread in threads if thread.get("id") == started_thread_id),
            None,
        )
    if listed_thread is None and threads:
        listed_thread = threads[0]

    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_started_thread": listed_thread is not None
        and listed_thread.get("id") == started_thread_id,
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }
    if listed_thread is not None:
        normalized.update(
            {
                "listed_thread_ephemeral": listed_thread.get("ephemeral"),
                "listed_thread_model_provider": listed_thread.get("modelProvider"),
                "listed_thread_model": listed_thread.get("model"),
                "listed_thread_name": listed_thread.get("name"),
                "listed_thread_preview": listed_thread.get("preview"),
                "listed_thread_source": listed_thread.get("source"),
                "listed_thread_status_type": status_type(listed_thread.get("status")),
                "listed_thread_turn_count": len(listed_thread.get("turns") or []),
            }
        )
    return normalized


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


def send_thread_resume(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/resume",
            "params": {
                "threadId": thread_id,
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

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                first_client, 2, workspace
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                started_thread_id,
                "client-user-message-cold-resume-1",
                FIRST_USER_TEXT,
            )
            first_thread_read_response = send_thread_read(first_client, 4, started_thread_id)
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            thread_resume_response = send_thread_resume(second_client, 102, started_thread_id)
            resumed_thread_id = (
                ((thread_resume_response.get("result") or {}).get("thread") or {}).get("id")
                or started_thread_id
            )
            post_resume_thread_read_response = send_thread_read(
                second_client, 103, resumed_thread_id
            )
            second_turn_start_response = send_turn_start(
                second_client,
                104,
                resumed_thread_id,
                "client-user-message-cold-resume-2",
                SECOND_USER_TEXT,
            )
            final_thread_read_response = send_thread_read(second_client, 105, resumed_thread_id)
            final_thread_list_response = send_thread_list(second_client, 106)
        finally:
            second_stderr = second_client.close()

        result = {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "first_process": {
                "command": first_client.command,
                "initialize_response": first_initialize_response,
                "thread_start_response": thread_start_response,
                "turn_start_response": first_turn_start_response,
                "thread_read_response": first_thread_read_response,
                "jsonrpc_sent": first_client.sent,
                "jsonrpc_received": first_client.received,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "command": second_client.command,
                "initialize_response": second_initialize_response,
                "thread_resume_response": thread_resume_response,
                "post_resume_thread_read_response": post_resume_thread_read_response,
                "turn_start_response": second_turn_start_response,
                "final_thread_read_response": final_thread_read_response,
                "final_thread_list_response": final_thread_list_response,
                "jsonrpc_sent": second_client.sent,
                "jsonrpc_received": second_client.received,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "normalized_resume": normalize_thread_response(thread_resume_response),
            "normalized_post_resume_read": normalize_thread_response(
                post_resume_thread_read_response
            ),
            "normalized_final_read": normalize_thread_response(final_thread_read_response),
            "normalized_final_list": normalize_thread_list_response(
                final_thread_list_response, started_thread_id
            ),
            "thread_read_path_observations": {
                "first_read": summarize_path_observation(
                    first_thread_read_response, started_thread_id
                ),
                "post_resume_read": summarize_path_observation(
                    post_resume_thread_read_response, started_thread_id
                ),
                "final_read": summarize_path_observation(
                    final_thread_read_response, started_thread_id
                ),
            },
        }
        if tree_name == "chat-backend":
            result["chat_package_summary"] = summarize_chat_packages(chat_root)
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
        return result


def original_line_count(summary: dict[str, Any]) -> int | None:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return None
    return rollouts[0].get("line_count")


def chat_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("journal_line_count")


def chat_timeline_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("timeline_line_count")


def chat_package_resume_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 4
        and package.get("journal_line_count", 0) >= 4
        and "runtime_context_snapshot" in event_types
        and "message" in event_types
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-cold-resume-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_resume = original_result["normalized_resume"]
    chat_resume = chat_result["normalized_resume"]
    original_post_resume_read = original_result["normalized_post_resume_read"]
    chat_post_resume_read = chat_result["normalized_post_resume_read"]
    original_final_read = original_result["normalized_final_read"]
    chat_final_read = chat_result["normalized_final_read"]
    original_final_list = original_result["normalized_final_list"]
    chat_final_list = chat_result["normalized_final_list"]

    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_lines = original_line_count(original_storage)
    chat_journal_lines = chat_journal_line_count(chat_package)
    chat_timeline_lines = chat_timeline_line_count(chat_package)
    journal_line_count_matches_original = (
        original_lines is not None and original_lines == chat_journal_lines
    )

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    mock_second_turn_context_ok = all(
        [
            original_mock["response_request_count"] == 2,
            chat_mock["response_request_count"] == 2,
            original_mock["second_response_input_contains_first_user_text"],
            chat_mock["second_response_input_contains_first_user_text"],
            original_mock["second_response_input_contains_first_assistant_text"],
            chat_mock["second_response_input_contains_first_assistant_text"],
            original_mock["second_response_input_contains_second_user_text"],
            chat_mock["second_response_input_contains_second_user_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-resume-smoke",
        "binary_checks": binary_checks,
        "original_resume_exit_ok": "result"
        in original_result["second_process"]["thread_resume_response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_result["second_process"]["thread_resume_response"],
        "original_second_turn_exit_ok": "result"
        in original_result["second_process"]["turn_start_response"]["response"],
        "chat_backend_second_turn_exit_ok": "result"
        in chat_result["second_process"]["turn_start_response"]["response"],
        "original_second_turn_notifications_ok": not original_result["second_process"][
            "turn_start_response"
        ]["notification_errors"],
        "chat_backend_second_turn_notifications_ok": not chat_result["second_process"][
            "turn_start_response"
        ]["notification_errors"],
        "normalized_resume_equal": original_resume == chat_resume,
        "normalized_post_resume_read_equal": (
            original_post_resume_read == chat_post_resume_read
        ),
        "normalized_final_read_equal": original_final_read == chat_final_read,
        "normalized_final_list_equal": original_final_list == chat_final_list,
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_second_turn_context_ok": mock_second_turn_context_ok,
        "chat_package_resume_ok": chat_package_resume_ok(chat_package),
        "journal_line_count_matches_original": journal_line_count_matches_original,
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_resume": original_resume,
        "chat_backend_normalized_resume": chat_resume,
        "original_normalized_post_resume_read": original_post_resume_read,
        "chat_backend_normalized_post_resume_read": chat_post_resume_read,
        "original_normalized_final_read": original_final_read,
        "chat_backend_normalized_final_read": chat_final_read,
        "original_normalized_final_list": original_final_list,
        "chat_backend_normalized_final_list": chat_final_list,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observations"],
            "chat-backend": chat_result["thread_read_path_observations"],
        },
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "running rejoin parity",
            "fork/rollback/compaction parity",
            "command/tool execution parity",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/cold-resume-response.json", original_result)
    write_json(output_dir / "chat-backend/cold-resume-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Cold Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server resume protocol code and tests were also read.

## Scope

This smoke covers one completed durable turn, process shutdown, a fresh
app-server process, `thread/resume`, `thread/read includeTurns=true`, a second
`turn/start`, and final `thread/read` / `thread/list`.

It proves only a cold-resume slice. It does not prove running rejoin, fork,
rollback, compaction, command/tool execution, archive/search/delete, crash
recovery, complete data fidelity, or user-indistinguishability.

## Result

- original `thread/resume` response succeeded: `{summary['original_resume_exit_ok']}`
- `.chat` backend `thread/resume` response succeeded: `{summary['chat_backend_resume_exit_ok']}`
- original second `turn/start` response succeeded: `{summary['original_second_turn_exit_ok']}`
- `.chat` backend second `turn/start` response succeeded: `{summary['chat_backend_second_turn_exit_ok']}`
- original second turn notifications completed: `{summary['original_second_turn_notifications_ok']}`
- `.chat` backend second turn notifications completed: `{summary['chat_backend_second_turn_notifications_ok']}`
- normalized original vs `.chat` `thread/resume` fields equal: `{summary['normalized_resume_equal']}`
- normalized original vs `.chat` post-resume `thread/read` fields equal: `{summary['normalized_post_resume_read_equal']}`
- normalized original vs `.chat` final `thread/read` fields equal: `{summary['normalized_final_read_equal']}`
- normalized original vs `.chat` final `thread/list` fields equal: `{summary['normalized_final_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- second model request included prior user/assistant context and new user text: `{summary['mock_second_turn_context_ok']}`
- durable `.chat` package remained readable after cold resume: `{summary['chat_package_resume_ok']}`
- `.chat` journal line count matched original rollout line count: `{summary['journal_line_count_matches_original']}`

## Normalized Resume

```json
{json.dumps({'original': original_resume, 'chat-backend': chat_resume}, indent=2, sort_keys=True)}
```

## Final Thread Read

```json
{json.dumps({'original': original_final_read, 'chat-backend': chat_final_read}, indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat-backend': chat_mock}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cold-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-resume-response.json
```

## Not Yet Proven

This smoke does not prove running rejoin, fork, rollback, compaction,
command/tool execution, archive/search/delete, crash recovery, complete data
fidelity, or user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_second_turn_exit_ok"],
            summary["chat_backend_second_turn_exit_ok"],
            summary["original_second_turn_notifications_ok"],
            summary["chat_backend_second_turn_notifications_ok"],
            summary["normalized_resume_equal"],
            summary["normalized_post_resume_read_equal"],
            summary["normalized_final_read_equal"],
            summary["normalized_final_list_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_second_turn_context_ok"],
            summary["chat_package_resume_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
