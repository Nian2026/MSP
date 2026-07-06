#!/usr/bin/env python3
"""Run request_permissions parity smoke for original vs `.chat` backend."""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import pathlib
import sys
import threading
from typing import Any

from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import JsonRpcClient
from app_server_durable_turn_smoke import ensure_binary
from app_server_durable_turn_smoke import read_json_lines
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json


USER_TEXT = "Run the request_permissions approval smoke."
SECOND_USER_TEXT = "Use the session permission grant to write a file."
FIRST_FINAL_TEXT = "Request permissions approval smoke first turn complete."
SECOND_FINAL_TEXT = "Request permissions session grant command complete."
CALL_ID = "call-request-permissions"
COMMAND_CALL_ID = "call-request-permissions-session-command"
REQUEST_REASON = "Select a workspace root"
COMMAND_TEXT = (
    "printf 'SESSION_GRANT_WRITE_OK\\n' > session-grant.txt; "
    "cat session-grant.txt"
)
COMMAND_OUTPUT_TEXT = "SESSION_GRANT_WRITE_OK"


def serialized_contains_scope(serialized: str, scope: str) -> bool:
    patterns = [
        f'"scope":"{scope}"',
        f'"scope": "{scope}"',
        f'\\"scope\\":\\"{scope}\\"',
        f'\\"scope\\": \\"{scope}\\"',
    ]
    return any(pattern in serialized for pattern in patterns)


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
                "input_tokens": 0,
                "input_tokens_details": None,
                "output_tokens": 0,
                "output_tokens_details": None,
                "total_tokens": 0,
            },
        },
    }


def ev_request_permissions_call(response_id: str, call_id: str) -> bytes:
    arguments = json.dumps(
        {
            "reason": REQUEST_REASON,
            "permissions": {
                "file_system": {
                    "write": [".", "../shared"],
                },
            },
        },
        separators=(",", ":"),
    )
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": call_id,
                    "name": "request_permissions",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_shell_command_call(response_id: str, call_id: str, command: str) -> bytes:
    arguments = json.dumps(
        {
            "command": command,
            "workdir": None,
            "timeout_ms": 10000,
        },
        separators=(",", ":"),
    )
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": call_id,
                    "name": "shell_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message(response_id: str, message_id: str, text: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": message_id,
                    "content": [{"type": "output_text", "text": text}],
                },
            },
            ev_completed(response_id),
        ]
    )


class RequestPermissionsResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_request_permissions_call("resp-request-permissions-call", CALL_ID),
            ev_final_message(
                "resp-request-permissions-final",
                "msg-request-permissions-final",
                FIRST_FINAL_TEXT,
            ),
            ev_shell_command_call(
                "resp-request-permissions-command",
                COMMAND_CALL_ID,
                COMMAND_TEXT,
            ),
            ev_final_message(
                "resp-request-permissions-command-final",
                "msg-request-permissions-command-final",
                SECOND_FINAL_TEXT,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "RequestPermissionsResponsesServer":
        handler = self._make_handler()
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self._httpd.mock_server = self  # type: ignore[attr-defined]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)

    @property
    def url(self) -> str:
        assert self._httpd is not None
        host, port = self._httpd.server_address
        return f"http://{host}:{port}"

    def next_sse_body(self) -> bytes:
        with self._lock:
            index = len(
                [request for request in self.requests if request["path"].endswith("/responses")]
            )
        if index < 1 or index > len(self.responses):
            return ev_final_message(
                "resp-request-permissions-extra",
                "msg-request-permissions-extra",
                "extra request permissions response",
            )
        return self.responses[index - 1]

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        serialized_bodies = [
            json.dumps(request["json"], ensure_ascii=False) for request in response_requests
        ]
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "contains_request_permissions_call": any(
                CALL_ID in body and "request_permissions" in body for body in serialized_bodies
            ),
            "contains_function_call_output": any(
                CALL_ID in body and "function_call_output" in body for body in serialized_bodies
            ),
            "contains_command_function_output": any(
                COMMAND_CALL_ID in body and "function_call_output" in body
                for body in serialized_bodies
            ),
            "contains_granted_file_system_write": any(
                "file_system" in body and "write" in body for body in serialized_bodies
            ),
            "contains_turn_scope": any(
                serialized_contains_scope(body, "turn") for body in serialized_bodies
            ),
            "contains_session_scope": any(
                serialized_contains_scope(body, "session") for body in serialized_bodies
            ),
            "contains_command_output": any(
                COMMAND_OUTPUT_TEXT in body for body in serialized_bodies
            ),
            "contains_first_final_text": any(
                FIRST_FINAL_TEXT in body for body in serialized_bodies
            ),
            "contains_second_final_text": any(
                SECOND_FINAL_TEXT in body for body in serialized_bodies
            ),
        }

    def _make_handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def do_GET(self) -> None:
                if self.path.endswith("/models"):
                    body = json.dumps({"models": []}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_error(404)

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length)
                try:
                    body_json = json.loads(raw_body.decode() or "{}")
                except json.JSONDecodeError:
                    body_json = {"_decode_error": raw_body.decode(errors="replace")}
                server: RequestPermissionsResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
                server.record_request(
                    {
                        "method": "POST",
                        "path": self.path,
                        "json": body_json,
                    }
                )
                if not self.path.endswith("/responses"):
                    self.send_error(404)
                    return
                body = server.next_sse_body()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        return Handler


