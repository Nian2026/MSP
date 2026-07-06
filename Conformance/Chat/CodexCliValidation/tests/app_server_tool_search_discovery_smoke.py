#!/usr/bin/env python3
"""Run app-server tool-search discovery parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both vendored source trees. It covers the previously open slice that
the older tool-search smoke did not prove: a search-capable model advertises
`tool_search`, a deferred dynamic tool is hidden from the first model request,
the client-executed search returns a non-empty discovery result, and the
original backend and `.chat` backend persist the same durable facts.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
import threading
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


USER_TEXT = "Find the recurring automation dynamic command."
ASSISTANT_TEXT = "Tool-search discovery final answer from mock model."
MODEL = "gpt-5.4"
TOOL_SEARCH_CALL_ID = "call-tool-search-discovery"
TOOL_NAMESPACE = "codex_app"
TOOL_NAMESPACE_DESCRIPTION = "Automation tools."
TOOL_NAME = "automation_update"
TOOL_DESCRIPTION = "Create, update, view, or delete recurring automations."
TOOL_QUERY = "recurring automations"


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
                "input_tokens": 31,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 29,
                "output_tokens_details": {"reasoning_tokens": 0},
                "total_tokens": 60,
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


def tool_search_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            ev_tool_search_call(),
            ev_completed(response_id),
        ]
    )


def final_sse_response(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-tool-search-discovery-final",
                    "content": [{"type": "output_text", "text": ASSISTANT_TEXT}],
                },
            },
            ev_completed(response_id),
        ]
    )


class ToolSearchDiscoveryResponsesServer(MockResponsesServer):
    def __init__(self) -> None:
        super().__init__(ASSISTANT_TEXT)
        self._lock = threading.Lock()

    def next_sse_body(self) -> bytes:
        with self._lock:
            self._counter += 1
            counter = self._counter
        if counter == 1:
            return tool_search_sse_response("resp-tool-search-discovery-1")
        return final_sse_response(f"resp-tool-search-discovery-{counter}")

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        bodies = [request["json"] for request in response_requests]
        first_body = bodies[0] if bodies else {}
        second_body = bodies[1] if len(bodies) > 1 else {}
        first_tools = first_body.get("tools", [])
        second_tools = second_body.get("tools", [])
        first_tool_names = tool_names_from_tools(first_tools)
        second_tool_names = tool_names_from_tools(second_tools)
        first_tools_serialized = json.dumps(first_tools, ensure_ascii=False)
        second_tools_serialized = json.dumps(second_tools, ensure_ascii=False)
        second_output = find_tool_search_output(second_body, TOOL_SEARCH_CALL_ID)
        discovered_tools = (second_output or {}).get("tools") or []
        discovered_tools_serialized = json.dumps(discovered_tools, ensure_ascii=False)
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
        }


def tool_names_from_tools(tools: Any) -> list[str]:
    if not isinstance(tools, list):
        return []
    names = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name") or tool.get("type")
        if isinstance(name, str):
            names.append(name)
    return names


def find_tool_search_output(value: Any, call_id: str) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if (
            value.get("type") == "tool_search_output"
            and value.get("call_id") == call_id
        ):
            return value
        for child in value.values():
            found = find_tool_search_output(child, call_id)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_tool_search_output(child, call_id)
            if found is not None:
                return found
    return None


def dynamic_tools() -> list[dict[str, Any]]:
    return [
        {
            "type": "namespace",
            "name": TOOL_NAMESPACE,
            "description": TOOL_NAMESPACE_DESCRIPTION,
            "tools": [
                {
                    "type": "function",
                    "name": TOOL_NAME,
                    "description": TOOL_DESCRIPTION,
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "mode": {"type": "string"},
                        },
                        "required": ["mode"],
                        "additionalProperties": False,
                    },
                    "deferLoading": True,
                }
            ],
        }
    ]


def write_search_capable_mock_config(
    codex_home: pathlib.Path,
    server_url: str,
) -> None:
    models_json = (
        ORIGINAL_CODEX_RS / "models-manager/models.json"
    ).resolve()
    config = f"""
model = {json.dumps(MODEL)}
model_catalog_json = {json.dumps(str(models_json))}
approval_policy = "never"
sandbox_mode = "read-only"

