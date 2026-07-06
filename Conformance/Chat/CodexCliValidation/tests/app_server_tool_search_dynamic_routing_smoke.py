#!/usr/bin/env python3
"""Run app-server tool-search dynamic routing parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers the slice after non-empty
tool-search discovery: the model calls a deferred dynamic tool, app-server sends
`item/tool/call`, the client returns a dynamic tool response, the next model
request receives a function-call output, and the original backend and `.chat`
backend persist the same durable response facts.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import threading
import traceback
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
    normalize_thread_list_response,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from app_server_fork_smoke import (  # noqa: E402
    send_initialize,
    send_thread_list,
    send_thread_read,
    send_turn_start,
)
from app_server_tool_search_discovery_smoke import (  # noqa: E402
    MODEL,
    TOOL_DESCRIPTION,
    TOOL_NAME,
    TOOL_NAMESPACE,
    TOOL_QUERY,
    TOOL_SEARCH_CALL_ID,
    dynamic_tools,
    find_tool_search_output,
    send_thread_start_with_dynamic_tools,
    summarize_chat_tool_search_package,
    summarize_original_tool_search_storage,
    tool_names_from_tools,
    write_search_capable_mock_config,
)


USER_TEXT = "Find and run the recurring automation dynamic command."
ASSISTANT_TEXT = "Dynamic tool routing final answer from mock model."
DYNAMIC_CALL_ID = "call-dynamic-tool-routing"
DYNAMIC_ARGUMENTS = {"mode": "create"}
DYNAMIC_RESPONSE_TEXT = "dynamic-search-ok"


def sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def ev_response_created(response_id: str) -> dict[str, Any]:
    return {"type": "response.created", "response": {"id": response_id}}


def ev_completed(response_id: str) -> dict[str, Any]:
    return {
        "type": "response.completed",
        "response": {
            "id": response_id,
            "usage": {
                "input_tokens": 43,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 37,
                "output_tokens_details": {"reasoning_tokens": 0},
                "total_tokens": 80,
            },
        },
    }


def ev_tool_search_call() -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "tool_search_call",
            "call_id": TOOL_SEARCH_CALL_ID,
            "execution": "client",
            "arguments": {
                "query": TOOL_QUERY,
                "limit": 4,
            },
        },
    }


def ev_dynamic_function_call() -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "function_call",
            "call_id": DYNAMIC_CALL_ID,
            "namespace": TOOL_NAMESPACE,
            "name": TOOL_NAME,
            "arguments": json.dumps(DYNAMIC_ARGUMENTS, separators=(",", ":")),
        },
    }


def ev_assistant_message(message_id: str, text: str) -> dict[str, Any]:
    return {
        "type": "response.output_item.done",
        "item": {
            "type": "message",
            "role": "assistant",
            "id": message_id,
            "content": [{"type": "output_text", "text": text}],
        },
    }


def tool_search_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_tool_search_call(),
            ev_completed(response_id),
        ]
    )


def dynamic_call_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_dynamic_function_call(),
            ev_completed(response_id),
        ]
    )


def final_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_assistant_message("msg-tool-search-dynamic-final", ASSISTANT_TEXT),
            ev_completed(response_id),
        ]
    )


class ToolSearchDynamicRoutingResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter == 1:
            return tool_search_sse_response("resp-tool-search-routing-1")
        if counter == 2:
            return dynamic_call_sse_response("resp-tool-search-routing-2")
        return final_sse_response(f"resp-tool-search-routing-{counter}")

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        bodies = [request["json"] for request in response_requests]
        first_body = bodies[0] if bodies else {}
        second_body = bodies[1] if len(bodies) > 1 else {}
        third_body = bodies[2] if len(bodies) > 2 else {}
        first_tools = first_body.get("tools", [])
        second_tools = second_body.get("tools", [])
        third_tools = third_body.get("tools", [])
        first_tool_names = tool_names_from_tools(first_tools)
        second_tool_names = tool_names_from_tools(second_tools)
        third_tool_names = tool_names_from_tools(third_tools)
        first_tools_serialized = json.dumps(first_tools, ensure_ascii=False)
        second_tools_serialized = json.dumps(second_tools, ensure_ascii=False)
        third_tools_serialized = json.dumps(third_tools, ensure_ascii=False)
        second_output = find_tool_search_output(second_body, TOOL_SEARCH_CALL_ID)
        discovered_tools = (second_output or {}).get("tools") or []
        discovered_tools_serialized = json.dumps(discovered_tools, ensure_ascii=False)
        dynamic_output = find_type_with_call_id(
            third_body,
            "function_call_output",
            DYNAMIC_CALL_ID,
        )
        third_serialized = json.dumps(third_body, ensure_ascii=False)
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "first_response_model": first_body.get("model"),
            "first_response_input_contains_user_text": USER_TEXT
            in json.dumps(first_body.get("input"), ensure_ascii=False),
            "first_response_tools": first_tool_names,
            "first_response_advertises_tool_search": "tool_search" in first_tool_names,
            "first_response_hides_deferred_tool": TOOL_NAME not in first_tools_serialized
            and TOOL_NAMESPACE not in first_tools_serialized,
            "second_response_tools": second_tool_names,
            "second_response_direct_tool_still_hidden": TOOL_NAME
            not in second_tools_serialized
            and TOOL_NAMESPACE not in second_tools_serialized,
            "second_response_input_contains_tool_search_output": second_output is not None,
            "second_response_tool_search_output_tool_count": len(discovered_tools),
            "second_response_tool_search_output_tools": discovered_tools,
            "second_response_tool_search_output_contains_namespace": TOOL_NAMESPACE
            in discovered_tools_serialized,
            "second_response_tool_search_output_contains_tool_name": TOOL_NAME
            in discovered_tools_serialized,
            "second_response_tool_search_output_contains_schema_term": "mode"
            in discovered_tools_serialized,
            "third_response_tools": third_tool_names,
            "third_response_direct_tool_still_hidden": TOOL_NAME
            not in third_tools_serialized
            and TOOL_NAMESPACE not in third_tools_serialized,
            "third_response_input_contains_dynamic_output": dynamic_output is not None,
            "third_response_input_contains_dynamic_call_id": DYNAMIC_CALL_ID
            in third_serialized,
            "third_response_input_contains_dynamic_response_text": DYNAMIC_RESPONSE_TEXT
            in third_serialized,
            "third_response_function_call_output": dynamic_output,
        }


def find_type_with_call_id(
    value: Any,
    item_type: str,
    call_id: str,
) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if value.get("type") == item_type and value.get("call_id") == call_id:
            return value
        for child in value.values():
            found = find_type_with_call_id(child, item_type, call_id)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_type_with_call_id(child, item_type, call_id)
            if found is not None:
                return found
    return None


def dynamic_tool_response() -> dict[str, Any]:
    return {
        "contentItems": [{"type": "inputText", "text": DYNAMIC_RESPONSE_TEXT}],
        "success": True,
    }


def item_id(message: dict[str, Any]) -> Any:
    return (((message.get("params") or {}).get("item") or {}).get("id"))


def is_dynamic_item(message: dict[str, Any], method: str) -> bool:
    item = ((message.get("params") or {}).get("item") or {})
    if message.get("method") != method:
        return False
    if item.get("type") != "dynamicToolCall":
        return False
    if item.get("id") == DYNAMIC_CALL_ID:
        return True
    return (
        item.get("namespace") == TOOL_NAMESPACE
        and item.get("tool") == TOOL_NAME
        and item.get("arguments") == DYNAMIC_ARGUMENTS
    )


def find_received_dynamic_item(
    messages: list[dict[str, Any]],
    method: str,
) -> dict[str, Any] | None:
    for message in reversed(messages):
        if is_dynamic_item(message, method):
            return message
    return None


def is_dynamic_request(message: dict[str, Any]) -> bool:
    params = message.get("params") or {}
    return (
        message.get("method") == "item/tool/call"
        and params.get("callId") == DYNAMIC_CALL_ID
        and params.get("namespace") == TOOL_NAMESPACE
        and params.get("tool") == TOOL_NAME
    )


def find_received_dynamic_request(
    messages: list[dict[str, Any]],
) -> dict[str, Any] | None:
    for message in reversed(messages):
        if is_dynamic_request(message):
            return message
    return None


def receive_dynamic_item(
    client: JsonRpcClient,
    method: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    found = find_received_dynamic_item(client.received, method)
    if found is not None:
        return found
    try:
        return client.receive_until(
            lambda message: is_dynamic_item(message, method),
            timeout_seconds,
            f"{method} for dynamic call {DYNAMIC_CALL_ID}",
        )
    except TimeoutError:
        found = find_received_dynamic_item(client.received, method)
        if found is not None:
            return found
        raise


def receive_dynamic_request(
    client: JsonRpcClient,
    timeout_seconds: int,
) -> dict[str, Any]:
    found = find_received_dynamic_request(client.received)
    if found is not None:
        return found
    try:
        return client.receive_until(
            lambda message: is_dynamic_request(message),
            timeout_seconds,
            f"item/tool/call for dynamic call {DYNAMIC_CALL_ID}",
        )
    except TimeoutError:
        found = find_received_dynamic_request(client.received)
        if found is not None:
            return found
        raise


def normalize_dynamic_request(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params") or {}
    return {
        "has_request_id": message.get("id") is not None,
        "method": message.get("method"),
        "call_id": params.get("callId"),
        "namespace": params.get("namespace"),
        "tool": params.get("tool"),
        "arguments": params.get("arguments"),
        "has_thread_id": bool(params.get("threadId")),
        "has_turn_id": bool(params.get("turnId")),
    }


def normalize_dynamic_item(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params") or {}
    item = params.get("item") or {}
    return {
        "method": message.get("method"),
        "thread_id_present": bool(params.get("threadId")),
        "turn_id_present": bool(params.get("turnId")),
        "item_type": item.get("type"),
        "id": item.get("id"),
        "namespace": item.get("namespace"),
        "tool": item.get("tool"),
        "arguments": item.get("arguments"),
        "status": item.get("status"),
        "content_items": item.get("contentItems"),
        "success": item.get("success"),
        "duration_ms_present": item.get("durationMs") is not None,
    }


def normalize_thread_read_for_dynamic(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": [
            (turn.get("status") or {}).get("type")
            if isinstance(turn.get("status"), dict)
            else turn.get("status")
            for turn in turns
        ],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in turn.get("items") or []] for turn in turns
        ],
        "contains_user_text": USER_TEXT in serialized,
        "contains_assistant_text": ASSISTANT_TEXT in serialized,
        "contains_dynamic_call_id": DYNAMIC_CALL_ID in serialized,
        "contains_dynamic_tool_name": TOOL_NAME in serialized,
        "contains_dynamic_response_text": DYNAMIC_RESPONSE_TEXT in serialized,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def response_item_payloads(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    payloads = []
    for item in items:
        if item.get("type") == "response_item":
            payloads.append(item.get("payload") or {})
    return payloads


def summarize_dynamic_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    payloads = response_item_payloads(items)
    response_types = [payload.get("type") for payload in payloads]
    function_calls = [
        payload
        for payload in payloads
        if payload.get("type") == "function_call"
        and payload.get("call_id") == DYNAMIC_CALL_ID
    ]
    function_outputs = [
        payload
        for payload in payloads
        if payload.get("type") == "function_call_output"
        and payload.get("call_id") == DYNAMIC_CALL_ID
    ]
    serialized_calls = json.dumps(function_calls, ensure_ascii=False)
    serialized_outputs = json.dumps(function_outputs, ensure_ascii=False)
    return {
        "line_count": len(items),
        "response_types": response_types,
        "dynamic_function_call_count": len(function_calls),
        "dynamic_function_output_count": len(function_outputs),
        "dynamic_function_call_ids": [
            item.get("call_id") for item in function_calls
        ],
        "dynamic_function_output_call_ids": [
            item.get("call_id") for item in function_outputs
        ],
        "dynamic_call_contains_namespace": TOOL_NAMESPACE in serialized_calls,
        "dynamic_call_contains_tool_name": TOOL_NAME in serialized_calls,
        "dynamic_call_contains_arguments": "create" in serialized_calls,
        "dynamic_output_contains_response_text": DYNAMIC_RESPONSE_TEXT
        in serialized_outputs,
        "has_expected_dynamic_call": any(
            item.get("call_id") == DYNAMIC_CALL_ID
            and item.get("namespace") == TOOL_NAMESPACE
            and item.get("name") == TOOL_NAME
            and "create" in json.dumps(item.get("arguments"), ensure_ascii=False)
            for item in function_calls
        ),
        "has_expected_dynamic_output": any(
            item.get("call_id") == DYNAMIC_CALL_ID
            and DYNAMIC_RESPONSE_TEXT
            in json.dumps(item.get("output"), ensure_ascii=False)
            for item in function_outputs
        ),
    }


def summarize_original_dynamic_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    sessions_root = codex_home / "sessions"
    rollout_paths = sorted(sessions_root.rglob("*.jsonl"))
    ignored_jsonl_paths = sorted(
        path.relative_to(codex_home).as_posix()
        for path in codex_home.rglob("*.jsonl")
        if path not in rollout_paths
    )
    all_items: list[dict[str, Any]] = []
    rollouts = []
    for path in rollout_paths:
        lines = read_json_lines(path)
        all_items.extend(lines)
        rollouts.append(
            {
                "path": path.relative_to(codex_home).as_posix(),
                "line_count": len(lines),
            }
        )
    summary = summarize_dynamic_sources(all_items)
    summary.update(
        {
            "codex_home": str(codex_home),
            "rollouts": rollouts,
            "ignored_jsonl_paths": ignored_jsonl_paths,
        }
    )
    return summary


def summarize_chat_dynamic_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_dynamic_sources([]),
            "timeline": {},
        }
    package = packages[0]
    journal_lines = read_json_lines(package / "journal.ndjson")
    source_items = [source_payload_from_journal_line(line) for line in journal_lines]
    timeline_lines = read_json_lines(package / "timeline.ndjson")
    timeline_source_response_types = [
        (line.get("body") or {}).get("source_response_type") for line in timeline_lines
    ]
    timeline_summary = {
        "line_count": len(timeline_lines),
        "event_types": [line.get("type") for line in timeline_lines],
        "source_response_types": timeline_source_response_types,
        "dynamic_call_event_count": sum(
            1 for value in timeline_source_response_types if value == "function_call"
        ),
        "dynamic_output_event_count": sum(
            1
            for value in timeline_source_response_types
            if value == "function_call_output"
        ),
        "tool_call_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "tool_call"
        ),
        "tool_output_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "tool_output"
        ),
    }
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "package": str(package),
        "journal": summarize_dynamic_sources(source_items),
        "timeline": timeline_summary,
    }


def safe_summary(label: str, callback: Any) -> dict[str, Any]:
    try:
        value = callback()
        if isinstance(value, dict):
            return value
        return {"value": value}
    except Exception as exc:  # pragma: no cover - diagnostic path
        return {
            "summary_error": label,
            "error_type": type(exc).__name__,
            "error": str(exc),
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

    with ToolSearchDynamicRoutingResponsesServer() as mock_server:
        write_search_capable_mock_config(codex_home, mock_server.url)
        client: JsonRpcClient | None = None
        stderr = ""
        error_info: dict[str, Any] | None = None
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        turn_start_result: dict[str, Any] = {}
        dynamic_started: dict[str, Any] = {}
        dynamic_request: dict[str, Any] = {}
        dynamic_completed: dict[str, Any] = {}
        turn_completed_notification: dict[str, Any] = {}
        thread_read_response: dict[str, Any] = {}
        thread_list_response: dict[str, Any] = {}
        started_thread_id: str | None = None
        try:
            client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
            initialize_response = send_initialize(client, 1)
            started_thread_id, thread_start_response = send_thread_start_with_dynamic_tools(
                client,
                2,
                workspace,
            )
            turn_start_result = send_turn_start(
                client,
                3,
                started_thread_id,
                "client-user-message-tool-search-dynamic-routing",
                USER_TEXT,
            )
            dynamic_request = receive_dynamic_request(client, timeout_seconds=30)
            dynamic_started = find_received_dynamic_item(
                client.received,
                "item/started",
            ) or receive_dynamic_item(
                client,
                "item/started",
                timeout_seconds=5,
            )
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": dynamic_request.get("id"),
                    "result": dynamic_tool_response(),
                }
            )
            dynamic_completed = receive_dynamic_item(
                client,
                "item/completed",
                timeout_seconds=30,
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed",
                timeout_seconds=90,
            )
            thread_read_response = send_thread_read(client, 4, started_thread_id)
            thread_list_response = send_thread_list(client, 5)
        except BaseException as exc:  # pragma: no cover - diagnostic path
            error_info = {
                "type": type(exc).__name__,
                "message": str(exc),
                "traceback": "".join(
                    traceback.format_exception(type(exc), exc, exc.__traceback__)
                ),
            }
        finally:
            if client is not None:
                stderr = client.close()

        result = {
            "tree": tree_name,
            "ok": error_info is None,
            "error": error_info,
            "command": client.command if client is not None else [str(codex_bin)],
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "mock_server_summary": mock_server.summary(),
            "initialize_response": initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_result": turn_start_result,
            "dynamic_started": dynamic_started,
            "dynamic_request": dynamic_request,
            "dynamic_completed": dynamic_completed,
            "normalized_dynamic_started": normalize_dynamic_item(dynamic_started),
            "normalized_dynamic_request": normalize_dynamic_request(dynamic_request),
            "normalized_dynamic_completed": normalize_dynamic_item(dynamic_completed),
            "turn_completed_notification": turn_completed_notification,
            "thread_read_response": thread_read_response,
            "thread_list_response": thread_list_response,
            "normalized_thread_read": normalize_thread_read_for_dynamic(
                thread_read_response
            ),
            "normalized_thread_list": normalize_thread_list_response(
                thread_list_response,
                started_thread_id,
            ),
            "jsonrpc_sent": client.sent if client is not None else [],
            "jsonrpc_received": client.received if client is not None else [],
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode if client is not None else None,
        }
        if tree_name == "chat-backend":
            result["chat_package_summary"] = safe_summary(
                "chat_package_summary",
                lambda: summarize_chat_packages(chat_root),
            )
            result["chat_tool_search_storage"] = safe_summary(
                "chat_tool_search_storage",
                lambda: summarize_chat_tool_search_package(chat_root),
            )
            result["chat_dynamic_storage"] = safe_summary(
                "chat_dynamic_storage",
                lambda: summarize_chat_dynamic_package(chat_root),
            )
        else:
            result["original_storage_summary"] = safe_summary(
                "original_storage_summary",
                lambda: summarize_original_storage(codex_home),
            )
            result["original_tool_search_storage"] = safe_summary(
                "original_tool_search_storage",
                lambda: summarize_original_tool_search_storage(codex_home),
            )
            result["original_dynamic_storage"] = safe_summary(
                "original_dynamic_storage",
                lambda: summarize_original_dynamic_storage(codex_home),
            )
        return result


def write_partial_result(
    output_dir: pathlib.Path,
    tree_name: str,
    result: dict[str, Any],
) -> None:
    if tree_name == "chat-backend":
        path = output_dir / "chat-backend/tool-search-dynamic-routing-response.json"
    else:
        path = output_dir / "original/tool-search-dynamic-routing-response.json"
    write_json(path, result)


def failure_summary(
    output_dir: pathlib.Path,
    binary_checks: dict[str, Any],
    original_result: dict[str, Any] | None,
    chat_result: dict[str, Any] | None,
) -> dict[str, Any]:
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-tool-search-dynamic-routing-smoke",
        "status": "failed-before-parity-summary",
        "binary_checks": binary_checks,
        "original_ok": bool((original_result or {}).get("ok")),
        "chat_backend_ok": bool((chat_result or {}).get("ok")),
        "original_error": (original_result or {}).get("error"),
        "chat_backend_error": (chat_result or {}).get("error"),
        "diagnostic_files": [],
        "not_yet_proven": [
            "dynamic tool follow-up execution routing after discovery",
            "broader MCP/app-search variants",
            "subagent activity",
            "inter-agent communication",
            "detached/interrupted review-mode variants",
            "broader web-search parity",
            "performance and final user-indistinguishability",
        ],
    }
    if original_result is not None:
        summary["diagnostic_files"].append(
            "original/tool-search-dynamic-routing-response.json"
        )
    if chat_result is not None:
        summary["diagnostic_files"].append(
            "chat-backend/tool-search-dynamic-routing-response.json"
        )
    write_json(output_dir / "summary.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-tool-search-dynamic-routing-smoke-"
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
    write_partial_result(output_dir, "original", original_result)
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )
    write_partial_result(output_dir, "chat-backend", chat_result)

    if not original_result.get("ok") or not chat_result.get("ok"):
        failure_summary(output_dir, binary_checks, original_result, chat_result)
        return 1

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_tool_search = original_result["original_tool_search_storage"]
    chat_tool_search = chat_result["chat_tool_search_storage"]["journal"]
    original_dynamic = original_result["original_dynamic_storage"]
    chat_dynamic_storage = chat_result["chat_dynamic_storage"]
    chat_dynamic = chat_dynamic_storage["journal"]
    chat_dynamic_timeline = chat_dynamic_storage["timeline"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]
    original_dynamic_request = original_result["normalized_dynamic_request"]
    chat_dynamic_request = chat_result["normalized_dynamic_request"]
    original_dynamic_started = original_result["normalized_dynamic_started"]
    chat_dynamic_started = chat_result["normalized_dynamic_started"]
    original_dynamic_completed = original_result["normalized_dynamic_completed"]
    chat_dynamic_completed = chat_result["normalized_dynamic_completed"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-tool-search-dynamic-routing-smoke",
        "binary_checks": binary_checks,
        "original_turn_start_exit_ok": "result"
        in original_result["turn_start_result"]["response"],
        "chat_backend_turn_start_exit_ok": "result"
        in chat_result["turn_start_result"]["response"],
        "normalized_thread_read_equal": original_read == chat_read,
        "normalized_thread_list_equal": original_list == chat_list,
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_response_request_count_is_three": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 3
        ),
        "mock_models_are_search_capable": (
            original_mock["first_response_model"]
            == chat_mock["first_response_model"]
            == MODEL
        ),
        "mock_tool_search_visible_in_first_request": (
            original_mock["first_response_advertises_tool_search"]
            and chat_mock["first_response_advertises_tool_search"]
        ),
        "mock_deferred_tool_hidden_before_search": (
            original_mock["first_response_hides_deferred_tool"]
            and chat_mock["first_response_hides_deferred_tool"]
        ),
        "mock_tool_search_output_reaches_second_request": (
            original_mock["second_response_input_contains_tool_search_output"]
            and chat_mock["second_response_input_contains_tool_search_output"]
        ),
        "mock_tool_search_output_non_empty": (
            original_mock["second_response_tool_search_output_tool_count"] > 0
            and chat_mock["second_response_tool_search_output_tool_count"] > 0
        ),
        "mock_discovered_tools_equal": (
            original_mock["second_response_tool_search_output_tools"]
            == chat_mock["second_response_tool_search_output_tools"]
        ),
        "mock_follow_up_relies_on_tool_search_output_not_direct_injection": (
            original_mock["second_response_direct_tool_still_hidden"]
            and chat_mock["second_response_direct_tool_still_hidden"]
            and original_mock["third_response_direct_tool_still_hidden"]
            and chat_mock["third_response_direct_tool_still_hidden"]
        ),
        "mock_dynamic_output_reaches_third_request": (
            original_mock["third_response_input_contains_dynamic_output"]
            and chat_mock["third_response_input_contains_dynamic_output"]
        ),
        "mock_dynamic_output_contains_call_id": (
            original_mock["third_response_input_contains_dynamic_call_id"]
            and chat_mock["third_response_input_contains_dynamic_call_id"]
        ),
        "mock_dynamic_output_contains_response_text": (
            original_mock["third_response_input_contains_dynamic_response_text"]
            and chat_mock["third_response_input_contains_dynamic_response_text"]
        ),
        "dynamic_started_notifications_equal": (
            original_dynamic_started == chat_dynamic_started
        ),
        "dynamic_request_params_equal": (
            original_dynamic_request == chat_dynamic_request
        ),
        "dynamic_completed_notifications_equal": (
            original_dynamic_completed == chat_dynamic_completed
        ),
        "dynamic_request_has_expected_params": (
            original_dynamic_request["method"] == "item/tool/call"
            and original_dynamic_request["call_id"] == DYNAMIC_CALL_ID
            and original_dynamic_request["namespace"] == TOOL_NAMESPACE
            and original_dynamic_request["tool"] == TOOL_NAME
            and original_dynamic_request["arguments"] == DYNAMIC_ARGUMENTS
            and original_dynamic_request["has_request_id"]
        ),
        "dynamic_completed_has_expected_output": (
            original_dynamic_completed["id"] == DYNAMIC_CALL_ID
            and original_dynamic_completed["status"] == "completed"
            and original_dynamic_completed["success"] is True
            and DYNAMIC_RESPONSE_TEXT
            in json.dumps(
                original_dynamic_completed["content_items"],
                ensure_ascii=False,
            )
        ),
        "original_has_non_empty_tool_search_output": original_tool_search[
            "has_expected_tool_search_output"
        ],
        "chat_journal_has_non_empty_tool_search_output": chat_tool_search[
            "has_expected_tool_search_output"
        ],
        "tool_search_output_tools_equal": original_tool_search[
            "tool_search_output_tools"
        ]
        == chat_tool_search["tool_search_output_tools"],
        "original_has_dynamic_function_call": original_dynamic[
            "has_expected_dynamic_call"
        ],
        "original_has_dynamic_function_output": original_dynamic[
            "has_expected_dynamic_output"
        ],
        "chat_journal_has_dynamic_function_call": chat_dynamic[
            "has_expected_dynamic_call"
        ],
        "chat_journal_has_dynamic_function_output": chat_dynamic[
            "has_expected_dynamic_output"
        ],
        "dynamic_function_call_counts_equal": original_dynamic[
            "dynamic_function_call_count"
        ]
        == chat_dynamic["dynamic_function_call_count"],
        "dynamic_function_output_counts_equal": original_dynamic[
            "dynamic_function_output_count"
        ]
        == chat_dynamic["dynamic_function_output_count"],
        "dynamic_function_call_ids_equal": original_dynamic[
            "dynamic_function_call_ids"
        ]
        == chat_dynamic["dynamic_function_call_ids"],
        "dynamic_function_output_call_ids_equal": original_dynamic[
            "dynamic_function_output_call_ids"
        ]
        == chat_dynamic["dynamic_function_output_call_ids"],
        "line_counts_equal": original_dynamic["line_count"]
        == chat_dynamic["line_count"],
        "chat_timeline_has_dynamic_tool_call_mapping": (
            chat_dynamic_timeline.get("dynamic_call_event_count", 0) >= 1
            and chat_dynamic_timeline.get("tool_call_event_count", 0) >= 2
        ),
        "chat_timeline_has_dynamic_tool_output_mapping": (
            chat_dynamic_timeline.get("dynamic_output_event_count", 0) >= 1
            and chat_dynamic_timeline.get("tool_output_event_count", 0) >= 2
        ),
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_dynamic_request": original_dynamic_request,
        "chat_backend_dynamic_request": chat_dynamic_request,
        "original_dynamic_started": original_dynamic_started,
        "chat_backend_dynamic_started": chat_dynamic_started,
        "original_dynamic_completed": original_dynamic_completed,
        "chat_backend_dynamic_completed": chat_dynamic_completed,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_tool_search_storage": original_tool_search,
        "chat_tool_search_storage": chat_result["chat_tool_search_storage"],
        "original_dynamic_storage": original_dynamic,
        "chat_dynamic_storage": chat_dynamic_storage,
        "chat_package_summary": chat_result["chat_package_summary"],
        "not_yet_proven": [
            "broader MCP/app-search variants",
            "subagent activity",
            "inter-agent communication",
            "detached/interrupted review-mode variants",
            "broader web-search parity",
            "performance and final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/tool-search-dynamic-routing-response.json", original_result)
    write_json(
        output_dir / "chat-backend/tool-search-dynamic-routing-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Tool Search Dynamic Routing Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API under model `{MODEL}`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, public spec candidates, backend mapping, parity matrix, current
data-fidelity report, persisted item inventory, discovery smoke evidence, and
source-backed Codex dynamic-tool routing code were read.

## Scope

This smoke closes the narrow routing gap after non-empty tool-search discovery:

- the first model request advertises `tool_search`;
- the deferred dynamic tool is hidden before discovery;
- the second model request contains non-empty `tool_search_output.tools`;
- the model calls discovered dynamic tool `{TOOL_NAMESPACE}.{TOOL_NAME}`;
- app-server sends `item/tool/call` with the expected namespace/tool/arguments;
- the client returns a valid `DynamicToolCallResponse`;
- the third model request receives the dynamic tool result as
  `function_call_output`;
- the `.chat` backend preserves the same durable `FunctionCall` /
  `FunctionCallOutput` facts in journal and maps them to neutral `tool_call` /
  `tool_output` timeline events.

`DynamicToolCallRequest` and `DynamicToolCallResponse` are live-only
`EventMsg` variants in the pinned original Codex persistence policy. This smoke
therefore does not claim they are durable rollout facts; it proves the live
route and the resulting durable response items are equivalent.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- normalized original vs `.chat` `thread/read` equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` equal: `{summary['normalized_thread_list_equal']}`
- both model runs made three Responses requests: `{summary['mock_response_request_count_is_three']}`
- non-empty discovery output reached second request: `{summary['mock_tool_search_output_non_empty']}`
- discovered tools equal across backends: `{summary['mock_discovered_tools_equal']}`
- dynamic request params equal: `{summary['dynamic_request_params_equal']}`
- dynamic request has expected params: `{summary['dynamic_request_has_expected_params']}`
- dynamic completion notifications equal: `{summary['dynamic_completed_notifications_equal']}`
- dynamic completion has expected output: `{summary['dynamic_completed_has_expected_output']}`
- dynamic output reached third model request: `{summary['mock_dynamic_output_reaches_third_request']}`
- `.chat` journal has dynamic function call: `{summary['chat_journal_has_dynamic_function_call']}`
- `.chat` journal has dynamic function output: `{summary['chat_journal_has_dynamic_function_output']}`
- `.chat` timeline maps dynamic call/output neutrally: `{summary['chat_timeline_has_dynamic_tool_call_mapping'] and summary['chat_timeline_has_dynamic_tool_output_mapping']}`
- rollout/journal durable line counts equal: `{summary['line_counts_equal']}`

## Dynamic Request

```json
{json.dumps(original_dynamic_request, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/tool-search-dynamic-routing-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/tool-search-dynamic-routing-response.json
```

## Not Yet Proven

This smoke does not prove broader MCP/app-search variants, subagent activity,
inter-agent communication, detached/interrupted review-mode variants, broader
web-search parity, performance, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    required = [
        "original_turn_start_exit_ok",
        "chat_backend_turn_start_exit_ok",
        "normalized_thread_read_equal",
        "normalized_thread_list_equal",
        "mock_response_request_counts_equal",
        "mock_response_request_count_is_three",
        "mock_models_are_search_capable",
        "mock_tool_search_visible_in_first_request",
        "mock_deferred_tool_hidden_before_search",
        "mock_tool_search_output_reaches_second_request",
        "mock_tool_search_output_non_empty",
        "mock_discovered_tools_equal",
        "mock_follow_up_relies_on_tool_search_output_not_direct_injection",
        "mock_dynamic_output_reaches_third_request",
        "mock_dynamic_output_contains_call_id",
        "mock_dynamic_output_contains_response_text",
        "dynamic_started_notifications_equal",
        "dynamic_request_params_equal",
        "dynamic_completed_notifications_equal",
        "dynamic_request_has_expected_params",
        "dynamic_completed_has_expected_output",
        "original_has_non_empty_tool_search_output",
        "chat_journal_has_non_empty_tool_search_output",
        "tool_search_output_tools_equal",
        "original_has_dynamic_function_call",
        "original_has_dynamic_function_output",
        "chat_journal_has_dynamic_function_call",
        "chat_journal_has_dynamic_function_output",
        "dynamic_function_call_counts_equal",
        "dynamic_function_output_counts_equal",
        "dynamic_function_call_ids_equal",
        "dynamic_function_output_call_ids_equal",
        "line_counts_equal",
        "chat_timeline_has_dynamic_tool_call_mapping",
        "chat_timeline_has_dynamic_tool_output_mapping",
    ]
    return 0 if all(summary[key] for key in required) else 1


if __name__ == "__main__":
    sys.exit(main())