def write_request_permissions_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "on-request"
sandbox_mode = "read-only"
suppress_unstable_features_warning = true

model_provider = "mock_provider"

[features]
request_permissions_tool = true

[model_providers.mock_provider]
name = "Mock provider for test"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def status_type(value: Any) -> Any:
    if isinstance(value, dict):
        return value.get("type")
    return value


def path_value(value: Any) -> str | None:
    if isinstance(value, dict):
        if "path" in value:
            return path_value(value.get("path"))
        if "value" in value:
            return path_value(value.get("value"))
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    if value is None:
        return None
    return str(value)


def path_role(value: Any, workspace: pathlib.Path) -> str:
    path = path_value(value)
    if not path:
        return "missing"
    candidate = pathlib.Path(path)
    if candidate == workspace:
        return "workspace"
    if candidate == workspace.parent / "shared":
        return "workspace-parent-shared"
    if candidate.is_absolute():
        try:
            return "abs:" + candidate.relative_to(workspace.parent).as_posix()
        except ValueError:
            return "abs:" + candidate.name
    return "relative:" + path


def file_system_entries(file_system: dict[str, Any]) -> list[dict[str, Any]]:
    entries = []
    for entry in file_system.get("entries") or []:
        entries.append(
            {
                "access": entry.get("access"),
                "path_kind": (entry.get("path") or {}).get("kind")
                if isinstance(entry.get("path"), dict)
                else None,
                "raw_path": path_value((entry.get("path") or {}).get("path"))
                if isinstance(entry.get("path"), dict)
                else path_value(entry.get("path")),
            }
        )
    return entries


def normalize_permission_request(
    message: dict[str, Any],
    expected: dict[str, str],
    workspace: pathlib.Path,
) -> dict[str, Any]:
    params = message.get("params") or {}
    permissions = params.get("permissions") or {}
    file_system = permissions.get("fileSystem") or {}
    write_paths = file_system.get("write") or []
    entries = file_system_entries(file_system)
    cwd = path_value(params.get("cwd"))
    return {
        "method": message.get("method"),
        "has_request_id": message.get("id") is not None,
        "thread_id_matches": params.get("threadId") == expected.get("thread_id"),
        "turn_id_matches": params.get("turnId") == expected.get("turn_id"),
        "item_id": params.get("itemId"),
        "item_id_matches": params.get("itemId") == expected.get("call_id"),
        "environment_id": params.get("environmentId"),
        "started_at_ms_present": params.get("startedAtMs") is not None,
        "cwd_present": cwd is not None,
        "cwd_is_absolute": pathlib.Path(cwd).is_absolute() if cwd else False,
        "cwd_role": path_role(cwd, workspace),
        "reason": params.get("reason"),
        "reason_matches": params.get("reason") == REQUEST_REASON,
        "network_present": permissions.get("network") is not None,
        "file_system_present": bool(file_system),
        "write_count": len(write_paths),
        "write_roles": [path_role(path, workspace) for path in write_paths],
        "entries_count": len(entries),
        "entry_accesses": [entry["access"] for entry in entries],
        "entry_roles": [path_role(entry["raw_path"], workspace) for entry in entries],
    }


