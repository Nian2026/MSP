#!/usr/bin/env python3
"""Run an MCP redacted thread/resume smoke for original vs `.chat` Codex.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. Each tree runs a model-triggered MCP tool call through Codex's bundled
stdio MCP test server, persists that turn, restarts the app-server as a remote
ChatGPT client, and calls `thread/resume`.

Remote resume responses should redact MCP arguments and result payloads without
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
    run_command,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)


USER_TEXT = "Call the MCP redaction validation tool."
ASSISTANT_TEXT = "MCP redaction validation completed."
MCP_SERVER_NAME = "msp_redaction"
MCP_NAMESPACE = f"mcp__{MCP_SERVER_NAME}"
MCP_TOOL_NAME = "echo"
MCP_CALL_ID = "call-mcp-redaction-smoke"
MCP_SECRET_ARGUMENT = "secret mcp argument"
MCP_SECRET_RESULT_FRAGMENT = f"ECHOING: {MCP_SECRET_ARGUMENT}"
REMOTE_CLIENT_NAME = "codex_chatgpt_ios_remote"
NORMAL_CLIENT_NAME = "msp-chat-validation"


def sse_events(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def usage() -> dict[str, Any]:
    return {
        "input_tokens": 0,
        "input_tokens_details": None,
        "output_tokens": 0,
        "output_tokens_details": None,
        "total_tokens": 0,
    }


def sse_mcp_call_response(response_id: str) -> bytes:
    return sse_events(
        [
            {
                "type": "response.created",
                "response": {
                    "id": response_id,
                },
            },
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": MCP_CALL_ID,
                    "namespace": MCP_NAMESPACE,
                    "name": MCP_TOOL_NAME,
                    "arguments": json.dumps(
                        {"message": MCP_SECRET_ARGUMENT},
                        separators=(",", ":"),
                    ),
                },
            },
            {
                "type": "response.completed",
                "response": {
                    "id": response_id,
                    "usage": usage(),
                },
            },
        ]
    )


def sse_final_message_response(response_id: str, message_id: str) -> bytes:
    return sse_events(
        [
            {
                "type": "response.created",
                "response": {
                    "id": response_id,
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
                    "usage": usage(),
                },
            },
        ]
    )


class McpCallMockResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter == 1:
            return sse_mcp_call_response("resp-mcp-redaction-smoke-1")
        return sse_final_message_response(
            f"resp-mcp-redaction-smoke-{counter}",
            f"msg-mcp-redaction-smoke-{counter}",
        )

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        request_bodies = [request["json"] for request in response_requests]
        first_body = request_bodies[0] if request_bodies else {}
        second_body = request_bodies[1] if len(request_bodies) > 1 else {}
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "first_response_model": first_body.get("model"),
            "first_response_input_contains_user_text": USER_TEXT
            in json.dumps(first_body.get("input"), ensure_ascii=False),
            "second_response_input_contains_mcp_output": MCP_SECRET_RESULT_FRAGMENT
            in json.dumps(second_body.get("input"), ensure_ascii=False),
            "response_input_contains_function_call_output": "function_call_output"
            in json.dumps(second_body.get("input"), ensure_ascii=False),
        }


def ensure_test_stdio_server(codex_rs: pathlib.Path, build_if_missing: bool) -> dict[str, Any]:
    binary = codex_rs / "target/debug/test_stdio_server"
    if binary.exists():
        return {
            "built": False,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
        }

    if not build_if_missing:
        raise RuntimeError(
            f"missing {binary}; run `cargo build -p codex-rmcp-client --bin test_stdio_server` first"
        )

    result = run_command(
        ["cargo", "build", "-p", "codex-rmcp-client", "--bin", "test_stdio_server"],
        codex_rs,
    )
    if result["exit_code"] != 0 or not binary.exists():
        raise RuntimeError(f"failed to build {binary}: {result}")
    result.update(
        {
            "built": True,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
        }
    )
    return result


def append_mcp_config(codex_home: pathlib.Path, test_stdio_server: pathlib.Path) -> None:
    config_path = codex_home / "config.toml"
    with config_path.open("a") as handle:
        handle.write(
            "\n"
            f"[mcp_servers.{MCP_SERVER_NAME}]\n"
            f"command = {json.dumps(str(test_stdio_server))}\n"
            "startup_timeout_sec = 10\n"
            "tool_timeout_sec = 10\n"
        )


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
                "clientUserMessageId": "client-user-message-mcp-redaction",
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
                "initialTurnsPage": {
                    "itemsView": "full",
                },
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


def serialized(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def item_types(turns: list[dict[str, Any]]) -> list[list[Any]]:
    return [[item.get("type") for item in turn.get("items") or []] for turn in turns]


def flat_items(turns: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [item for turn in turns for item in (turn.get("items") or [])]


def mcp_items(turns: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [item for item in flat_items(turns) if item.get("type") == "mcpToolCall"]


def summarize_mcp_item(item: dict[str, Any] | None) -> dict[str, Any] | None:
    if item is None:
        return None
    result = item.get("result") or {}
    error = item.get("error") or {}
    body = serialized(item)
    return {
        "id": item.get("id"),
        "server": item.get("server"),
        "tool": item.get("tool"),
        "status": item.get("status"),
        "arguments": item.get("arguments"),
        "result_content": result.get("content"),
        "result_structured_content": result.get("structuredContent"),
        "result_meta": result.get("meta"),
        "error_message": error.get("message"),
        "contains_secret_argument": MCP_SECRET_ARGUMENT in body,
        "contains_secret_result": MCP_SECRET_RESULT_FRAGMENT in body,
        "contains_redacted_marker": "[redacted]" in body,
    }


def summarize_turns(turns: list[dict[str, Any]]) -> dict[str, Any]:
    body = serialized(turns)
    types_by_turn = item_types(turns)
    flat_types = [item_type for turn_types in types_by_turn for item_type in turn_types]
    mcp = mcp_items(turns)
    first_mcp = mcp[0] if mcp else None
    return {
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "items_views": [turn.get("itemsView") for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": types_by_turn,
        "has_mcp_tool_call": "mcpToolCall" in flat_types,
        "has_agent_message": "agentMessage" in flat_types,
        "contains_user_text": USER_TEXT in body,
        "contains_assistant_text": ASSISTANT_TEXT in body,
        "contains_mcp_call_id": MCP_CALL_ID in body,
        "contains_secret_argument": MCP_SECRET_ARGUMENT in body,
        "contains_secret_result": MCP_SECRET_RESULT_FRAGMENT in body,
        "contains_redacted_marker": "[redacted]" in body,
        "mcp_item_count": len(mcp),
        "first_mcp_item": summarize_mcp_item(first_mcp),
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


def line_count(summary: dict[str, Any], key: str) -> int | None:
    items = summary.get(key) or []
    if len(items) != 1:
        return None
    return items[0].get("line_count")


def wait_for_mcp_item_completed(client: JsonRpcClient) -> dict[str, Any]:
    return client.receive_until(
        lambda message: message.get("method") == "item/completed"
        and (
            ((message.get("params") or {}).get("item") or {}).get("type")
            == "mcpToolCall"
        )
        and (
            ((message.get("params") or {}).get("item") or {}).get("id")
            == MCP_CALL_ID
        ),
        60,
        "item/completed MCP tool call notification",
    )


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    test_stdio_server: pathlib.Path,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with McpCallMockResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        append_mcp_config(codex_home, test_stdio_server)
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
            mcp_item_completed_notification = wait_for_mcp_item_completed(normal_client)
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
            "test_stdio_server": str(test_stdio_server),
            "mock_server_summary": mock_server.summary(),
            "normal_initialize_response": normal_initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": turn_start_response,
            "turn_started_notification": turn_started_notification,
            "mcp_item_completed_notification": mcp_item_completed_notification,
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


def chat_package_mcp_redaction_smoke_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    source_types = set(source_transport_response_types(summary))
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 7
        and package.get("journal_line_count", 0) >= 7
        and "tool_call" in event_types
        and "tool_output" in event_types
        and "function_call" in source_types
        and "function_call_output" in source_types
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-mcp-redacted-resume-smoke-"
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
    mcp_binary_checks = {
        "original": ensure_test_stdio_server(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_test_stdio_server(
            CHAT_BACKEND_CODEX_RS,
            args.build_if_missing,
        ),
    }

    run_root = output_dir / "run"
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
        test_stdio_server=pathlib.Path(mcp_binary_checks["original"]["artifact"]),
    )
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        test_stdio_server=pathlib.Path(mcp_binary_checks["chat-backend"]["artifact"]),
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
        "scope": "app-server-mcp-redacted-resume-smoke",
        "remote_client_name": REMOTE_CLIENT_NAME,
        "mcp_server_name": MCP_SERVER_NAME,
        "mcp_tool_name": MCP_TOOL_NAME,
        "mcp_call_id": MCP_CALL_ID,
        "binary_checks": binary_checks,
        "mcp_binary_checks": mcp_binary_checks,
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
        "original_normal_read_has_mcp": original_normal_read["turns"][
            "has_mcp_tool_call"
        ],
        "chat_backend_normal_read_has_mcp": chat_normal_read["turns"][
            "has_mcp_tool_call"
        ],
        "original_normal_read_keeps_mcp_secret": (
            original_normal_read["turns"]["contains_secret_argument"]
            and original_normal_read["turns"]["contains_secret_result"]
        ),
        "chat_backend_normal_read_keeps_mcp_secret": (
            chat_normal_read["turns"]["contains_secret_argument"]
            and chat_normal_read["turns"]["contains_secret_result"]
        ),
        "original_remote_resume_thread_mcp_redacted": (
            original_remote_resume["turns"]["has_mcp_tool_call"]
            and original_remote_resume["turns"]["contains_redacted_marker"]
            and not original_remote_resume["turns"]["contains_secret_argument"]
            and not original_remote_resume["turns"]["contains_secret_result"]
        ),
        "chat_backend_remote_resume_thread_mcp_redacted": (
            chat_remote_resume["turns"]["has_mcp_tool_call"]
            and chat_remote_resume["turns"]["contains_redacted_marker"]
            and not chat_remote_resume["turns"]["contains_secret_argument"]
            and not chat_remote_resume["turns"]["contains_secret_result"]
        ),
        "original_remote_resume_initial_page_mcp_redacted": (
            original_remote_resume["initial_turns_page"]["has_mcp_tool_call"]
            and original_remote_resume["initial_turns_page"]["contains_redacted_marker"]
            and not original_remote_resume["initial_turns_page"][
                "contains_secret_argument"
            ]
            and not original_remote_resume["initial_turns_page"][
                "contains_secret_result"
            ]
        ),
        "chat_backend_remote_resume_initial_page_mcp_redacted": (
            chat_remote_resume["initial_turns_page"]["has_mcp_tool_call"]
            and chat_remote_resume["initial_turns_page"]["contains_redacted_marker"]
            and not chat_remote_resume["initial_turns_page"][
                "contains_secret_argument"
            ]
            and not chat_remote_resume["initial_turns_page"][
                "contains_secret_result"
            ]
        ),
        "original_remote_read_after_resume_still_has_mcp_secret": (
            original_remote_read["turns"]["contains_secret_argument"]
            and original_remote_read["turns"]["contains_secret_result"]
        ),
        "chat_backend_remote_read_after_resume_still_has_mcp_secret": (
            chat_remote_read["turns"]["contains_secret_argument"]
            and chat_remote_read["turns"]["contains_secret_result"]
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_two_model_requests_each": (
            original_mock["response_request_count"] == 2
            and chat_mock["response_request_count"] == 2
        ),
        "mock_request_includes_user_text": (
            original_mock["first_response_input_contains_user_text"]
            and chat_mock["first_response_input_contains_user_text"]
        ),
        "mock_second_request_includes_mcp_output": (
            original_mock["second_response_input_contains_mcp_output"]
            and chat_mock["second_response_input_contains_mcp_output"]
        ),
        "chat_package_mcp_redaction_smoke_ok": chat_package_mcp_redaction_smoke_ok(
            chat_package
        ),
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
            "pending unload race parity",
            "fork/rollback/compaction parity",
            "broad command/tool execution parity beyond one MCP tool call",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/mcp-redacted-resume-response.json", original_result)
    write_json(
        output_dir / "chat-backend/mcp-redacted-resume-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server MCP Redacted Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path, a local mock
Responses API, and Codex's bundled stdio MCP test server.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read. The relevant
vendored Codex source paths were also checked:

- `app-server/src/request_processors/thread_resume_redaction.rs`
- `app-server/tests/suite/v2/thread_resume.rs`
- `app-server/tests/suite/v2/mcp_tool.rs`
- `core/src/mcp_tool_call.rs`
- `protocol/src/models.rs`
- `protocol/src/items.rs`
- `rmcp-client/src/bin/test_stdio_server.rs`

## Scope

This smoke covers one model-triggered MCP tool call:

1. mock Responses emits `function_call` with namespace `{MCP_NAMESPACE}`;
2. Codex executes `{MCP_SERVER_NAME}.{MCP_TOOL_NAME}` through stdio MCP;
3. Codex sends the tool output back to the mock Responses API;
4. mock Responses emits the final assistant message;
5. both original and `.chat` backend persist the completed turn;
6. remote `thread/resume` redacts MCP arguments and result payloads;
7. ordinary `thread/read` still exposes the unredacted persisted history.

This is still a narrow R07 slice. It does not prove every MCP transport,
approval, elicitation, large-result, or dynamic-tool path.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_exit_ok']}`
- original `thread/read` response succeeded: `{summary['original_normal_read_exit_ok']}`
- `.chat` backend `thread/read` response succeeded: `{summary['chat_backend_normal_read_exit_ok']}`
- original remote `thread/resume` response succeeded: `{summary['original_remote_resume_exit_ok']}`
- `.chat` backend remote `thread/resume` response succeeded: `{summary['chat_backend_remote_resume_exit_ok']}`
- normalized original vs `.chat` normal `thread/read` equal: `{summary['normalized_normal_read_equal']}`
- normalized original vs `.chat` remote `thread/resume` equal: `{summary['normalized_remote_resume_equal']}`
- normalized original vs `.chat` remote `thread/read` after resume equal: `{summary['normalized_remote_read_after_resume_equal']}`
- normal original read keeps MCP secret payload: `{summary['original_normal_read_keeps_mcp_secret']}`
- normal `.chat` read keeps MCP secret payload: `{summary['chat_backend_normal_read_keeps_mcp_secret']}`
- original remote resume redacts MCP item: `{summary['original_remote_resume_thread_mcp_redacted']}`
- `.chat` backend remote resume redacts MCP item: `{summary['chat_backend_remote_resume_thread_mcp_redacted']}`
- original remote initial turns page redacts MCP item: `{summary['original_remote_resume_initial_page_mcp_redacted']}`
- `.chat` backend remote initial turns page redacts MCP item: `{summary['chat_backend_remote_resume_initial_page_mcp_redacted']}`
- original ordinary read after remote resume still has MCP secret: `{summary['original_remote_read_after_resume_still_has_mcp_secret']}`
- `.chat` ordinary read after remote resume still has MCP secret: `{summary['chat_backend_remote_read_after_resume_still_has_mcp_secret']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- each tree made two model requests: `{summary['mock_two_model_requests_each']}`
- second model request included MCP output: `{summary['mock_second_request_includes_mcp_output']}`
- durable `.chat` package has MCP source transport evidence: `{summary['chat_package_mcp_redaction_smoke_ok']}`
- `.chat` journal line count matches original rollout: `{summary['journal_line_count_matches_original']}`

## Normalized Remote Resume

```json
{json.dumps({'original': original_remote_resume, 'chat-backend': chat_remote_resume}, indent=2, sort_keys=True)}
```

## Normalized Ordinary Read After Remote Resume

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
{output_dir.relative_to(VALIDATION_DIR)}/original/mcp-redacted-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/mcp-redacted-resume-response.json
```

## Not Yet Proven

This smoke does not prove pending unload race parity, fork, rollback,
compaction, broad command/tool execution parity, search/archive/delete parity,
crash recovery, complete data fidelity, or final user-indistinguishability under
normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return (
        0
        if summary["original_turn_exit_ok"]
        and summary["chat_backend_turn_exit_ok"]
        and summary["original_normal_read_exit_ok"]
        and summary["chat_backend_normal_read_exit_ok"]
        and summary["original_remote_resume_exit_ok"]
        and summary["chat_backend_remote_resume_exit_ok"]
        and summary["original_remote_read_exit_ok"]
        and summary["chat_backend_remote_read_exit_ok"]
        and summary["normalized_normal_read_equal"]
        and summary["normalized_remote_resume_equal"]
        and summary["normalized_remote_read_after_resume_equal"]
        and summary["original_normal_read_keeps_mcp_secret"]
        and summary["chat_backend_normal_read_keeps_mcp_secret"]
        and summary["original_remote_resume_thread_mcp_redacted"]
        and summary["chat_backend_remote_resume_thread_mcp_redacted"]
        and summary["original_remote_resume_initial_page_mcp_redacted"]
        and summary["chat_backend_remote_resume_initial_page_mcp_redacted"]
        and summary["original_remote_read_after_resume_still_has_mcp_secret"]
        and summary["chat_backend_remote_read_after_resume_still_has_mcp_secret"]
        and summary["mock_response_request_counts_equal"]
        and summary["mock_two_model_requests_each"]
        and summary["mock_second_request_includes_mcp_output"]
        and summary["chat_package_mcp_redaction_smoke_ok"]
        and summary["journal_line_count_matches_original"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
