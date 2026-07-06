#!/usr/bin/env python3
"""Run world-state full/patch parity smoke for original vs `.chat` backend.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both vendored source trees. It targets K04: a deferred remote environment
first enters model context as `starting`, then reports `zsh`, while automatic
compaction preserves the prior world state and the next environment sample is
persisted as a patch.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import base64
import datetime as dt
import hashlib
import http.server
import json
import pathlib
import socket
import struct
import sys
import threading
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_resume_smoke import send_thread_resume  # noqa: E402
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    read_json_lines,
    status_type,
    summarize_chat_packages,
    summarize_original_storage,
    summarize_path_observation,
    utc_now_iso,
    write_json,
)
from app_server_fork_smoke import response_request_bodies  # noqa: E402


REMOTE_ENVIRONMENT_ID = "remote"
FIRST_USER_TEXT = "Wait for the remote environment full patch smoke."
FOLLOWUP_USER_TEXT = "Resume and report the remote environment full patch smoke."
REQUEST_INPUT_CALL_ID = "call-world-state-request-input"
COMPACT_PROMPT = "Summarize the conversation for world state full patch smoke."
COMPACTION_SUMMARY_TEXT = "WORLD_STATE_AUTO_COMPACT_SUMMARY"
FIRST_FINAL_TEXT = "World state first turn done."
FOLLOWUP_FINAL_TEXT = "World state follow-up done."


def sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        chunks.append(f"event: {event['type']}\n")
        chunks.append(f"data: {json.dumps(event, separators=(',', ':'))}\n\n")
    return "".join(chunks).encode()


def ev_response_created(response_id: str) -> dict[str, Any]:
    return {"type": "response.created", "response": {"id": response_id}}


def ev_completed_with_tokens(response_id: str, total_tokens: int) -> dict[str, Any]:
    return {
        "type": "response.completed",
        "response": {
            "id": response_id,
            "usage": {
                "input_tokens": total_tokens,
                "input_tokens_details": None,
                "output_tokens": 0,
                "output_tokens_details": None,
                "total_tokens": total_tokens,
            },
        },
    }


def ev_assistant_message(response_id: str, message_id: str, text: str, tokens: int) -> bytes:
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
            ev_completed_with_tokens(response_id, tokens),
        ]
    )


def ev_request_user_input_call() -> bytes:
    arguments = json.dumps(
        {
            "questions": [
                {
                    "id": "continue",
                    "header": "Continue",
                    "question": "Continue after remote environment startup?",
                    "options": [
                        {
                            "label": "Yes (Recommended)",
                            "description": "Continue the smoke after the environment is ready.",
                        },
                        {
                            "label": "No",
                            "description": "Stop the smoke.",
                        },
                    ],
                }
            ]
        },
        separators=(",", ":"),
    )
    return sse(
        [
            ev_response_created("resp-world-state-1"),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": REQUEST_INPUT_CALL_ID,
                    "name": "request_user_input",
                    "arguments": arguments,
                },
            },
            ev_completed_with_tokens("resp-world-state-1", 96),
        ]
    )


class WorldStateMockResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_request_user_input_call(),
            ev_assistant_message(
                "resp-world-state-compact",
                "msg-world-state-compact",
                COMPACTION_SUMMARY_TEXT,
                10,
            ),
            ev_assistant_message(
                "resp-world-state-final",
                "msg-world-state-final",
                FIRST_FINAL_TEXT,
                20,
            ),
            ev_assistant_message(
                "resp-world-state-followup",
                "msg-world-state-followup",
                FOLLOWUP_FINAL_TEXT,
                20,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "WorldStateMockResponsesServer":
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
        if 1 <= index <= len(self.responses):
            return self.responses[index - 1]
        return self.responses[-1]

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

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
                server: WorldStateMockResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
                server.record_request(
                    {
                        "method": "POST",
                        "path": self.path,
                        "headers": {key.lower(): value for key, value in self.headers.items()},
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


class MiniExecServer:
    def __init__(self) -> None:
        self.ready_to_report = threading.Event()
        self.messages: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self._stop = threading.Event()
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen()
        self._listener.settimeout(0.2)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "MiniExecServer":
        self._thread.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self._stop.set()
        try:
            socket.create_connection(self._listener.getsockname(), timeout=0.2).close()
        except OSError:
            pass
        self._thread.join(timeout=5)
        self._listener.close()

    @property
    def url(self) -> str:
        host, port = self._listener.getsockname()
        return f"ws://{host}:{port}"

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            thread = threading.Thread(target=self._handle_connection, args=(conn,), daemon=True)
            thread.start()

    def _handle_connection(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(5)
            try:
                self._handshake(conn)
                while not self._stop.is_set():
                    message = self._recv_text(conn)
                    if message is None:
                        return
                    try:
                        payload = json.loads(message)
                    except json.JSONDecodeError:
                        self.errors.append(f"invalid exec-server json: {message!r}")
                        return
                    self.messages.append(payload)
                    method = payload.get("method")
                    if method == "initialize":
                        self._send_json(
                            conn,
                            {
                                "id": payload.get("id"),
                                "result": {"sessionId": "world-state-smoke-session"},
                            },
                        )
                    elif method == "initialized":
                        continue
                    elif method == "environment/info":
                        self.ready_to_report.wait(timeout=20)
                        self._send_json(
                            conn,
                            {
                                "id": payload.get("id"),
                                "result": {
                                    "shell": {"name": "zsh", "path": "/bin/zsh"},
                                },
                            },
                        )
                    elif method == "fs/getMetadata":
                        self._send_json(
                            conn,
                            {
                                "id": payload.get("id"),
                                "error": {"code": -32004, "message": "not found"},
                            },
                        )
                    else:
                        self.errors.append(f"unexpected exec-server method: {method}")
                        self._send_json(
                            conn,
                            {
                                "id": payload.get("id"),
                                "error": {
                                    "code": -32601,
                                    "message": f"unexpected method {method}",
                                },
                            },
                        )
            except OSError as exc:
                if not self._stop.is_set() and "websocket frame closed" not in str(exc):
                    self.errors.append(f"{type(exc).__name__}: {exc}")
            except Exception as exc:  # pragma: no cover - written into summary
                if not self._stop.is_set():
                    self.errors.append(f"{type(exc).__name__}: {exc}")

    def _handshake(self, conn: socket.socket) -> None:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = conn.recv(4096)
            if not chunk:
                raise OSError("websocket handshake closed")
            request += chunk
        headers: dict[str, str] = {}
        for line in request.decode(errors="replace").split("\r\n")[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()
        key = headers["sec-websocket-key"]
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        )
        conn.sendall(response.encode())

    def _recv_exact(self, conn: socket.socket, size: int) -> bytes:
        data = b""
        while len(data) < size:
            chunk = conn.recv(size - len(data))
            if not chunk:
                raise OSError("websocket frame closed")
            data += chunk
        return data

    def _recv_text(self, conn: socket.socket) -> str | None:
        header = self._recv_exact(conn, 2)
        first, second = header
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(conn, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(conn, 8))[0]
        mask = self._recv_exact(conn, 4) if masked else b""
        payload = self._recv_exact(conn, length)
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x8:
            return None
        if opcode == 0x9:
            self._send_frame(conn, 0xA, payload)
            return self._recv_text(conn)
        if opcode not in (0x1, 0x2):
            return self._recv_text(conn)
        return payload.decode()

    def _send_frame(self, conn: socket.socket, opcode: int, payload: bytes) -> None:
        header = bytes([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([length])
        elif length < (1 << 16):
            header += bytes([126]) + struct.pack("!H", length)
        else:
            header += bytes([127]) + struct.pack("!Q", length)
        conn.sendall(header + payload)

    def _send_json(self, conn: socket.socket, payload: dict[str, Any]) -> None:
        self._send_frame(conn, 0x1, json.dumps(payload, separators=(",", ":")).encode())


def write_world_state_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"
model_provider = "mock_provider"
compact_prompt = "{COMPACT_PROMPT}"
model_context_window = 100
model_auto_compact_token_limit = 90

[features]
deferred_executor = true
default_mode_request_user_input = true

[model_providers.mock_provider]
name = "Mock provider for world-state smoke"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


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


def send_environment_add(
    client: JsonRpcClient,
    request_id: int,
    exec_server_url: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "environment/add",
            "params": {
                "environmentId": REMOTE_ENVIRONMENT_ID,
                "execServerUrl": exec_server_url,
                "connectTimeoutMs": 5000,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def environment_params(workspace: pathlib.Path) -> list[dict[str, str]]:
    return [{"environmentId": REMOTE_ENVIRONMENT_ID, "cwd": str(workspace)}]


def send_thread_start_with_environment(
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
                "environments": environment_params(workspace),
            },
        }
    )
    response = client.receive_until_response(request_id, timeout_seconds=30)
    thread_id = ((response.get("result") or {}).get("thread") or {}).get("id")
    return thread_id, response


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
            "params": {"threadId": thread_id, "includeTurns": True},
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def answer_request_user_input(
    client: JsonRpcClient,
    request: dict[str, Any],
    exec_server: MiniExecServer,
) -> None:
    exec_server.ready_to_report.set()
    questions = ((request.get("params") or {}).get("questions") or [])
    question_id = (questions[0] or {}).get("id") if questions else "continue"
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "answers": {
                    question_id: {"answers": ["Yes (Recommended)"]},
                }
            },
        }
    )


def send_turn_start_and_drain(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    workspace: pathlib.Path,
    client_user_message_id: str,
    text: str,
    exec_server: MiniExecServer | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": client_user_message_id,
                "input": [{"type": "text", "text": text, "textElements": []}],
                "environments": environment_params(workspace),
            },
        }
    )

    response: dict[str, Any] | None = None
    notifications: list[dict[str, Any]] = []
    server_requests: list[dict[str, Any]] = []
    errors: list[str] = []
    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            message = client.receive_until(lambda msg: True, 5, "next turn message")
        except TimeoutError as exc:
            errors.append(str(exc))
            continue
        if message.get("id") == request_id and ("result" in message or "error" in message):
            response = message
        elif message.get("method") == "item/tool/requestUserInput":
            server_requests.append(message)
            if exec_server is None:
                errors.append("received request_user_input without exec server")
            else:
                answer_request_user_input(client, message, exec_server)
        elif "method" in message:
            notifications.append(message)
            if message.get("method") == "turn/completed":
                break
        if response is not None and any(
            notification.get("method") == "turn/completed" for notification in notifications
        ):
            break
    else:
        errors.append("timed out waiting for turn completion")

    return {
        "response": response or {},
        "notifications": notifications,
        "server_requests": server_requests,
        "notification_errors": errors,
    }


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def response_inputs_containing(requests: list[dict[str, Any]], needle: str) -> int:
    return sum(
        1
        for body in response_request_bodies(requests)
        if response_input_contains(body, needle)
    )


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    response_requests = [
        request for request in requests if str(request.get("path", "")).endswith("/responses")
    ]
    bodies = response_request_bodies(response_requests)
    serialized_bodies = [json.dumps(body.get("input"), ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(response_requests),
        "paths": [request.get("path") for request in requests],
        "contains_first_user_text_count": response_inputs_containing(
            response_requests, FIRST_USER_TEXT
        ),
        "contains_followup_user_text_count": response_inputs_containing(
            response_requests, FOLLOWUP_USER_TEXT
        ),
        "contains_compact_prompt_count": response_inputs_containing(
            response_requests, COMPACT_PROMPT
        ),
        "contains_compaction_summary_count": response_inputs_containing(
            response_requests, COMPACTION_SUMMARY_TEXT
        ),
        "environment_starting_context_count": sum(
            "<status>starting</status>" in body for body in serialized_bodies
        ),
        "environment_zsh_context_count": sum("<shell>zsh</shell>" in body for body in serialized_bodies),
        "environment_available_context_count": sum(
            "<status>available</status>" in body for body in serialized_bodies
        ),
        "request_user_input_call_count": response_inputs_containing(
            response_requests, REQUEST_INPUT_CALL_ID
        ),
    }


def get_source_payload(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def state_value(payload: dict[str, Any], pointer: list[str]) -> Any:
    value: Any = payload
    for key in pointer:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def summarize_world_state_payloads(payloads: list[dict[str, Any]]) -> dict[str, Any]:
    states = []
    for payload in payloads:
        world_payload = payload.get("payload") or {}
        state = world_payload.get("state") or {}
        remote = state_value(
            state,
            ["environments", "environments", REMOTE_ENVIRONMENT_ID],
        ) or {}
        states.append(
            {
                "full": world_payload.get("full"),
                "remote_status": remote.get("status"),
                "remote_shell": remote.get("shell"),
            }
        )
    return {
        "world_state_count": len(payloads),
        "full_flags": [state["full"] for state in states],
        "remote_statuses": [state["remote_status"] for state in states],
        "remote_shells": [state["remote_shell"] for state in states],
        "has_full_full_patch": [state["full"] for state in states] == [True, True, False],
        "has_starting_then_available_zsh": (
            any(state["remote_status"] == "starting" for state in states)
            and any(
                state["remote_status"] == "available" and state["remote_shell"] == "zsh"
                for state in states
            )
        ),
    }


def original_world_state_summary(summary: dict[str, Any]) -> dict[str, Any]:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return {"rollout_count": len(rollouts), "world_state_count": 0}
    rollout_path = pathlib.Path(summary["codex_home"]) / rollouts[0]["path"]
    payloads = [
        line
        for line in read_json_lines(rollout_path)
        if line.get("type") == "world_state"
    ]
    result = summarize_world_state_payloads(payloads)
    result["rollout_line_count"] = len(read_json_lines(rollout_path))
    return result


def chat_world_state_summary(summary: dict[str, Any]) -> dict[str, Any]:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return {"package_count": len(packages), "world_state_count": 0}
    package = pathlib.Path(packages[0]["package"])
    timeline = read_json_lines(package / "timeline.ndjson")
    journal = read_json_lines(package / "journal.ndjson")
    payloads = [
        get_source_payload(line)
        for line in journal
        if get_source_payload(line).get("type") == "world_state"
    ]
    result = summarize_world_state_payloads(payloads)
    result.update(
        {
            "package_count": len(packages),
            "timeline_line_count": len(timeline),
            "journal_line_count": len(journal),
            "timeline_event_types": [line.get("type") for line in timeline],
            "timeline_state_snapshot_count": sum(
                line.get("type") == "state_snapshot" for line in timeline
            ),
            "timeline_state_patch_count": sum(
                line.get("type") == "state_patch" for line in timeline
            ),
            "has_timeline_snapshot_and_patch": (
                any(line.get("type") == "state_snapshot" for line in timeline)
                and any(line.get("type") == "state_patch" for line in timeline)
            ),
        }
    )
    return result


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_status_type": status_type(thread.get("status")),
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])] for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_followup_user_text": FOLLOWUP_USER_TEXT in serialized_turns,
        "contains_first_final_text": FIRST_FINAL_TEXT in serialized_turns,
        "contains_followup_final_text": FOLLOWUP_FINAL_TEXT in serialized_turns,
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

    with WorldStateMockResponsesServer() as mock_server, MiniExecServer() as exec_server:
        write_world_state_config(codex_home, mock_server.url)
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            environment_add_response = send_environment_add(first_client, 2, exec_server.url)
            thread_id, thread_start_response = send_thread_start_with_environment(
                first_client, 3, workspace
            )
            first_turn_start_response = send_turn_start_and_drain(
                first_client,
                4,
                thread_id,
                workspace,
                "client-user-message-world-state-first",
                FIRST_USER_TEXT,
                exec_server,
            )
            after_first_read_response = send_thread_read(first_client, 5, thread_id)
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 6)
            second_environment_add_response = send_environment_add(
                second_client, 7, exec_server.url
            )
            thread_resume_response = send_thread_resume(second_client, 8, thread_id)
            post_resume_read_response = send_thread_read(second_client, 9, thread_id)
            followup_turn_start_response = send_turn_start_and_drain(
                second_client,
                10,
                thread_id,
                workspace,
                "client-user-message-world-state-followup",
                FOLLOWUP_USER_TEXT,
                exec_server,
            )
            final_read_response = send_thread_read(second_client, 11, thread_id)
        finally:
            second_stderr = second_client.close()

        result: dict[str, Any] = {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "first_process": {
                "command": first_client.command,
                "initialize_response": initialize_response,
                "environment_add_response": environment_add_response,
                "thread_start_response": thread_start_response,
                "first_turn_start_response": first_turn_start_response,
                "after_first_thread_read_response": after_first_read_response,
                "jsonrpc_sent": first_client.sent,
                "jsonrpc_received": first_client.received,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "command": second_client.command,
                "initialize_response": second_initialize_response,
                "environment_add_response": second_environment_add_response,
                "thread_resume_response": thread_resume_response,
                "post_resume_thread_read_response": post_resume_read_response,
                "followup_turn_start_response": followup_turn_start_response,
                "final_thread_read_response": final_read_response,
                "jsonrpc_sent": second_client.sent,
                "jsonrpc_received": second_client.received,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "exec_server_summary": {
                "url": exec_server.url,
                "messages": exec_server.messages,
                "methods": [message.get("method") for message in exec_server.messages],
                "errors": exec_server.errors,
                "environment_info_count": sum(
                    message.get("method") == "environment/info"
                    for message in exec_server.messages
                ),
            },
            "normalized_after_first_read": normalize_thread_response(after_first_read_response),
            "normalized_post_resume_read": normalize_thread_response(post_resume_read_response),
            "normalized_final_read": normalize_thread_response(final_read_response),
            "thread_read_path_observations": {
                "after_first": summarize_path_observation(after_first_read_response, thread_id),
                "post_resume": summarize_path_observation(post_resume_read_response, thread_id),
                "final": summarize_path_observation(final_read_response, thread_id),
            },
        }

        if tree_name == "chat-backend":
            chat_summary = summarize_chat_packages(chat_root)
            result["chat_package_summary"] = chat_summary
            result["chat_world_state_summary"] = chat_world_state_summary(chat_summary)
        else:
            original_summary = summarize_original_storage(codex_home)
            result["original_storage_summary"] = original_summary
            result["original_world_state_summary"] = original_world_state_summary(
                original_summary
            )
        return result


def turn_ok(result: dict[str, Any], process_name: str, turn_name: str) -> bool:
    turn = result[process_name][turn_name]
    return "result" in (turn.get("response") or {}) and not turn.get("notification_errors")


def response_ok(result: dict[str, Any], process_name: str, response_name: str) -> bool:
    return "result" in result[process_name][response_name]


def evaluate(original: dict[str, Any], chat: dict[str, Any]) -> dict[str, Any]:
    original_world = original.get("original_world_state_summary") or {}
    chat_world = chat.get("chat_world_state_summary") or {}
    original_mock = original.get("mock_server_summary") or {}
    chat_mock = chat.get("mock_server_summary") or {}
    checks = {
        "original_first_turn_completed": turn_ok(
            original, "first_process", "first_turn_start_response"
        ),
        "chat_first_turn_completed": turn_ok(
            chat, "first_process", "first_turn_start_response"
        ),
        "original_followup_turn_completed": turn_ok(
            original, "second_process", "followup_turn_start_response"
        ),
        "chat_followup_turn_completed": turn_ok(
            chat, "second_process", "followup_turn_start_response"
        ),
        "original_resume_ok": response_ok(
            original, "second_process", "thread_resume_response"
        ),
        "chat_resume_ok": response_ok(chat, "second_process", "thread_resume_response"),
        "original_world_state_full_full_patch": original_world.get("has_full_full_patch"),
        "chat_world_state_full_full_patch": chat_world.get("has_full_full_patch"),
        "chat_timeline_has_state_snapshot_and_patch": chat_world.get(
            "has_timeline_snapshot_and_patch"
        ),
        "original_context_has_starting_and_zsh": (
            original_mock.get("environment_starting_context_count", 0) > 0
            and original_mock.get("environment_zsh_context_count", 0) > 0
        ),
        "chat_context_has_starting_and_zsh": (
            chat_mock.get("environment_starting_context_count", 0) > 0
            and chat_mock.get("environment_zsh_context_count", 0) > 0
        ),
        "mock_request_counts_equal": original_mock.get("response_request_count")
        == chat_mock.get("response_request_count"),
        "exec_server_no_errors": not original["exec_server_summary"]["errors"]
        and not chat["exec_server_summary"]["errors"],
    }
    return {
        "checks": checks,
        "passed": all(bool(value) for value in checks.values()),
        "original_world_state_summary": original_world,
        "chat_world_state_summary": chat_world,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-world-state-full-patch-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    run_root = args.output_dir / "run"
    ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing)
    ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing)

    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{run_root / "chat-backend" / "chat-store"}" }}'],
    )
    evaluation = evaluate(original_result, chat_result)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server world-state full/patch K04 parity smoke",
        "is_final_parity_claim": False,
        "matrix_slice": ["K04"],
        "original": original_result,
        "chat_backend": chat_result,
        "evaluation": evaluation,
    }

    write_json(args.output_dir / "original" / "world-state-response.json", original_result)
    write_json(args.output_dir / "chat-backend" / "world-state-response.json", chat_result)
    write_json(args.output_dir / "summary.json", summary)

    report = [
        "# App-Server World State Full/Patch Smoke",
        "",
        f"Generated: `{summary['generated_at']}`",
        "",
        "This is K04 source-backed evidence, not final Codex parity.",
        "",
        "## Result",
        "",
        f"- Passed: `{evaluation['passed']}`",
        f"- Original world-state flags: `{original_result.get('original_world_state_summary', {}).get('full_flags')}`",
        f"- .chat journal world-state flags: `{chat_result.get('chat_world_state_summary', {}).get('full_flags')}`",
        f"- .chat timeline state snapshots: `{chat_result.get('chat_world_state_summary', {}).get('timeline_state_snapshot_count')}`",
        f"- .chat timeline state patches: `{chat_result.get('chat_world_state_summary', {}).get('timeline_state_patch_count')}`",
        "",
        "## Checks",
        "",
    ]
    for key, value in evaluation["checks"].items():
        report.append(f"- `{key}`: `{value}`")
    report.extend(
        [
            "",
            "## Evidence",
            "",
            f"- Summary JSON: `{args.output_dir / 'summary.json'}`",
            f"- Original response JSON: `{args.output_dir / 'original' / 'world-state-response.json'}`",
            f"- .chat response JSON: `{args.output_dir / 'chat-backend' / 'world-state-response.json'}`",
            "",
        ]
    )
    (args.output_dir / "report.md").write_text("\n".join(report))

    print(json.dumps({"summary": str(args.output_dir / "summary.json"), **evaluation}, indent=2))
    return 0 if evaluation["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