def normalized_live_sequence(received: list[dict[str, Any]], workspace: pathlib.Path) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/permissions/requestApproval":
            permissions = params.get("permissions") or {}
            file_system = permissions.get("fileSystem") or {}
            sequence.append(
                {
                    "event": "permissionsRequest",
                    "itemId": params.get("itemId"),
                    "reasonMatches": params.get("reason") == REQUEST_REASON,
                    "cwdRole": path_role(params.get("cwd"), workspace),
                    "writeCount": len(file_system.get("write") or []),
                    "writeRoles": [
                        path_role(path, workspace) for path in file_system.get("write") or []
                    ],
                    "entriesCount": len(file_system.get("entries") or []),
                }
            )
        elif method == "serverRequest/resolved":
            sequence.append(
                {
                    "event": "serverRequestResolved",
                    "requestIdPresent": params.get("requestId") is not None,
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    return sequence


def normalized_sequence_has_order(sequence: list[dict[str, Any]]) -> bool:
    events = [event.get("event") for event in sequence]
    try:
        request_index = events.index("permissionsRequest")
        resolved_index = events.index("serverRequestResolved")
        completed_index = events.index("turnCompleted")
    except ValueError:
        return False
    return request_index < resolved_index < completed_index


def normalize_thread_read_visible(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in turn.get("items") or []] for turn in turns
        ],
        "contains_first_final_text": FIRST_FINAL_TEXT in serialized,
        "contains_second_final_text": SECOND_FINAL_TEXT in serialized,
        "contains_command_output": COMMAND_OUTPUT_TEXT in serialized,
        "contains_request_reason": REQUEST_REASON in serialized,
        "contains_call_id": CALL_ID in serialized,
        "contains_command_call_id": COMMAND_CALL_ID in serialized,
    }


def command_items_from_thread_read(response: dict[str, Any]) -> list[dict[str, Any]]:
    thread = ((response.get("result") or {}).get("thread") or {})
    commands = []
    for turn in thread.get("turns") or []:
        for item in turn.get("items") or []:
            if item.get("type") != "commandExecution":
                continue
            output = item.get("aggregatedOutput") or ""
            commands.append(
                {
                    "command": item.get("command"),
                    "source": item.get("source"),
                    "status": status_type(item.get("status")),
                    "exitCode": item.get("exitCode"),
                    "contains_session_grant_output": COMMAND_OUTPUT_TEXT in output,
                }
            )
    return commands


def extract_journal_payloads(journal_lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        (((line.get("source_transport") or {}).get("payload") or {}).get("payload") or {})
        for line in journal_lines
    ]