model_provider = "mock_provider"

[model_providers.mock_provider]
name = "Mock provider for tool-search discovery smoke"
base_url = {json.dumps(server_url + "/v1")}
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def send_thread_start_with_dynamic_tools(
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
                "model": MODEL,
                "dynamicTools": dynamic_tools(),
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    thread_id = ((response.get("result") or {}).get("thread") or {}).get("id")
    return thread_id, response


def normalize_thread_read_for_tool_search(response: dict[str, Any]) -> dict[str, Any]:
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
        "contains_tool_search_call_id": TOOL_SEARCH_CALL_ID in serialized,
        "contains_tool_search_tool_name": TOOL_NAME in serialized,
    }


def source_payload_from_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def summarize_tool_search_sources(items: list[dict[str, Any]]) -> dict[str, Any]:
    response_types: list[str] = []
    tool_search_calls: list[dict[str, Any]] = []
    tool_search_outputs: list[dict[str, Any]] = []
    for item in items:
        if item.get("type") != "response_item":
            continue
        payload = item.get("payload") or {}
        nested_type = payload.get("type")
        response_types.append(nested_type)
        if nested_type == "tool_search_call":
            tool_search_calls.append(payload)
        elif nested_type == "tool_search_output":
            tool_search_outputs.append(payload)

    output_tools = []
    for output in tool_search_outputs:
        output_tools.extend(output.get("tools") or [])

    serialized_outputs = json.dumps(tool_search_outputs, ensure_ascii=False)
    return {
        "line_count": len(items),
        "response_types": response_types,
        "tool_search_call_count": len(tool_search_calls),
        "tool_search_output_count": len(tool_search_outputs),
        "tool_search_call_ids": [
            item.get("call_id") for item in tool_search_calls
        ],
        "tool_search_output_call_ids": [
            item.get("call_id") for item in tool_search_outputs
        ],
        "tool_search_queries": [
            (item.get("arguments") or {}).get("query") for item in tool_search_calls
        ],
        "tool_search_executions": [
            item.get("execution") for item in tool_search_calls + tool_search_outputs
        ],
        "tool_search_output_statuses": [
            item.get("status") for item in tool_search_outputs
        ],
        "tool_search_output_tool_count": len(output_tools),
        "tool_search_output_tools": output_tools,
        "tool_search_output_contains_namespace": TOOL_NAMESPACE in serialized_outputs,
        "tool_search_output_contains_tool_name": TOOL_NAME in serialized_outputs,
        "tool_search_output_contains_schema_term": "mode" in serialized_outputs,
        "has_expected_tool_search_call": any(
            item.get("call_id") == TOOL_SEARCH_CALL_ID
            and (item.get("arguments") or {}).get("query") == TOOL_QUERY
            for item in tool_search_calls
        ),
        "has_expected_tool_search_output": any(
            item.get("call_id") == TOOL_SEARCH_CALL_ID
            and item.get("status") == "completed"
            and item.get("execution") == "client"
            and (item.get("tools") or [])
            for item in tool_search_outputs
        ),
    }


def summarize_original_tool_search_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    rollout_paths = sorted(codex_home.rglob("*.jsonl"))
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
    summary = summarize_tool_search_sources(all_items)
    summary.update({"codex_home": str(codex_home), "rollouts": rollouts})
    return summary


