#!/usr/bin/env python3
"""Run a redacted thread/resume payload smoke for original vs `.chat` Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. Each tree first persists a turn containing an image-generation item, then
restarts the app-server as a remote ChatGPT client and calls `thread/resume`.
Remote resume responses should remove image-generation payloads without
changing persisted history or ordinary `thread/read` behavior.
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
    utc_now_iso,
    write_json,
    write_mock_config,
)


USER_TEXT = "Create image generation history for redacted resume validation."
ASSISTANT_TEXT = "Image generation turn completed."
IMAGE_GENERATION_ID = "ig-redacted-resume-smoke"
IMAGE_REVISED_PROMPT = "A tiny blue square for resume redaction validation."
IMAGE_RESULT = "Zm9v"
REMOTE_CLIENT_NAME = "codex_chatgpt_ios_remote"
NORMAL_CLIENT_NAME = "msp-chat-validation"


def sse_image_generation_response(response_id: str, message_id: str) -> bytes:
    events = [
        {
            "type": "response.created",
            "response": {
                "id": response_id,
            },
        },
        {
            "type": "response.output_item.done",
            "item": {
                "id": IMAGE_GENERATION_ID,
                "type": "image_generation_call",
                "status": "completed",
                "revised_prompt": IMAGE_REVISED_PROMPT,
                "result": IMAGE_RESULT,
            },
        },
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message",
                "role": "assistant",
                "id": message_id,
                "content": [{"type": "output_text", "text": ASSISTANT_TEXT}],
            },
        },
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 0,
                    "input_tokens_details": None,
                    "output_tokens": 0,
                    "output_tokens_details": None,
                    "total_tokens": 0,
                },
            },
        },
    ]
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


class ImageGenerationMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        return sse_image_generation_response(
            f"resp-redacted-resume-smoke-{counter}",
            f"msg-redacted-resume-smoke-{counter}",
        )

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        first_body = response_requests[0]["json"] if response_requests else {}
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "first_response_model": first_body.get("model"),
            "first_response_input_contains_user_text": USER_TEXT
            in json.dumps(first_body.get("input"), ensure_ascii=False),
        }


def send_initialize(
    client: JsonRpcClient,
    request_id: int,
    client_name: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": client_name,
                    "title": client_name,
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
                "clientUserMessageId": "client-user-message-redacted-resume",
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


def send_thread_resume_remote(
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
                "initialTurnsPage": {},
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def thread_from_response(response: dict[str, Any]) -> dict[str, Any]:
    return ((response.get("result") or {}).get("thread") or {})


def turns_from_response(response: dict[str, Any]) -> list[dict[str, Any]]:
    return thread_from_response(response).get("turns") or []


def initial_page_turns_from_resume(response: dict[str, Any]) -> list[dict[str, Any]]:
    page = (response.get("result") or {}).get("initialTurnsPage") or {}
    return page.get("data") or []


def item_types(turns: list[dict[str, Any]]) -> list[list[Any]]:
    return [[item.get("type") for item in turn.get("items") or []] for turn in turns]


def serialized(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def summarize_turns(turns: list[dict[str, Any]]) -> dict[str, Any]:
    body = serialized(turns)
    types_by_turn = item_types(turns)
    flat_types = [item_type for turn_types in types_by_turn for item_type in turn_types]
    return {
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": types_by_turn,
        "has_image_generation": "imageGeneration" in flat_types,
        "has_agent_message": "agentMessage" in flat_types,
        "contains_user_text": USER_TEXT in body,
        "contains_assistant_text": ASSISTANT_TEXT in body,
        "contains_image_generation_id": IMAGE_GENERATION_ID in body,
        "contains_image_result": IMAGE_RESULT in body,
        "contains_image_revised_prompt": IMAGE_REVISED_PROMPT in body,
        "contains_redacted_marker": "[redacted]" in body,
    }


def normalize_thread_payload(response: dict[str, Any]) -> dict[str, Any]:
    thread = thread_from_response(response)
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": (response.get("result") or {}).get("model") or thread.get("model"),
        "model_provider": (response.get("result") or {}).get("modelProvider")
        or thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turns": summarize_turns(turns_from_response(response)),
    }


def normalize_resume_payload(response: dict[str, Any]) -> dict[str, Any]:
    normalized = normalize_thread_payload(response)
    normalized["initial_turns_page"] = summarize_turns(
        initial_page_turns_from_resume(response)
    )
    page = (response.get("result") or {}).get("initialTurnsPage") or {}
    normalized["initial_turns_page_next_cursor_present"] = (
        page.get("nextCursor") is not None
    )
    normalized["initial_turns_page_backwards_cursor_present"] = (
        page.get("backwardsCursor") is not None
    )
    return normalized


def source_transport_response_types(package_summary: dict[str, Any]) -> list[Any]:
    packages = package_summary.get("packages") or []
    if len(packages) != 1:
        return []
    package = pathlib.Path(packages[0]["package"])
    values = []
    for line in (package / "journal.ndjson").read_text().splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        payload = ((entry.get("source_transport") or {}).get("payload") or {})
        if payload.get("type") == "response_item":
            values.append((payload.get("payload") or {}).get("type"))
    return values


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

    with ImageGenerationMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        normal_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        normal_stderr = ""
        remote_stderr = ""
        try:
            normal_initialize_response = send_initialize(
                normal_client,
                1,
                NORMAL_CLIENT_NAME,
            )
            thread_id, thread_start_response = send_thread_start(
                normal_client,
                2,
                workspace,
            )
            turn_start_response = send_turn_start(normal_client, 3, thread_id)
            turn_started_notification = normal_client.receive_until_method(
                "turn/started",
                timeout_seconds=30,
            )
            turn_completed_notification = normal_client.receive_until_method(
                "turn/completed",
                timeout_seconds=60,
            )
            normal_thread_read_response = send_thread_read(normal_client, 4, thread_id)
        finally:
            normal_stderr = normal_client.close()

        remote_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        try:
            remote_initialize_response = send_initialize(
                remote_client,
                11,
                REMOTE_CLIENT_NAME,
            )
            remote_resume_response = send_thread_resume_remote(remote_client, 12, thread_id)
            remote_thread_read_response = send_thread_read(remote_client, 13, thread_id)
        finally:
            remote_stderr = remote_client.close()

        result = {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "mock_server_summary": mock_server.summary(),
            "normal_initialize_response": normal_initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": turn_start_response,
            "turn_started_notification": turn_started_notification,
            "turn_completed_notification": turn_completed_notification,
            "normal_thread_read_response": normal_thread_read_response,
            "remote_initialize_response": remote_initialize_response,
            "remote_resume_response": remote_resume_response,
            "remote_thread_read_response": remote_thread_read_response,
            "normalized_normal_read": normalize_thread_payload(
                normal_thread_read_response
            ),
            "normalized_remote_resume": normalize_resume_payload(remote_resume_response),
            "normalized_remote_read_after_resume": normalize_thread_payload(
                remote_thread_read_response
            ),
            "thread_id": thread_id,
            "normal_jsonrpc_sent": normal_client.sent,
            "normal_jsonrpc_received": normal_client.received,
            "remote_jsonrpc_sent": remote_client.sent,
            "remote_jsonrpc_received": remote_client.received,
            "normal_stderr_tail": normal_stderr[-6000:],
            "remote_stderr_tail": remote_stderr[-6000:],
            "normal_process_exit_code": normal_client.process.returncode,
            "remote_process_exit_code": remote_client.process.returncode,
        }
        if tree_name == "chat-backend":
            package_summary = summarize_chat_packages(chat_root)
            result["chat_package_summary"] = package_summary
            result["chat_journal_response_types"] = source_transport_response_types(
                package_summary
            )
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
        return result


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def chat_package_redaction_smoke_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 5
        and package.get("journal_line_count", 0) >= 5
        and "tool_call" in event_types
        and "image_generation_call" in source_transport_response_types(summary)
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-redacted-resume-payload-smoke-"
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

    original_normal_read = original_result["normalized_normal_read"]
    chat_normal_read = chat_result["normalized_normal_read"]
    original_remote_resume = original_result["normalized_remote_resume"]
    chat_remote_resume = chat_result["normalized_remote_resume"]
    original_remote_read = original_result["normalized_remote_read_after_resume"]
    chat_remote_read = chat_result["normalized_remote_read_after_resume"]
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_lines = line_count(original_storage, "rollouts")
    chat_packages = chat_package.get("packages") or []
    chat_journal_lines = (
        chat_packages[0].get("journal_line_count") if len(chat_packages) == 1 else None
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-redacted-resume-payload-smoke",
        "remote_client_name": REMOTE_CLIENT_NAME,
        "binary_checks": binary_checks,
        "original_turn_exit_ok": "result" in original_result["turn_start_response"],
        "chat_backend_turn_exit_ok": "result" in chat_result["turn_start_response"],
        "original_normal_read_exit_ok": "result"
        in original_result["normal_thread_read_response"],
        "chat_backend_normal_read_exit_ok": "result"
        in chat_result["normal_thread_read_response"],
        "original_remote_resume_exit_ok": "result"
        in original_result["remote_resume_response"],
        "chat_backend_remote_resume_exit_ok": "result"
        in chat_result["remote_resume_response"],
        "original_remote_read_exit_ok": "result"
        in original_result["remote_thread_read_response"],
        "chat_backend_remote_read_exit_ok": "result"
        in chat_result["remote_thread_read_response"],
        "normalized_normal_read_equal": original_normal_read == chat_normal_read,
        "normalized_remote_resume_equal": original_remote_resume == chat_remote_resume,
        "normalized_remote_read_after_resume_equal": original_remote_read == chat_remote_read,
        "original_normal_read_has_image_generation": original_normal_read["turns"][
            "has_image_generation"
        ],
        "chat_backend_normal_read_has_image_generation": chat_normal_read["turns"][
            "has_image_generation"
        ],
        "original_remote_resume_thread_image_removed": not original_remote_resume[
            "turns"
        ]["has_image_generation"],
        "chat_backend_remote_resume_thread_image_removed": not chat_remote_resume[
            "turns"
        ]["has_image_generation"],
        "original_remote_resume_initial_page_image_removed": not original_remote_resume[
            "initial_turns_page"
        ]["has_image_generation"],
        "chat_backend_remote_resume_initial_page_image_removed": not chat_remote_resume[
            "initial_turns_page"
        ]["has_image_generation"],
        "original_remote_resume_thread_payload_removed": not original_remote_resume[
            "turns"
        ]["contains_image_result"],
        "chat_backend_remote_resume_thread_payload_removed": not chat_remote_resume[
            "turns"
        ]["contains_image_result"],
        "original_remote_resume_initial_page_payload_removed": not original_remote_resume[
            "initial_turns_page"
        ]["contains_image_result"],
        "chat_backend_remote_resume_initial_page_payload_removed": not chat_remote_resume[
            "initial_turns_page"
        ]["contains_image_result"],
        "original_remote_read_after_resume_still_has_image_generation": original_remote_read[
            "turns"
        ]["has_image_generation"],
        "chat_backend_remote_read_after_resume_still_has_image_generation": chat_remote_read[
            "turns"
        ]["has_image_generation"],
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_single_model_request_each": (
            original_mock["response_request_count"] == 1
            and chat_mock["response_request_count"] == 1
        ),
        "mock_request_includes_user_text": (
            original_mock["first_response_input_contains_user_text"]
            and chat_mock["first_response_input_contains_user_text"]
        ),
        "chat_package_redaction_smoke_ok": chat_package_redaction_smoke_ok(chat_package),
        "journal_line_count_matches_original": (
            original_lines is not None and original_lines == chat_journal_lines
        ),
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "original_normalized_normal_read": original_normal_read,
        "chat_backend_normalized_normal_read": chat_normal_read,
        "original_normalized_remote_resume": original_remote_resume,
        "chat_backend_normalized_remote_resume": chat_remote_resume,
        "original_normalized_remote_read_after_resume": original_remote_read,
        "chat_backend_normalized_remote_read_after_resume": chat_remote_read,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "chat_journal_response_types": chat_result["chat_journal_response_types"],
        "not_yet_proven": [
            "MCP tool-call argument/result redaction parity",
            "pending unload race parity",
            "fork/rollback/compaction parity",
            "command/tool execution parity",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/redacted-resume-payload-response.json", original_result)
    write_json(
        output_dir / "chat-backend/redacted-resume-payload-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Redacted Resume Payload Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that emits an `image_generation_call` item.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. Relevant
vendored app-server resume redaction, event mapping, SSE parsing, and `.chat`
backend source-transport code was also read.

## Scope

This smoke covers one completed image-generation turn, a cold `thread/resume`
from `{REMOTE_CLIENT_NAME}`, and a follow-up `thread/read`.

It proves an R07 image-generation redaction slice for this harness: the remote
`thread/resume` response removes image-generation payloads, while persisted
history remains readable through ordinary `thread/read`. It does not prove MCP
tool-call argument/result redaction, fork, rollback, compaction,
archive/search/delete, crash recovery, complete data fidelity, or final
user-indistinguishability.

## Result

- original normal `thread/read` included image generation: `{summary['original_normal_read_has_image_generation']}`
- `.chat` backend normal `thread/read` included image generation: `{summary['chat_backend_normal_read_has_image_generation']}`
- normalized normal reads equal: `{summary['normalized_normal_read_equal']}`
- original remote `thread/resume` removed image generation from thread: `{summary['original_remote_resume_thread_image_removed']}`
- `.chat` backend remote `thread/resume` removed image generation from thread: `{summary['chat_backend_remote_resume_thread_image_removed']}`
- original remote `thread/resume` removed image generation from initial page: `{summary['original_remote_resume_initial_page_image_removed']}`
- `.chat` backend remote `thread/resume` removed image generation from initial page: `{summary['chat_backend_remote_resume_initial_page_image_removed']}`
- normalized remote resumes equal: `{summary['normalized_remote_resume_equal']}`
- original `thread/read` after remote resume still included image generation: `{summary['original_remote_read_after_resume_still_has_image_generation']}`
- `.chat` backend `thread/read` after remote resume still included image generation: `{summary['chat_backend_remote_read_after_resume_still_has_image_generation']}`
- normalized post-resume reads equal: `{summary['normalized_remote_read_after_resume_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- `.chat` package retained image generation source transport: `{summary['chat_package_redaction_smoke_ok']}`
- `.chat` journal line count matched original rollout line count: `{summary['journal_line_count_matches_original']}`

## Normalized Normal Read

```json
{json.dumps({'original': original_normal_read, 'chat-backend': chat_normal_read}, indent=2, sort_keys=True)}
```

## Normalized Remote Resume

```json
{json.dumps({'original': original_remote_resume, 'chat-backend': chat_remote_resume}, indent=2, sort_keys=True)}
```

## Normalized Read After Remote Resume

```json
{json.dumps({'original': original_remote_read, 'chat-backend': chat_remote_read}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/redacted-resume-payload-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/redacted-resume-payload-response.json
```

## Not Yet Proven

This smoke does not prove MCP tool-call argument/result redaction, pending
unload race, fork, rollback, compaction, command/tool execution,
archive/search/delete, crash recovery, complete data fidelity, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_turn_exit_ok"],
            summary["chat_backend_turn_exit_ok"],
            summary["original_normal_read_exit_ok"],
            summary["chat_backend_normal_read_exit_ok"],
            summary["original_remote_resume_exit_ok"],
            summary["chat_backend_remote_resume_exit_ok"],
            summary["original_remote_read_exit_ok"],
            summary["chat_backend_remote_read_exit_ok"],
            summary["normalized_normal_read_equal"],
            summary["normalized_remote_resume_equal"],
            summary["normalized_remote_read_after_resume_equal"],
            summary["original_normal_read_has_image_generation"],
            summary["chat_backend_normal_read_has_image_generation"],
            summary["original_remote_resume_thread_image_removed"],
            summary["chat_backend_remote_resume_thread_image_removed"],
            summary["original_remote_resume_initial_page_image_removed"],
            summary["chat_backend_remote_resume_initial_page_image_removed"],
            summary["original_remote_resume_thread_payload_removed"],
            summary["chat_backend_remote_resume_thread_payload_removed"],
            summary["original_remote_resume_initial_page_payload_removed"],
            summary["chat_backend_remote_resume_initial_page_payload_removed"],
            summary["original_remote_read_after_resume_still_has_image_generation"],
            summary["chat_backend_remote_read_after_resume_still_has_image_generation"],
            summary["mock_response_request_counts_equal"],
            summary["mock_single_model_request_each"],
            summary["mock_request_includes_user_text"],
            summary["chat_package_redaction_smoke_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