def summarize_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = extract_journal_payloads(journal_lines)
        serialized_timeline = json.dumps(timeline_lines, ensure_ascii=False)
        serialized_journal = json.dumps(journal_payloads, ensure_ascii=False)
        packages.append(
            {
                "package": str(package),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_has_tool_call": any(
                    line.get("type") == "tool_call" for line in timeline_lines
                ),
                "timeline_has_tool_output": any(
                    line.get("type") == "tool_output" for line in timeline_lines
                ),
                "timeline_has_command_call": any(
                    line.get("type") == "command_call" for line in timeline_lines
                ),
                "timeline_has_command_output": any(
                    line.get("type") == "command_output" for line in timeline_lines
                ),
                "timeline_contains_request_permissions": "request_permissions"
                in serialized_timeline,
                "timeline_contains_command_call_id": COMMAND_CALL_ID in serialized_timeline,
                "timeline_contains_command_output": COMMAND_OUTPUT_TEXT in serialized_timeline,
                "timeline_contains_granted_write": "file_system" in serialized_timeline
                and "write" in serialized_timeline,
                "journal_source_response_types": [
                    payload.get("type") for payload in journal_payloads
                ],
                "journal_function_call_names": [
                    payload.get("name")
                    for payload in journal_payloads
                    if payload.get("type") == "function_call"
                ],
                "journal_function_call_output_call_ids": [
                    payload.get("call_id")
                    for payload in journal_payloads
                    if payload.get("type") == "function_call_output"
                ],
                "journal_has_request_permissions_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "request_permissions"
                    for payload in journal_payloads
                ),
                "journal_has_function_call_output": any(
                    payload.get("type") == "function_call_output"
                    and payload.get("call_id") == CALL_ID
                    for payload in journal_payloads
                ),
                "journal_has_command_function_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("call_id") == COMMAND_CALL_ID
                    for payload in journal_payloads
                ),
                "journal_has_command_function_call_output": any(
                    payload.get("type") == "function_call_output"
                    and payload.get("call_id") == COMMAND_CALL_ID
                    for payload in journal_payloads
                ),
                "journal_contains_request_reason": REQUEST_REASON in serialized_journal,
                "journal_contains_granted_write": "file_system" in serialized_journal
                and "write" in serialized_journal,
                "journal_contains_turn_scope": serialized_contains_scope(
                    serialized_journal,
                    "turn",
                ),
                "journal_contains_session_scope": serialized_contains_scope(
                    serialized_journal,
                    "session",
                ),
                "journal_contains_command_output": COMMAND_OUTPUT_TEXT in serialized_journal,
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
        serialized_lines = json.dumps(lines, ensure_ascii=False)
        rollout_items = [line for line in lines]
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "payload_types": [item.get("type") for item in rollout_items],
                "response_item_types": [
                    ((item.get("payload") or {}).get("type"))
                    for item in rollout_items
                    if item.get("type") == "response_item"
                ],
                "function_call_names": [
                    ((item.get("payload") or {}).get("name"))
                    for item in rollout_items
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call"
                ],
                "function_call_output_call_ids": [
                    ((item.get("payload") or {}).get("call_id"))
                    for item in rollout_items
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call_output"
                ],
                "turn_context_approval_policies": [
                    ((item.get("payload") or {}).get("approval_policy"))
                    for item in rollout_items
                    if item.get("type") == "turn_context"
                ],
                "contains_request_permissions": "request_permissions" in serialized_lines,
                "contains_command_call": COMMAND_CALL_ID in serialized_lines,
                "contains_request_reason": REQUEST_REASON in serialized_lines,
                "contains_granted_write": "file_system" in serialized_lines
                and "write" in serialized_lines,
                "contains_turn_scope": serialized_contains_scope(serialized_lines, "turn"),
                "contains_session_scope": serialized_contains_scope(
                    serialized_lines,
                    "session",
                ),
                "contains_command_output": COMMAND_OUTPUT_TEXT in serialized_lines,
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def first_requested_write_path(permission_request: dict[str, Any]) -> Any:
    params = permission_request.get("params") or {}
    permissions = params.get("permissions") or {}
    file_system = permissions.get("fileSystem") or {}
    write_paths = file_system.get("write") or []
    if not write_paths:
        raise RuntimeError("request_permissions approval request did not include write paths")
    return write_paths[0]


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    scenario_root = run_root / tree_name
    workspace = scenario_root / "workspace"
    codex_home = scenario_root / "codex-home"
    chat_root = scenario_root / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with RequestPermissionsResponsesServer() as mock_server:
        write_request_permissions_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        turn_start_response: dict[str, Any] = {}
        permission_request: dict[str, Any] = {}
        turn_completed_notification: dict[str, Any] = {}
        thread_read_response: dict[str, Any] = {}
        second_turn_start_response: dict[str, Any] = {}
        second_turn_completed_notification: dict[str, Any] = {}
        final_thread_read_response: dict[str, Any] = {}
        try:
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
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
            initialize_response = client.receive_until_response(1, timeout_seconds=30)
            client.send({"jsonrpc": "2.0", "method": "initialized"})

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "thread/start",
                    "params": {
                        "cwd": str(workspace),
                        "ephemeral": False,
                        "historyMode": "legacy",
                        "model": "mock-model",
                    },
                }
            )
            thread_start_response = client.receive_until_response(2, timeout_seconds=30)
            started_thread_id = (
                ((thread_start_response.get("result") or {}).get("thread") or {}).get("id")
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "turn/start",
                    "params": {
                        "threadId": started_thread_id,
                        "clientUserMessageId": "client-user-request-permissions",
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
            turn_start_response = client.receive_until_response(3, timeout_seconds=30)
            turn_id = ((turn_start_response.get("result") or {}).get("turn") or {}).get("id")

            permission_request = client.receive_until_method(
                "item/permissions/requestApproval",
                timeout_seconds=30,
            )
            granted_write_path = first_requested_write_path(permission_request)
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": permission_request.get("id"),
                    "result": {
                        "permissions": {
                            "fileSystem": {
                                "write": [granted_write_path],
                            },
                        },
                        "scope": "session",
                        "strictAutoReview": None,
                    },
                }
            )

            turn_completed_notification = client.receive_until_method(
                "turn/completed",
                timeout_seconds=90,
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "thread/read",
                    "params": {
                        "threadId": started_thread_id,
                        "includeTurns": True,
                    },
                }
            )
            thread_read_response = client.receive_until_response(4, timeout_seconds=30)

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "turn/start",
                    "params": {
                        "threadId": started_thread_id,
                        "clientUserMessageId": "client-user-request-permissions-session-command",
                        "input": [
                            {
                                "type": "text",
                                "text": SECOND_USER_TEXT,
                                "textElements": [],
                            }
                        ],
                    },
                }
            )
            second_turn_start_response = client.receive_until_response(5, timeout_seconds=30)
            second_turn_completed_notification = client.receive_until_method(
                "turn/completed",
                timeout_seconds=90,
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 6,
                    "method": "thread/read",
                    "params": {
                        "threadId": started_thread_id,
                        "includeTurns": True,
                    },
                }
            )
            final_thread_read_response = client.receive_until_response(6, timeout_seconds=30)
        finally:
            stderr = client.close()

    expected = {
        "thread_id": started_thread_id,
        "turn_id": turn_id,
        "call_id": CALL_ID,
    }
    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "permission_request": permission_request,
        "normalized_permission_request": normalize_permission_request(
            permission_request,
            expected,
            workspace,
        ),
        "turn_completed_notification": turn_completed_notification,
        "thread_read_response": thread_read_response,
        "second_turn_start_response": second_turn_start_response,
        "second_turn_completed_notification": second_turn_completed_notification,
        "final_thread_read_response": final_thread_read_response,
        "normalized_live_sequence": normalized_live_sequence(client.received, workspace),
        "normalized_live_sequence_order_ok": normalized_sequence_has_order(
            normalized_live_sequence(client.received, workspace)
        ),
        "normalized_thread_read_visible": normalize_thread_read_visible(
            thread_read_response,
        ),
        "normalized_final_thread_read_visible": normalize_thread_read_visible(
            final_thread_read_response,
        ),
        "normalized_final_thread_read_command_items": command_items_from_thread_read(
            final_thread_read_response,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
        "workspace_effect": {
            "session_grant_file_exists": (workspace / "session-grant.txt").exists(),
            "session_grant_file_text": (workspace / "session-grant.txt").read_text()
            if (workspace / "session-grant.txt").exists()
            else None,
        },
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_original_rollouts(codex_home)
    return result


def scenario_ok(result: dict[str, Any]) -> bool:
    request = result["normalized_permission_request"]
    visible = result["normalized_thread_read_visible"]
    mock = result["mock_server_summary"]
    if "result" not in result["turn_start_response"]:
        return False
    if "result" not in result["thread_read_response"]:
        return False
    if "result" not in result["second_turn_start_response"]:
        return False
    if "result" not in result["final_thread_read_response"]:
        return False
    if not request["thread_id_matches"] or not request["turn_id_matches"]:
        return False
    if not request["item_id_matches"] or not request["reason_matches"]:
        return False
    if request["write_count"] != 2:
        return False
    if request["write_roles"] != ["workspace", "workspace-parent-shared"]:
        return False
    if request["entries_count"] != 2:
        return False
    if request["entry_accesses"] != ["write", "write"]:
        return False
    if not result["normalized_live_sequence_order_ok"]:
        return False
    final_visible = result["normalized_final_thread_read_visible"]
    command_items = result["normalized_final_thread_read_command_items"]
    if not visible["contains_first_final_text"]:
        return False
    if not final_visible["contains_first_final_text"]:
        return False
    if not final_visible["contains_second_final_text"]:
        return False
    workspace_effect = result["workspace_effect"]
    if not workspace_effect["session_grant_file_exists"]:
        return False
    if COMMAND_OUTPUT_TEXT not in (workspace_effect["session_grant_file_text"] or ""):
        return False
    if not mock["contains_function_call_output"]:
        return False
    if not mock["contains_command_function_output"]:
        return False
    if not mock["contains_granted_file_system_write"]:
        return False
    if not mock["contains_session_scope"]:
        return False
    if not mock["contains_command_output"]:
        return False
    if result["tree"] == "chat-backend":
        packages = result["chat_timeline_summary"]["packages"]
        return any(
            package["timeline_has_tool_call"]
            and package["timeline_has_tool_output"]
            and package["timeline_has_command_call"]
            and package["timeline_has_command_output"]
            and package["journal_has_request_permissions_call"]
            and package["journal_has_function_call_output"]
            and package["journal_has_command_function_call"]
            and package["journal_has_command_function_call_output"]
            and package["journal_contains_request_reason"]
            and package["journal_contains_granted_write"]
            and package["journal_contains_session_scope"]
            and package["journal_contains_command_output"]
            for package in packages
        )
    rollouts = result["original_rollout_summary"]["rollouts"]
    return any(
        "request_permissions" in rollout["function_call_names"]
        and CALL_ID in rollout["function_call_output_call_ids"]
        and COMMAND_CALL_ID in rollout["function_call_output_call_ids"]
        and rollout["contains_request_reason"]
        and rollout["contains_granted_write"]
        and rollout["contains_session_scope"]
        and rollout["contains_command_output"]
        for rollout in rollouts
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-request-permissions-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_ok = scenario_ok(original)
    chat_ok = scenario_ok(chat)
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-request-permissions-smoke",
        "binary_checks": binary_checks,
        "original_ok": original_ok,
        "chat_backend_ok": chat_ok,
        "normalized_permission_request_equal": (
            original["normalized_permission_request"] == chat["normalized_permission_request"]
        ),
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat["normalized_live_sequence"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"] == chat["normalized_thread_read_visible"]
        ),
        "normalized_final_thread_read_visible_equal": (
            original["normalized_final_thread_read_visible"]
            == chat["normalized_final_thread_read_visible"]
        ),
        "normalized_final_thread_read_command_items_equal": (
            original["normalized_final_thread_read_command_items"]
            == chat["normalized_final_thread_read_command_items"]
        ),
        "workspace_effect_equal": original["workspace_effect"] == chat["workspace_effect"],
        "mock_response_request_counts_equal": (
            original["mock_server_summary"]["response_request_count"]
            == chat["mock_server_summary"]["response_request_count"]
        ),
        "mock_function_output_contains_granted_permissions": (
            original["mock_server_summary"]["contains_granted_file_system_write"]
            and chat["mock_server_summary"]["contains_granted_file_system_write"]
        ),
        "chat_timeline_has_tool_call": any(
            package["timeline_has_tool_call"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_timeline_has_tool_output": any(
            package["timeline_has_tool_output"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_timeline_has_command_call": any(
            package["timeline_has_command_call"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_timeline_has_command_output": any(
            package["timeline_has_command_output"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_request_permissions_call": any(
            package["journal_has_request_permissions_call"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_function_call_output": any(
            package["journal_has_function_call_output"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_session_command_call": any(
            package["journal_has_command_function_call"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_session_command_output": any(
            package["journal_has_command_function_call_output"]
            and package["journal_contains_command_output"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_granted_permissions": any(
            package["journal_contains_granted_write"]
            and package["journal_contains_session_scope"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "original_normalized_permission_request": original["normalized_permission_request"],
        "chat_backend_normalized_permission_request": chat["normalized_permission_request"],
        "original_normalized_live_sequence": original["normalized_live_sequence"],
        "chat_backend_normalized_live_sequence": chat["normalized_live_sequence"],
        "chat_timeline_summary": chat["chat_timeline_summary"],
        "all_scenarios_ok": False,
        "not_yet_proven": [
            "zsh subcommand approval_id routing",
            "network approval",
            "complete T06 data fidelity report",
            "crash recovery during approval flow",
        ],
    }
    summary["all_scenarios_ok"] = (
        summary["original_ok"]
        and summary["chat_backend_ok"]
        and summary["normalized_permission_request_equal"]
        and summary["normalized_live_sequence_equal"]
        and summary["normalized_thread_read_visible_equal"]
        and summary["normalized_final_thread_read_visible_equal"]
        and summary["normalized_final_thread_read_command_items_equal"]
        and summary["workspace_effect_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["mock_function_output_contains_granted_permissions"]
        and summary["chat_timeline_has_tool_call"]
        and summary["chat_timeline_has_tool_output"]
        and summary["chat_timeline_has_command_call"]
        and summary["chat_timeline_has_command_output"]
        and summary["chat_journal_retains_request_permissions_call"]
        and summary["chat_journal_retains_function_call_output"]
        and summary["chat_journal_retains_session_command_call"]
        and summary["chat_journal_retains_session_command_output"]
        and summary["chat_journal_retains_granted_permissions"]
    )

    write_json(output_dir / "original" / "request-permissions-response.json", original)
    write_json(output_dir / "chat-backend" / "request-permissions-response.json", chat)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Request Permissions Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that returns a `request_permissions` function call.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant Codex request-permissions source files were read.

## Scope

This smoke covers a T06 slice for the model-side `request_permissions` tool
approval flow and the resulting session-scoped permission profile grant. It
verifies:

- `item/permissions/requestApproval` is emitted in both backends.
- normalized request fields match across original and `.chat` backends.
- the requested filesystem write paths are projected as app-server protocol
  `permissions.fileSystem.write` plus matching entries.
- the client grants one requested write path with session scope.
- `serverRequest/resolved` is observed before `turn/completed`.
- the model receives a `function_call_output` for the permission response.
- `thread/read includeTurns=true` exposes equivalent visible state.
- a later turn can use the session-scoped grant to run a workspace write command
  without explicit `additional_permissions`.
- the `.chat` backend records the flow as neutral `tool_call` / `tool_output`
  and `command_call` / `command_output` timeline events while retaining source
  transport in `journal.ndjson`.

It does not claim full T06 conformance.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/request-permissions-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/request-permissions-response.json
```

## Not Yet Proven

This smoke does not prove zsh subcommand approval routing, network approval,
complete T06 data fidelity, or crash recovery during approval flow.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    ok = summary["all_scenarios_ok"]
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
