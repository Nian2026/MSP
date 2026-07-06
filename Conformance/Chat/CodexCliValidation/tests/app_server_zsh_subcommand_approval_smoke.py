#!/usr/bin/env python3
"""Run zsh subcommand approval-id parity smoke for original vs `.chat` backend.

This source-backed validation drives the real `codex-app-server` JSON-RPC stdio path
from a temporary package layout that contains the patched zsh fixture required
for execve-intercept subcommand approvals.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import os
import pathlib
import platform
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
from typing import Any

from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import JsonRpcClient
from app_server_durable_turn_smoke import read_json_lines
from app_server_durable_turn_smoke import run_command
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json


APP_SERVER_BIN = "codex-app-server"
ZSH_FIXTURE_URL = (
    "https://github.com/openai/codex/releases/download/rust-v0.104.0/"
    "codex-shell-tool-mcp-npm-0.104.0.tgz"
)
ZSH_CACHE = pathlib.Path(os.environ.get("MSP_CHAT_ZSH_CACHE", "/tmp/msp-chat-zsh-cache"))
CALL_ID = "call-zsh-subcommand-approval-id"
USER_TEXT = "Remove both files with the exact shell command."


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


def ev_shell_command_call(response_id: str, command: str) -> bytes:
    arguments = json.dumps(
        {
            "command": command,
            "workdir": None,
            "timeout_ms": 5000,
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
                    "call_id": CALL_ID,
                    "name": "shell_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_noop_response(response_id: str) -> bytes:
    return sse([ev_response_created(response_id), ev_completed(response_id)])


class ZshApprovalResponsesServer:
    def __init__(self, command: str) -> None:
        self.responses = [
            ev_shell_command_call("resp-zsh-subcommand-approval-1", command),
            ev_noop_response("resp-zsh-subcommand-approval-2"),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "ZshApprovalResponsesServer":
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
            response_count = len(
                [request for request in self.requests if request["path"].endswith("/responses")]
            )
        if response_count < 1 or response_count > len(self.responses):
            return ev_noop_response(f"resp-zsh-subcommand-extra-{response_count}")
        return self.responses[response_count - 1]

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "first_response_request_contains_call_id": any(
                CALL_ID in json.dumps(request["json"], ensure_ascii=False)
                for request in response_requests
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
                server: ZshApprovalResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
                server.record_request(
                    {"method": "POST", "path": self.path, "json": body_json}
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


def ensure_app_server_binary(codex_rs: pathlib.Path, build_if_missing: bool) -> dict[str, Any]:
    binary = codex_rs / "target/debug" / APP_SERVER_BIN
    if binary.exists():
        return {
            "built": False,
            "artifact": str(binary),
            "artifact_exists": True,
            "artifact_size_bytes": binary.stat().st_size,
        }
    if not build_if_missing:
        raise RuntimeError(
            f"missing {binary}; run `cargo build -p codex-app-server --bin {APP_SERVER_BIN}` first"
        )
    result = run_command(
        ["cargo", "build", "-p", "codex-app-server", "--bin", APP_SERVER_BIN],
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


def current_platform_zsh_member() -> str:
    machine = platform.machine().lower()
    if sys.platform == "darwin" and machine in {"arm64", "aarch64"}:
        return "package/vendor/aarch64-apple-darwin/zsh/macos-15/zsh"
    if sys.platform.startswith("linux") and machine in {"x86_64", "amd64"}:
        return "package/vendor/x86_64-unknown-linux-musl/zsh/ubuntu-24.04/zsh"
    if sys.platform.startswith("linux") and machine in {"aarch64", "arm64"}:
        return "package/vendor/aarch64-unknown-linux-musl/zsh/ubuntu-24.04/zsh"
    raise RuntimeError(f"unsupported zsh fixture platform: {sys.platform} {machine}")


def executable_supports_exec_wrapper(path: pathlib.Path) -> bool:
    plain = subprocess.run(
        [str(path), "-fc", "/usr/bin/true"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if plain.returncode != 0:
        return False

    wrapped = subprocess.run(
        [str(path), "-fc", "/usr/bin/true"],
        env={**os.environ, "EXEC_WRAPPER": "/usr/bin/false"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    return wrapped.returncode != 0


def resolve_zsh_binary(cache_dir: pathlib.Path) -> dict[str, Any]:
    explicit = os.environ.get("MSP_CHAT_ZSH_PATH")
    candidates = []
    if explicit:
        candidates.append((pathlib.Path(explicit), "MSP_CHAT_ZSH_PATH"))

    fixture = ORIGINAL_CODEX_RS / "app-server/tests/suite/zsh"
    if fixture.exists():
        candidates.append((fixture, "vendored dotslash fixture"))

    for path, source in candidates:
        if path.exists() and executable_supports_exec_wrapper(path):
            return {"path": str(path), "source": source, "downloaded": False}

    cache_dir.mkdir(parents=True, exist_ok=True)
    member_name = current_platform_zsh_member()
    cached_zsh = cache_dir / pathlib.Path(member_name).name
    if cached_zsh.exists() and executable_supports_exec_wrapper(cached_zsh):
        return {
            "path": str(cached_zsh),
            "source": "download-cache",
            "downloaded": False,
            "member": member_name,
        }

    archive = cache_dir / pathlib.Path(ZSH_FIXTURE_URL).name
    if not archive.exists():
        urllib.request.urlretrieve(ZSH_FIXTURE_URL, archive)

    with tarfile.open(archive, "r:gz") as tar:
        member = tar.getmember(member_name)
        extracted = tar.extractfile(member)
        if extracted is None:
            raise RuntimeError(f"zsh member could not be extracted: {member_name}")
        cached_zsh.write_bytes(extracted.read())
    cached_zsh.chmod(cached_zsh.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    if not executable_supports_exec_wrapper(cached_zsh):
        raise RuntimeError(f"downloaded zsh does not support EXEC_WRAPPER: {cached_zsh}")

    return {
        "path": str(cached_zsh),
        "source": ZSH_FIXTURE_URL,
        "downloaded": True,
        "member": member_name,
        "archive": str(archive),
    }


def create_package_app_server(
    codex_rs: pathlib.Path,
    package_root: pathlib.Path,
    zsh_binary: pathlib.Path,
) -> pathlib.Path:
    package_dir = package_root / "test-package"
    bin_dir = package_dir / "bin"
    zsh_dir = package_dir / "codex-resources/zsh/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    zsh_dir.mkdir(parents=True, exist_ok=True)
    (package_dir / "codex-package.json").write_text("{}")

    app_server = bin_dir / APP_SERVER_BIN
    shutil.copy2(codex_rs / "target/debug" / APP_SERVER_BIN, app_server)
    shutil.copy2(zsh_binary, zsh_dir / "zsh")
    app_server.chmod(app_server.stat().st_mode | stat.S_IXUSR)
    (zsh_dir / "zsh").chmod((zsh_dir / "zsh").stat().st_mode | stat.S_IXUSR)
    return app_server


def write_zsh_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "untrusted"
sandbox_mode = "read-only"

model_provider = "mock_provider"

[features]
remote_models = false
shell_zsh_fork = true
unified_exec = false
shell_snapshot = false

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


def normalize_available_decisions(
    decisions: list[Any] | None,
    first_file: str,
    second_file: str,
) -> list[Any]:
    normalized = []
    for decision in decisions or []:
        if isinstance(decision, str):
            normalized.append(decision)
            continue
        amendment = decision.get("acceptWithExecpolicyAmendment") if isinstance(decision, dict) else None
        if isinstance(amendment, dict):
            entries = amendment.get("execpolicy_amendment") or []
            serialized_entries = json.dumps(entries, ensure_ascii=False)
            normalized.append(
                {
                    "acceptWithExecpolicyAmendment": {
                        "entry_count": len(entries),
                        "contains_first_file": first_file in serialized_entries,
                        "contains_second_file": second_file in serialized_entries,
                    }
                }
            )
            continue
        normalized.append({"other": type(decision).__name__})
    return normalized


def normalize_approval(params: dict[str, Any], first_file: str, second_file: str) -> dict[str, Any]:
    command = params.get("command") or ""
    has_first = first_file in command
    has_second = second_file in command
    return {
        "method": "item/commandExecution/requestApproval",
        "item_id_matches": params.get("itemId") == CALL_ID,
        "approval_id_present": params.get("approvalId") is not None,
        "approval_id": params.get("approvalId"),
        "command_has_first_file": has_first,
        "command_has_second_file": has_second,
        "is_target_subcommand": (has_first != has_second) and ("rm " in command),
        "is_parent_or_wrapper": has_first and has_second,
        "available_decisions": normalize_available_decisions(
            params.get("availableDecisions"),
            first_file,
            second_file,
        ),
        "command_actions_count": len(params.get("commandActions") or []),
    }


def command_items_from_thread_read(response: dict[str, Any]) -> list[dict[str, Any]]:
    thread = ((response.get("result") or {}).get("thread") or {})
    items = []
    for turn in thread.get("turns") or []:
        for item in turn.get("items") or []:
            if item.get("type") == "commandExecution":
                items.append(
                    {
                        "id": item.get("id"),
                        "status": status_type(item.get("status")),
                        "exitCode": item.get("exitCode"),
                        "aggregatedOutput": item.get("aggregatedOutput"),
                    }
                )
    return items


def command_execution_item(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict) or value.get("type") != "commandExecution":
        return None
    return {
        "id": value.get("id"),
        "status": status_type(value.get("status")),
        "exitCode": value.get("exitCode"),
        "aggregatedOutput": value.get("aggregatedOutput"),
    }


def turn_completion(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    turn = value.get("turn") or {}
    return {
        "threadId_present": value.get("threadId") is not None,
        "turn_id_present": turn.get("id") is not None,
        "turn_status": status_type(turn.get("status")),
    }


def wait_for_parent_completion_or_terminal_turn(
    client: JsonRpcClient,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        message = client.receive_until(
            lambda candidate: candidate.get("method")
            in {"item/completed", "turn/completed"},
            timeout_seconds=max(1, int(deadline - time.time())),
            description="parent command item/completed or turn/completed",
        )
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/completed":
            item = command_execution_item(params.get("item"))
            if item and item.get("id") == CALL_ID:
                return {
                    "method": "item/completed",
                    "parent_command_item": item,
                    "turn_completed": None,
                }
            continue
        if method == "turn/completed":
            return {
                "method": "turn/completed",
                "parent_command_item": None,
                "turn_completed": turn_completion(params),
            }
    raise TimeoutError("timed out waiting for parent command item/completed or turn/completed")


def summarize_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        packages.append(
            {
                "package": str(package),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_has_command_call": any(
                    line.get("type") == "command_call" for line in timeline_lines
                ),
                "timeline_has_command_output": any(
                    line.get("type") == "command_output" for line in timeline_lines
                ),
                "journal_contains_call_id": any(
                    CALL_ID in json.dumps(line, ensure_ascii=False) for line in journal_lines
                ),
            }
        )
    return {"package_count": len(packages), "packages": packages}


def original_storage_has_function_call_output(codex_home: pathlib.Path) -> bool:
    for rollout_path in codex_home.glob("sessions/**/*.jsonl"):
        for line in rollout_path.read_text().splitlines():
            if not line.strip():
                continue
            item = json.loads(line)
            payload = item.get("payload") or {}
            if (
                item.get("type") == "response_item"
                and payload.get("type") == "function_call_output"
                and payload.get("call_id") == CALL_ID
            ):
                return True
    return False


def read_thread_from_new_app_server(
    app_server: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    thread_id: str,
) -> tuple[dict[str, Any], str]:
    client = JsonRpcClient(
        app_server,
        workspace,
        codex_home,
        config_overrides,
        app_server_subcommand=False,
    )
    try:
        client.send(
            {
                "jsonrpc": "2.0",
                "id": 101,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "msp-chat-validation-cold-read",
                        "title": "MSP Chat Validation Cold Read",
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
        initialize_response = client.receive_until_response(101, timeout_seconds=30)
        if "result" not in initialize_response:
            raise RuntimeError(f"cold initialize failed: {initialize_response}")
        client.send({"jsonrpc": "2.0", "method": "initialized"})
        client.send(
            {
                "jsonrpc": "2.0",
                "id": 102,
                "method": "thread/read",
                "params": {"threadId": thread_id, "includeTurns": True},
            }
        )
        return client.receive_until_response(102, timeout_seconds=30), client.close()
    except Exception:
        stderr = client.close()
        raise RuntimeError(f"cold thread/read failed; stderr tail={stderr[-4000:]}")


def run_scenario(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    zsh_binary: pathlib.Path,
) -> dict[str, Any]:
    scenario_root = run_root / tree_name
    workspace = scenario_root / "workspace"
    codex_home = scenario_root / "codex-home"
    chat_root = scenario_root / "chat-store"
    package_root = scenario_root / "package"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    first_file = workspace / "first.txt"
    second_file = workspace / "second.txt"
    first_file.write_text("one")
    second_file.write_text("two")
    shell_command = f"/bin/rm {shlex.quote(str(first_file))} && /bin/rm {shlex.quote(str(second_file))}"
    app_server = create_package_app_server(codex_rs, package_root, zsh_binary)

    with ZshApprovalResponsesServer(shell_command) as mock_server:
        write_zsh_config(codex_home, mock_server.url)
        client = JsonRpcClient(
            app_server,
            workspace,
            codex_home,
            config_overrides,
            app_server_subcommand=False,
        )
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        turn_start_response: dict[str, Any] = {}
        terminal_notification: dict[str, Any] = {}
        live_thread_read_response: dict[str, Any] = {}
        cold_thread_read_response: dict[str, Any] = {}
        cold_read_stderr = ""
        thread_id = ""
        approvals: list[dict[str, Any]] = []
        target_approvals: list[dict[str, Any]] = []
        parent_seen = False
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
            if "result" not in initialize_response:
                raise RuntimeError(f"initialize failed: {initialize_response}")
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
            if "result" not in thread_start_response:
                raise RuntimeError(f"thread/start failed: {thread_start_response}")
            thread_id = ((thread_start_response.get("result") or {}).get("thread") or {}).get("id")

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "turn/start",
                    "params": {
                        "threadId": thread_id,
                        "clientUserMessageId": f"client-user-zsh-subcommand-{tree_name}",
                        "input": [
                            {
                                "type": "text",
                                "text": USER_TEXT,
                                "textElements": [],
                            }
                        ],
                        "cwd": str(workspace),
                        "sandboxPolicy": {"type": "dangerFullAccess"},
                        "model": "mock-model",
                    },
                }
            )
            turn_start_response = client.receive_until_response(3, timeout_seconds=30)
            if "result" not in turn_start_response:
                raise RuntimeError(f"turn/start failed: {turn_start_response}")

            while len(target_approvals) < 2 or not parent_seen:
                try:
                    request = client.receive_until_method(
                        "item/commandExecution/requestApproval",
                        timeout_seconds=45,
                    )
                except TimeoutError as error:
                    tail = client.received[-20:]
                    raise TimeoutError(
                        f"{error}; received tail={json.dumps(tail, ensure_ascii=False)}"
                    ) from error
                params = request.get("params") or {}
                normalized = normalize_approval(
                    params,
                    str(first_file),
                    str(second_file),
                )
                if normalized["is_target_subcommand"]:
                    target_approvals.append(normalized)
                    decision = "accept" if len(target_approvals) == 1 else "cancel"
                elif normalized["is_parent_or_wrapper"]:
                    parent_seen = True
                    decision = "accept"
                else:
                    decision = "accept"
                normalized["decision"] = decision
                approvals.append(normalized)
                client.send(
                    {
                        "jsonrpc": "2.0",
                        "id": request.get("id"),
                        "result": {"decision": decision},
                    }
                )

            terminal_notification = wait_for_parent_completion_or_terminal_turn(
                client,
                timeout_seconds=90,
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "thread/read",
                    "params": {"threadId": thread_id, "includeTurns": True},
                }
            )
            live_thread_read_response = client.receive_until_response(4, timeout_seconds=30)
        finally:
            stderr = client.close()

        cold_thread_read_response, cold_read_stderr = read_thread_from_new_app_server(
            app_server,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
        )

    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "terminal_notification": terminal_notification,
        "approvals": approvals,
        "normalized_approval_sequence": [
            {
                key: value
                for key, value in approval.items()
                if key != "approval_id"
            }
            for approval in approvals
        ],
        "target_approval_ids": [
            approval.get("approval_id") for approval in target_approvals
        ],
        "target_approval_ids_non_null": all(
            approval.get("approval_id") for approval in target_approvals
        ),
        "target_approval_ids_distinct": len(
            {approval.get("approval_id") for approval in target_approvals}
        )
        == len(target_approvals),
        "parent_approval_seen": parent_seen,
        "live_thread_read_response": live_thread_read_response,
        "normalized_live_thread_read_command_items": command_items_from_thread_read(
            live_thread_read_response
        ),
        "cold_thread_read_response": cold_thread_read_response,
        "normalized_cold_thread_read_command_items": command_items_from_thread_read(
            cold_thread_read_response
        ),
        "first_file_exists_after": first_file.exists(),
        "second_file_exists_after": second_file.exists(),
        "stderr_tail": stderr[-6000:],
        "cold_read_stderr_tail": cold_read_stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_storage_has_function_call_output"] = (
            original_storage_has_function_call_output(codex_home)
        )
    return result


def scenario_ok(result: dict[str, Any]) -> bool:
    terminal = result.get("terminal_notification") or {}
    parent_item = terminal.get("parent_command_item") or {}
    turn_completed = terminal.get("turn_completed") or {}
    terminal_ok = (
        parent_item.get("status") == "declined"
        or turn_completed.get("turn_status") in {"interrupted", "completed"}
    )
    return (
        len(result["target_approval_ids"]) == 2
        and result["target_approval_ids_non_null"]
        and result["target_approval_ids_distinct"]
        and result["parent_approval_seen"]
        and terminal_ok
        and "result" in result["thread_start_response"]
        and "result" in result["turn_start_response"]
        and "result" in result["live_thread_read_response"]
        and "result" in result["cold_thread_read_response"]
        and result["first_file_exists_after"] is False
        and result["second_file_exists_after"] is True
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-zsh-subcommand-approval-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument("--zsh-cache-dir", type=pathlib.Path, default=ZSH_CACHE)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    zsh_info = resolve_zsh_binary(args.zsh_cache_dir)
    zsh_binary = pathlib.Path(zsh_info["path"])
    binary_checks = {
        "original": ensure_app_server_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat-backend": ensure_app_server_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
    }

    run_root = output_dir / "run"
    original = run_scenario(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
        zsh_binary=zsh_binary,
    )
    chat_store_root = run_root / "chat-backend/chat-store"
    chat = run_scenario(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        zsh_binary=zsh_binary,
    )

    original_ok = scenario_ok(original)
    chat_ok = scenario_ok(chat)
    chat_timeline = chat.get("chat_timeline_summary") or {}
    chat_packages = chat_timeline.get("packages") or []
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-zsh-subcommand-approval-smoke",
        "zsh_info": zsh_info,
        "binary_checks": binary_checks,
        "original_ok": original_ok,
        "chat_backend_ok": chat_ok,
        "normalized_approval_sequence_equal": (
            original["normalized_approval_sequence"] == chat["normalized_approval_sequence"]
        ),
        "terminal_notification_equal": (
            original["terminal_notification"] == chat["terminal_notification"]
        ),
        "live_thread_read_command_items_equal": (
            original["normalized_live_thread_read_command_items"]
            == chat["normalized_live_thread_read_command_items"]
        ),
        "cold_thread_read_command_items_equal": (
            original["normalized_cold_thread_read_command_items"]
            == chat["normalized_cold_thread_read_command_items"]
        ),
        "workspace_effect_equal": (
            original["first_file_exists_after"] == chat["first_file_exists_after"]
            and original["second_file_exists_after"] == chat["second_file_exists_after"]
        ),
        "chat_timeline_has_command_call": any(
            package["timeline_has_command_call"] for package in chat_packages
        ),
        "chat_timeline_has_command_output": any(
            package["timeline_has_command_output"] for package in chat_packages
        ),
        "original_storage_has_function_call_output": original[
            "original_storage_has_function_call_output"
        ],
        "command_output_retention_matches_original_storage": (
            any(package["timeline_has_command_output"] for package in chat_packages)
            == original["original_storage_has_function_call_output"]
        ),
        "chat_journal_contains_call_id": any(
            package["journal_contains_call_id"] for package in chat_packages
        ),
        "original_target_approval_ids_non_null": original["target_approval_ids_non_null"],
        "chat_target_approval_ids_non_null": chat["target_approval_ids_non_null"],
        "original_target_approval_ids_distinct": original["target_approval_ids_distinct"],
        "chat_target_approval_ids_distinct": chat["target_approval_ids_distinct"],
        "original_normalized_approval_sequence": original["normalized_approval_sequence"],
        "chat_backend_normalized_approval_sequence": chat["normalized_approval_sequence"],
        "chat_timeline_summary": chat_timeline,
        "not_yet_proven": [
            "permission profile approval beyond existing request-permissions and inline additional-permissions slices",
            "approval-flow crash recovery",
            "global Codex data-fidelity report integration",
        ],
    }
    summary["all_scenarios_ok"] = (
        original_ok
        and chat_ok
        and summary["normalized_approval_sequence_equal"]
        and summary["terminal_notification_equal"]
        and summary["cold_thread_read_command_items_equal"]
        and summary["workspace_effect_equal"]
        and summary["chat_timeline_has_command_call"]
        and summary["command_output_retention_matches_original_storage"]
        and summary["chat_journal_contains_call_id"]
    )

    write_json(output_dir / "original/zsh-subcommand-approval-response.json", original)
    write_json(output_dir / "chat-backend/zsh-subcommand-approval-response.json", chat)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Zsh Subcommand Approval Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, T06
reports, and relevant vendored Codex approval/zsh-fork source files were read.

## Scope

This smoke covers the remaining T06 zsh subcommand `approvalId` routing slice.
It drives the real `codex-app-server` JSON-RPC stdio path from a temporary
package layout containing the patched zsh resource. Both trees receive the same
mock model `shell_command` call:

```text
/bin/rm <workspace>/first.txt && /bin/rm <workspace>/second.txt
```

The smoke accepts the parent/wrapper approval, accepts the first intercepted
subcommand approval, and cancels the second intercepted subcommand approval.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/zsh-subcommand-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/zsh-subcommand-approval-response.json
```

## Remaining T06 Work

This closes only the zsh subcommand `approvalId` routing smoke slice. Permission
profile approval, approval-flow crash recovery, and the global Codex
data-fidelity report integration remain open.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
