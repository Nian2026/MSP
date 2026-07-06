#!/usr/bin/env python3
"""Run a durable app-server turn smoke for original vs `.chat` backend Codex.

This is source-backed validation tooling for the MSP `.chat` Codex CLI evidence
package. It drives the real `codex app-server` JSON-RPC stdio path and serves a
local mock Responses API over HTTP so a completed model turn creates durable
history without using the network.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import hashlib
import http.server
import json
import os
import pathlib
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time
import tempfile
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]


def source_snapshot_root() -> pathlib.Path:
    env_root = os.environ.get("CODEX_CHAT_VALIDATION_SOURCE_ROOT")
    if env_root:
        return pathlib.Path(env_root).expanduser().resolve()

    preferred = VALIDATION_DIR / "source-snapshots"
    if preferred.exists():
        return preferred

    return VALIDATION_DIR / "upstream"


SOURCE_SNAPSHOT_ROOT = source_snapshot_root()
ORIGINAL_CODEX_RS = SOURCE_SNAPSHOT_ROOT / "openai-codex-original/codex-rs"
CHAT_BACKEND_CODEX_RS = SOURCE_SNAPSHOT_ROOT / "openai-codex-chat-backend/codex-rs"

USER_TEXT = "Persist this durable .chat validation turn."
ASSISTANT_TEXT = "Durable turn answer from mock model."


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def read_json_lines(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    lines = []
    for line in path.read_text().splitlines():
        if line.strip():
            lines.append(json.loads(line))
    return lines


def run_command(
    command: list[str],
    cwd: pathlib.Path,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    started_at = time.time()
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return {
        "command": command,
        "cwd": str(cwd),
        "exit_code": completed.returncode,
        "duration_seconds": round(time.time() - started_at, 3),
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def cargo_target_root() -> pathlib.Path:
    env_root = os.environ.get("CODEX_CHAT_VALIDATION_CARGO_TARGET_ROOT")
    if env_root:
        return pathlib.Path(env_root).expanduser().resolve()

    digest = hashlib.sha256(str(VALIDATION_DIR).encode("utf-8")).hexdigest()[:16]
    return pathlib.Path(tempfile.gettempdir()) / "msp-chat-validation-cargo-targets" / digest


def cargo_target_name(codex_rs: pathlib.Path) -> str:
    parts = set(codex_rs.parts)
    if "openai-codex-original" in parts:
        return "original"
    if "openai-codex-chat-backend" in parts:
        return "chat-backend"
    return hashlib.sha256(str(codex_rs).encode("utf-8")).hexdigest()[:16]


def cargo_target_dir(codex_rs: pathlib.Path) -> pathlib.Path:
    return cargo_target_root() / cargo_target_name(codex_rs)


def link_snapshot_binary(snapshot_binary: pathlib.Path, external_binary: pathlib.Path) -> None:
    snapshot_binary.parent.mkdir(parents=True, exist_ok=True)
    if snapshot_binary.exists() or snapshot_binary.is_symlink():
        snapshot_binary.unlink()
    try:
        snapshot_binary.symlink_to(external_binary)
    except OSError:
        shutil.copy2(external_binary, snapshot_binary)


def ensure_binary(codex_rs: pathlib.Path, build_if_missing: bool) -> dict[str, Any]:
    binary = codex_rs / "target/debug/codex"
    target_dir = cargo_target_dir(codex_rs)
    external_binary = target_dir / "debug/codex"
    if binary.exists():
        return {
            "built": False,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
            "cargo_target_dir": str(target_dir),
            "external_artifact": str(external_binary),
            "external_artifact_exists": external_binary.exists(),
        }

    if external_binary.exists():
        link_snapshot_binary(binary, external_binary)
        return {
            "built": False,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
            "cargo_target_dir": str(target_dir),
            "external_artifact": str(external_binary),
            "external_artifact_exists": True,
            "restored_snapshot_artifact": True,
        }

    if not build_if_missing:
        raise RuntimeError(
            f"missing {binary}; run `cargo build -p codex-cli --bin codex` first"
        )

    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(target_dir)
    env.setdefault("CARGO_BUILD_JOBS", "1")
    result = run_command(
        ["cargo", "build", "-p", "codex-cli", "--bin", "codex"],
        codex_rs,
        env=env,
    )
    if result["exit_code"] != 0 or not external_binary.exists():
        raise RuntimeError(f"failed to build {external_binary}: {result}")
    link_snapshot_binary(binary, external_binary)
    result.update(
        {
            "built": True,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
            "cargo_target_dir": str(target_dir),
            "external_artifact": str(external_binary),
            "external_artifact_exists": True,
        }
    )
    return result


def sse_response(response_id: str, message_id: str, text: str) -> bytes:
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
                "type": "message",
                "role": "assistant",
                "id": message_id,
                "content": [{"type": "output_text", "text": text}],
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


class MockResponsesServer:
    def __init__(self, answer_text: str) -> None:
        self.answer_text = answer_text
        self.requests: list[dict[str, Any]] = []
        self._counter = 0
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "MockResponsesServer":
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
            self._counter += 1
            counter = self._counter
        return sse_response(
            f"resp-durable-smoke-{counter}",
            f"msg-durable-smoke-{counter}",
            self.answer_text,
        )

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

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
            "first_response_input_contains_user_text": USER_TEXT in json.dumps(
                first_body.get("input"), ensure_ascii=False
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
                server: MockResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


class JsonRpcClient:
    def __init__(
        self,
        codex_bin: pathlib.Path,
        workspace: pathlib.Path,
        codex_home: pathlib.Path,
        config_overrides: list[str],
        app_server_subcommand: bool = True,
    ) -> None:
        command = [str(codex_bin)]
        for override in config_overrides:
            command.extend(["--config", override])
        if app_server_subcommand:
            command.append("app-server")

        env = os.environ.copy()
        env["CODEX_HOME"] = str(codex_home)
        env.setdefault("RUST_LOG", "warn")

        self.command = command
        self.process = subprocess.Popen(
            command,
            cwd=str(workspace),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.sent: list[dict[str, Any]] = []
        self.received: list[dict[str, Any]] = []
        self._stdout_queue: queue.Queue[str] = queue.Queue()
        self._stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._stdout_thread.start()

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self._stdout_queue.put(line)

    def send(self, message: dict[str, Any]) -> None:
        payload = json.dumps(message, separators=(",", ":"))
        self.sent.append(message)
        assert self.process.stdin is not None
        self.process.stdin.write(payload + "\n")
        self.process.stdin.flush()

    def receive_until_response(self, request_id: int, timeout_seconds: int) -> dict[str, Any]:
        return self.receive_until(
            lambda message: message.get("id") == request_id
            and ("result" in message or "error" in message),
            timeout_seconds,
            f"response id {request_id}",
        )

    def receive_until_method(self, method: str, timeout_seconds: int) -> dict[str, Any]:
        return self.receive_until(
            lambda message: message.get("method") == method,
            timeout_seconds,
            f"notification method {method}",
        )

    def receive_until(
        self,
        predicate: Any,
        timeout_seconds: int,
        description: str,
    ) -> dict[str, Any]:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if self.process.poll() is not None and self._stdout_queue.empty():
                break
            try:
                line = self._stdout_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            payload = line.strip()
            try:
                message = json.loads(payload)
            except json.JSONDecodeError:
                continue
            self.received.append(message)
            if predicate(message):
                return message
        raise TimeoutError(
            f"timed out waiting for {description}; process status={self.process.poll()}"
        )

    def close(self) -> str:
        try:
            self.process.terminate()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()
            self.process.wait(timeout=5)
        assert self.process.stderr is not None
        return self.process.stderr.read()


def write_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"

model_provider = "mock_provider"

[model_providers.mock_provider]
name = "Mock provider for test"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def status_type(status: Any) -> Any:
    if isinstance(status, dict):
        return status.get("type")
    return status


def normalize_thread_start_response(response: dict[str, Any]) -> dict[str, Any]:
    result = response.get("result", {})
    thread = result.get("thread", {})
    sandbox = result.get("sandbox", {})
    active_permission_profile = result.get("activePermissionProfile")
    return {
        "has_error": "error" in response,
        "model": result.get("model"),
        "model_provider": result.get("modelProvider"),
        "approval_policy": result.get("approvalPolicy"),
        "approvals_reviewer": result.get("approvalsReviewer"),
        "sandbox_type": sandbox.get("type"),
        "sandbox_network_access": sandbox.get("networkAccess"),
        "active_permission_profile_id": (active_permission_profile or {}).get("id"),
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_status_type": status_type(thread.get("status")),
        "thread_turn_count": len(thread.get("turns") or []),
        "thread_source": thread.get("source"),
    }


def normalize_thread_read_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    item_types_by_turn = []
    item_count_by_turn = []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
    for turn in turns:
        items = turn.get("items") or []
        item_count_by_turn.append(len(items))
        item_types_by_turn.append([item.get("type") for item in items])
    path = thread.get("path")
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": thread.get("model"),
        "model_provider": thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": path is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": item_count_by_turn,
        "item_types_by_turn": item_types_by_turn,
        "contains_user_text": USER_TEXT in serialized_turns,
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


def summarize_path_observation(response: dict[str, Any], thread_id: str | None) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    if thread_id is not None and thread.get("id") != thread_id:
        thread = {}
    path = thread.get("path")
    return {
        "thread_id": thread_id,
        "path_present": path is not None,
        "path_suffix": pathlib.Path(path).suffix if path else None,
    }


def summarize_chat_packages(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = sorted(chat_root.glob("*.chat"))
    summaries = []
    for package in packages:
        manifest_path = package / "manifest.json"
        timeline_path = package / "timeline.ndjson"
        journal_path = package / "journal.ndjson"
        index_path = package / "indexes/thread-metadata.json"

        timeline_lines = read_json_lines(timeline_path)
        journal_lines = read_json_lines(journal_path)
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
        index = json.loads(index_path.read_text()) if index_path.exists() else None
        index_thread_id = (index or {}).get("thread_id")
        conversation_id = (
            ((manifest or {}).get("conversation") or {}).get("id")
            or (manifest or {}).get("thread_id")
            or index_thread_id
            or package.stem
        )
        summaries.append(
            {
                "package": str(package),
                "files": sorted(
                    item.relative_to(package).as_posix()
                    for item in package.rglob("*")
                    if item.is_file()
                ),
                "manifest_exists": manifest_path.exists(),
                "timeline_exists": timeline_path.exists(),
                "journal_exists": journal_path.exists(),
                "index_exists": index_path.exists(),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "manifest_format": (manifest or {}).get("format"),
                "manifest_profiles": (manifest or {}).get("profiles"),
                "manifest_capabilities": (manifest or {}).get("capabilities"),
                "conversation_id": conversation_id,
                "index_thread_id": index_thread_id,
                "index_rollout_path": (index or {}).get("rollout_path"),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "journal_source_schemas": [
                    ((line.get("source_transport") or {}).get("schema"))
                    for line in journal_lines
                ],
            }
        )
    return {
        "chat_root": str(chat_root),
        "package_count": len(packages),
        "packages": summaries,
    }


def summarize_original_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    files = [
        path.relative_to(codex_home).as_posix()
        for path in codex_home.rglob("*")
        if path.is_file()
    ]
    rollout_files = [
        path for path in files if path.endswith(".jsonl") or path.endswith(".jsonl.zst")
    ]
    rollout_summaries = []
    for rollout in rollout_files:
        rollout_path = codex_home / rollout
        rollout_summaries.append(
            {
                "path": rollout,
                "line_count": len(rollout_path.read_text().splitlines()),
            }
        )
    return {
        "codex_home": str(codex_home),
        "file_count": len(files),
        "rollout_files": sorted(rollout_files),
        "rollouts": rollout_summaries,
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
            initialize = {
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
            client.send(initialize)
            initialize_response = client.receive_until_response(1, timeout_seconds=30)
            client.send({"jsonrpc": "2.0", "method": "initialized"})

            thread_start = {
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
            client.send(thread_start)
            thread_start_response = client.receive_until_response(2, timeout_seconds=30)
            started_thread_id = (
                ((thread_start_response.get("result") or {}).get("thread") or {}).get("id")
            )

            turn_start = {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "turn/start",
                "params": {
                    "threadId": started_thread_id,
                    "clientUserMessageId": "client-user-message-durable-smoke",
                    "input": [
                        {
                            "type": "text",
                            "text": USER_TEXT,
                            "textElements": [],
                        }
                    ],
                },
            }
            client.send(turn_start)
            turn_start_response = client.receive_until_response(3, timeout_seconds=30)
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            thread_read = {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "thread/read",
                "params": {
                    "threadId": started_thread_id,
                    "includeTurns": True,
                },
            }
            client.send(thread_read)
            thread_read_response = client.receive_until_response(4, timeout_seconds=30)

            thread_list = {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "thread/list",
                "params": {
                    "limit": 10,
                    "modelProviders": [],
                    "archived": False,
                },
            }
            client.send(thread_list)
            thread_list_response = client.receive_until_response(5, timeout_seconds=30)
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
            "thread_read_response": thread_read_response,
            "thread_list_response": thread_list_response,
            "normalized_thread_start": normalize_thread_start_response(
                thread_start_response
            ),
            "normalized_thread_read": normalize_thread_read_response(
                thread_read_response
            ),
            "normalized_thread_list": normalize_thread_list_response(
                thread_list_response,
                started_thread_id,
            ),
            "thread_read_path_observation": summarize_path_observation(
                thread_read_response,
                started_thread_id,
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


def chat_package_materialized_ok(summary: dict[str, Any]) -> bool:
    if summary["package_count"] != 1:
        return False
    package = summary["packages"][0]
    if package["manifest_format"] != "msp.chat":
        return False
    if package["timeline_line_count"] < 2 or package["journal_line_count"] < 2:
        return False
    event_types = set(package["timeline_event_types"])
    return "runtime_context_snapshot" in event_types and "message" in event_types


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-durable-turn-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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

    original_read_normalized = original_result["normalized_thread_read"]
    chat_read_normalized = chat_result["normalized_thread_read"]
    original_list_normalized = original_result["normalized_thread_list"]
    chat_list_normalized = chat_result["normalized_thread_list"]
    chat_summary = chat_result["chat_package_summary"]
    materialized_ok = chat_package_materialized_ok(chat_summary)
    mock_request_counts_equal = (
        original_result["mock_server_summary"]["response_request_count"]
        == chat_result["mock_server_summary"]["response_request_count"]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-durable-turn-smoke",
        "binary_checks": binary_checks,
        "original_thread_start_exit_ok": "result" in original_result["thread_start_response"],
        "chat_backend_thread_start_exit_ok": "result" in chat_result["thread_start_response"],
        "original_turn_start_exit_ok": "result" in original_result["turn_start_response"],
        "chat_backend_turn_start_exit_ok": "result" in chat_result["turn_start_response"],
        "original_thread_read_exit_ok": "result" in original_result["thread_read_response"],
        "chat_backend_thread_read_exit_ok": "result" in chat_result["thread_read_response"],
        "original_thread_list_exit_ok": "result" in original_result["thread_list_response"],
        "chat_backend_thread_list_exit_ok": "result" in chat_result["thread_list_response"],
        "normalized_thread_start_equal": (
            original_result["normalized_thread_start"]
            == chat_result["normalized_thread_start"]
        ),
        "normalized_thread_read_equal": original_read_normalized == chat_read_normalized,
        "normalized_thread_list_equal": original_list_normalized == chat_list_normalized,
        "mock_response_request_counts_equal": mock_request_counts_equal,
        "chat_package_materialized_ok": materialized_ok,
        "original_normalized_thread_read": original_read_normalized,
        "chat_backend_normalized_thread_read": chat_read_normalized,
        "original_normalized_thread_list": original_list_normalized,
        "chat_backend_normalized_thread_list": chat_list_normalized,
        "original_mock_server_summary": original_result["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_result["mock_server_summary"],
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observation"],
            "chat-backend": chat_result["thread_read_path_observation"],
        },
        "original_storage_summary": original_result["original_storage_summary"],
        "chat_package_summary": chat_summary,
        "not_yet_proven": [
            "multi-turn normal conversation parity",
            "command/tool execution parity",
            "resume/running-rejoin/fork/rollback/compaction parity",
            "search/archive/delete parity",
            "crash recovery parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/durable-turn-response.json", original_result)
    write_json(output_dir / "chat-backend/durable-turn-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Durable Turn Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, and parity matrix were read.

## Scope

This smoke covers `initialize`, `thread/start`, one `turn/start` with a user
text message, `turn/completed`, `thread/read includeTurns=true`, and
`thread/list`.

It proves only the next durable persistence slice: a completed model turn should
materialize durable storage, `thread/read` should recover the visible turn, and
`thread/list` should expose the persisted thread. It is not full normal
conversation parity.

## Result

- original `thread/start` response succeeded: `{summary['original_thread_start_exit_ok']}`
- `.chat` backend `thread/start` response succeeded: `{summary['chat_backend_thread_start_exit_ok']}`
- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- original `thread/read` response succeeded: `{summary['original_thread_read_exit_ok']}`
- `.chat` backend `thread/read` response succeeded: `{summary['chat_backend_thread_read_exit_ok']}`
- original `thread/list` response succeeded: `{summary['original_thread_list_exit_ok']}`
- `.chat` backend `thread/list` response succeeded: `{summary['chat_backend_thread_list_exit_ok']}`
- normalized original vs `.chat` `thread/start` fields equal: `{summary['normalized_thread_start_equal']}`
- normalized original vs `.chat` `thread/read` fields equal: `{summary['normalized_thread_read_equal']}`
- normalized original vs `.chat` `thread/list` fields equal: `{summary['normalized_thread_list_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- durable `.chat` package materialized with timeline/journal evidence: `{summary['chat_package_materialized_ok']}`

## Normalized Thread Read

```json
{json.dumps({'original': original_read_normalized, 'chat-backend': chat_read_normalized}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/durable-turn-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/durable-turn-response.json
```

## Not Yet Proven

This smoke does not prove multi-turn parity, command/tool execution, resume,
running rejoin, fork, rollback, compaction, search/archive/delete parity, crash
recovery, complete data fidelity, or user-indistinguishability under normal
Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return (
        0
        if summary["original_thread_start_exit_ok"]
        and summary["chat_backend_thread_start_exit_ok"]
        and summary["original_turn_start_exit_ok"]
        and summary["chat_backend_turn_start_exit_ok"]
        and summary["original_thread_read_exit_ok"]
        and summary["chat_backend_thread_read_exit_ok"]
        and summary["original_thread_list_exit_ok"]
        and summary["chat_backend_thread_list_exit_ok"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["chat_package_materialized_ok"]
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