def summarize_chat_tool_search_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    if not packages:
        return {
            "chat_root": str(chat_root),
            "package_count": 0,
            "journal": summarize_tool_search_sources([]),
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
        "tool_search_call_event_count": sum(
            1 for value in timeline_source_response_types if value == "tool_search_call"
        ),
        "tool_search_output_event_count": sum(
            1 for value in timeline_source_response_types if value == "tool_search_output"
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
        "journal": summarize_tool_search_sources(source_items),
        "timeline": timeline_summary,
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

    with ToolSearchDiscoveryResponsesServer() as mock_server:
        write_search_capable_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
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
                "client-user-message-tool-search-discovery",
                USER_TEXT,
            )
            thread_read_response = send_thread_read(client, 4, started_thread_id)
            thread_list_response = send_thread_list(client, 5)
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
            "turn_start_result": turn_start_result,
            "thread_read_response": thread_read_response,
            "thread_list_response": thread_list_response,
            "normalized_thread_read": normalize_thread_read_for_tool_search(
                thread_read_response
            ),
            "normalized_thread_list": normalize_thread_list_response(
                thread_list_response,
                started_thread_id,
            ),
            "jsonrpc_sent": client.sent,
            "jsonrpc_received": client.received,
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }
        if tree_name == "chat-backend":
            result["chat_package_summary"] = summarize_chat_packages(chat_root)
            result["chat_tool_search_storage"] = summarize_chat_tool_search_package(
                chat_root
            )
        else:
            result["original_storage_summary"] = summarize_original_storage(codex_home)
            result["original_tool_search_storage"] = (
                summarize_original_tool_search_storage(codex_home)
            )
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-tool-search-discovery-smoke-"
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

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_storage = original_result["original_tool_search_storage"]
    chat_storage = chat_result["chat_tool_search_storage"]
    chat_journal = chat_storage["journal"]
    chat_timeline = chat_storage["timeline"]
    original_read = original_result["normalized_thread_read"]
    chat_read = chat_result["normalized_thread_read"]
    original_list = original_result["normalized_thread_list"]
    chat_list = chat_result["normalized_thread_list"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-tool-search-discovery-smoke",
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
        "mock_response_request_count_is_two": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 2
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
        "mock_tool_search_output_contains_tool_name": (
            original_mock["second_response_tool_search_output_contains_tool_name"]
            and chat_mock["second_response_tool_search_output_contains_tool_name"]
        ),
        "mock_tool_search_output_contains_namespace": (
            original_mock["second_response_tool_search_output_contains_namespace"]
            and chat_mock["second_response_tool_search_output_contains_namespace"]
        ),
        "mock_tool_search_output_contains_schema_term": (
            original_mock["second_response_tool_search_output_contains_schema_term"]
            and chat_mock["second_response_tool_search_output_contains_schema_term"]
        ),
        "mock_discovered_tools_equal": (
            original_mock["second_response_tool_search_output_tools"]
            == chat_mock["second_response_tool_search_output_tools"]
        ),
        "mock_follow_up_relies_on_tool_search_output_not_direct_injection": (
            original_mock["second_response_direct_tool_still_hidden"]
            and chat_mock["second_response_direct_tool_still_hidden"]
        ),
        "original_has_tool_search_call": original_storage[
            "has_expected_tool_search_call"
        ],
        "original_has_non_empty_tool_search_output": original_storage[
            "has_expected_tool_search_output"
        ],
        "chat_journal_has_tool_search_call": chat_journal[
            "has_expected_tool_search_call"
        ],
        "chat_journal_has_non_empty_tool_search_output": chat_journal[
            "has_expected_tool_search_output"
        ],
        "tool_search_call_counts_equal": original_storage["tool_search_call_count"]
        == chat_journal["tool_search_call_count"],
        "tool_search_output_counts_equal": original_storage["tool_search_output_count"]
        == chat_journal["tool_search_output_count"],
        "tool_search_output_tools_equal": original_storage[
            "tool_search_output_tools"
        ]
        == chat_journal["tool_search_output_tools"],
        "tool_search_call_ids_equal": original_storage["tool_search_call_ids"]
        == chat_journal["tool_search_call_ids"],
        "tool_search_output_call_ids_equal": original_storage[
            "tool_search_output_call_ids"
        ]
        == chat_journal["tool_search_output_call_ids"],
        "tool_search_queries_equal": original_storage["tool_search_queries"]
        == chat_journal["tool_search_queries"],
        "line_counts_equal": original_storage["line_count"] == chat_journal["line_count"],
        "chat_timeline_has_tool_search_call_mapping": chat_timeline.get(
            "tool_search_call_event_count",
            0,
        )
        >= 1
        and chat_timeline.get("tool_call_event_count", 0) >= 1,
        "chat_timeline_has_tool_search_output_mapping": chat_timeline.get(
            "tool_search_output_event_count",
            0,
        )
        >= 1
        and chat_timeline.get("tool_output_event_count", 0) >= 1,
        "original_normalized_thread_read": original_read,
        "chat_backend_normalized_thread_read": chat_read,
        "original_normalized_thread_list": original_list,
        "chat_backend_normalized_thread_list": chat_list,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_tool_search_storage": original_storage,
        "chat_tool_search_storage": chat_storage,
        "chat_package_summary": chat_result["chat_package_summary"],
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

    write_json(output_dir / "original/tool-search-discovery-response.json", original_result)
    write_json(output_dir / "chat-backend/tool-search-discovery-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Tool Search Discovery Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API under model `{MODEL}`, loaded from the bundled model catalog so
Codex uses a search-capable model metadata path.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
persisted item inventory, prior tool-search smoke, and source-backed Codex
`search_tool.rs` behavior were read.

## Scope

This smoke closes the narrow discovery part that the earlier
`app_server_tool_search_smoke.py` intentionally left open:

- the first model request advertises `tool_search`;
- the deferred dynamic tool is not directly exposed before search;
- the second model request contains a non-empty `tool_search_output.tools`;
- the discovered namespace/function/schema is identical for original and
  `.chat` backends;
- the `.chat` backend preserves the same durable source items in journal and
  maps them to neutral `tool_call` / `tool_output` timeline events.

It does not prove dynamic tool follow-up execution routing after discovery.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- normalized original vs `.chat` `thread/read` equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` equal: `{summary['normalized_thread_list_equal']}`
- both first requests used search-capable model `{MODEL}`: `{summary['mock_models_are_search_capable']}`
- first request advertised `tool_search`: `{summary['mock_tool_search_visible_in_first_request']}`
- deferred tool hidden before search: `{summary['mock_deferred_tool_hidden_before_search']}`
- non-empty `tool_search_output` reached second request: `{summary['mock_tool_search_output_non_empty']}`
- discovery output contains namespace `{TOOL_NAMESPACE}`: `{summary['mock_tool_search_output_contains_namespace']}`
- discovery output contains tool `{TOOL_NAME}`: `{summary['mock_tool_search_output_contains_tool_name']}`
- discovery outputs equal across backends: `{summary['mock_discovered_tools_equal']}`
- `.chat` journal has non-empty `tool_search_output`: `{summary['chat_journal_has_non_empty_tool_search_output']}`
- `.chat` timeline has neutral tool-search mappings: `{summary['chat_timeline_has_tool_search_call_mapping'] and summary['chat_timeline_has_tool_search_output_mapping']}`

## Discovered Tools

```json
{json.dumps(original_mock['second_response_tool_search_output_tools'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/tool-search-discovery-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/tool-search-discovery-response.json
```

## Not Yet Proven

This smoke does not prove dynamic tool follow-up execution routing, broader
MCP/app-search variants, subagent activity, detached/interrupted variants,
broader web-search parity, performance, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    required = [
        "original_turn_start_exit_ok",
        "chat_backend_turn_start_exit_ok",
        "normalized_thread_read_equal",
        "normalized_thread_list_equal",
        "mock_response_request_counts_equal",
        "mock_response_request_count_is_two",
        "mock_models_are_search_capable",
        "mock_tool_search_visible_in_first_request",
        "mock_deferred_tool_hidden_before_search",
        "mock_tool_search_output_reaches_second_request",
        "mock_tool_search_output_non_empty",
        "mock_tool_search_output_contains_tool_name",
        "mock_tool_search_output_contains_namespace",
        "mock_tool_search_output_contains_schema_term",
        "mock_discovered_tools_equal",
        "mock_follow_up_relies_on_tool_search_output_not_direct_injection",
        "original_has_tool_search_call",
        "original_has_non_empty_tool_search_output",
        "chat_journal_has_tool_search_call",
        "chat_journal_has_non_empty_tool_search_output",
        "tool_search_call_counts_equal",
        "tool_search_output_counts_equal",
        "tool_search_output_tools_equal",
        "tool_search_call_ids_equal",
        "tool_search_output_call_ids_equal",
        "tool_search_queries_equal",
        "line_counts_equal",
        "chat_timeline_has_tool_search_call_mapping",
        "chat_timeline_has_tool_search_output_mapping",
    ]
    return 0 if all(summary[key] for key in required) else 1


if __name__ == "__main__":
    sys.exit(main())
