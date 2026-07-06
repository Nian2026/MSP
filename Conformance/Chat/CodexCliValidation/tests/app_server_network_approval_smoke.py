#!/usr/bin/env python3
"""Run managed-network approval parity smoke for original vs `.chat` backend."""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import os
import pathlib
import threading
from typing import Any

from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import JsonRpcClient
from app_server_durable_turn_smoke import ensure_binary
from app_server_durable_turn_smoke import read_json_lines
from app_server_durable_turn_smoke import run_command
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json


USER_TEXT = "Run the managed network approval smoke."
FINAL_TEXT = "Network approval smoke complete."
CALL_ID = "call-network-approval"
NETWORK_HOST = "codex-network-test.invalid"
NETWORK_TARGET = f"http://{NETWORK_HOST}:80"
NETWORK_COMMAND = (
    f"/usr/bin/curl --silent --show-error --max-time 3 --noproxy '' {NETWORK_TARGET}"
)
APP_SERVER_BIN = "codex-app-server"


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


def ev_exec_command_call(response_id: str) -> bytes:
    arguments = json.dumps(
        {
            "cmd": NETWORK_COMMAND,
            "shell": "/bin/sh",
            "timeout_ms": 10000,
            "yield_time_ms": 1000,
            "max_output_tokens": 20000,
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
                    "name": "exec_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-network-approval-final",
                    "content": [{"type": "output_text", "text": FINAL_TEXT}],
                },
            },
            ev_completed(response_id),
        ]
    )


class NetworkApprovalResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_exec_command_call("resp-network-approval-1"),
            ev_final_message("resp-network-approval-2"),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "NetworkApprovalResponsesServer":
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
            return ev_final_message(f"resp-network-approval-extra-{index}")
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
            "contains_network_function_output": any(
                CALL_ID in body and "function_call_output" in body
                for body in serialized_bodies
            ),
            "contains_final_text": any(FINAL_TEXT in body for body in serialized_bodies),
            "contains_network_host": any(NETWORK_HOST in body for body in serialized_bodies),
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
                server: NetworkApprovalResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def write_network_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "on-request"
default_permissions = "workspace"
experimental_use_unified_exec_tool = true

model_provider = "mock_provider"

[features]
network_proxy = true
unified_exec = true

[model_providers.mock_provider]
name = "Mock provider for test"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false

[permissions.workspace.filesystem]
":minimal" = "read"

[permissions.workspace.network]
enabled = true
mode = "limited"
allow_local_binding = true
"""
    (codex_home / "config.toml").write_text(config)


def write_managed_network_requirements(managed_dir: pathlib.Path) -> pathlib.Path:
    managed_dir.mkdir(parents=True, exist_ok=True)
    managed_config = managed_dir / "managed_config.toml"
    requirements = managed_dir / "requirements.toml"
    managed_config.write_text("")
    requirements.write_text(
        """
[experimental_network]
enabled = true
allow_local_binding = true
"""
    )
    return managed_config


def normalize_decision_kind(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and value:
        return next(iter(value.keys()))
    return repr(value)


def normalize_network_request(message: dict[str, Any], expected_thread_id: str | None) -> dict[str, Any]:
    params = message.get("params") or {}
    context = params.get("networkApprovalContext") or {}
    amendments = params.get("proposedNetworkPolicyAmendments") or []
    available_decisions = params.get("availableDecisions") or []
    return {
        "method": message.get("method"),
        "thread_id_matches": params.get("threadId") == expected_thread_id,
        "turn_id_present": params.get("turnId") is not None,
        "item_id_present": params.get("itemId") is not None,
        "approval_id_present": params.get("approvalId") is not None,
        "environment_id": params.get("environmentId"),
        "reason_contains_network_access": "network" in str(params.get("reason") or "").lower(),
        "network_host": context.get("host"),
        "network_protocol": context.get("protocol"),
        "command_is_hidden_for_network_prompt": params.get("command") is None,
        "cwd_is_hidden_for_network_prompt": params.get("cwd") is None,
        "command_actions_are_hidden_for_network_prompt": params.get("commandActions") is None,
        "proposed_actions": sorted(
            amendment.get("action") for amendment in amendments if isinstance(amendment, dict)
        ),
        "proposed_hosts": sorted(
            amendment.get("host") for amendment in amendments if isinstance(amendment, dict)
        ),
        "available_decision_kinds": sorted(
            normalize_decision_kind(decision) for decision in available_decisions
        ),
    }


def choose_deny_amendment(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params") or {}
    for amendment in params.get("proposedNetworkPolicyAmendments") or []:
        if amendment.get("action") == "deny":
            return amendment
    context = params.get("networkApprovalContext") or {}
    host = context.get("host") or NETWORK_HOST
    return {"host": host, "action": "deny"}


def normalize_thread_read_visible(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in turn.get("items") or []] for turn in turns
        ],
        "contains_user_text": USER_TEXT in serialized,
        "contains_final_text": FINAL_TEXT in serialized,
    }


def summarize_config_read(response: dict[str, Any]) -> dict[str, Any]:
    config = ((response.get("result") or {}).get("config") or {})
    additional = config.get("additional") or {}
    features = additional.get("features") or {}
    permissions = config.get("permissions") or additional.get("permissions") or {}
    return {
        "has_error": "error" in response,
        "model": config.get("model"),
        "approval_policy": config.get("approvalPolicy") or config.get("approval_policy"),
        "default_permissions": config.get("defaultPermissions")
        or config.get("default_permissions")
        or additional.get("default_permissions"),
        "features_network_proxy": features.get("network_proxy"),
        "features_unified_exec": features.get("unified_exec"),
        "permissions_has_workspace": isinstance(permissions, dict)
        and "workspace" in permissions,
        "serialized_contains_network_profile": "network"
        in json.dumps(permissions, ensure_ascii=False).lower(),
    }


def summarize_config_requirements(response: dict[str, Any]) -> dict[str, Any]:
    requirements = ((response.get("result") or {}).get("requirements") or {})
    serialized = json.dumps(requirements, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "requirements_present": bool(requirements),
        "contains_experimental_network": "experimentalNetwork" in serialized
        or "experimental_network" in serialized,
        "contains_network": "network" in serialized.lower(),
        "keys": sorted(requirements.keys()) if isinstance(requirements, dict) else [],
    }


def summarize_app_server_diagnostics(
    config_read_response: dict[str, Any],
    config_requirements_read_response: dict[str, Any],
    received: list[dict[str, Any]],
    stderr: str,
) -> dict[str, Any]:
    serialized_received = json.dumps(received, ensure_ascii=False)
    stderr_lower = stderr.lower()
    return {
        "config_read": summarize_config_read(config_read_response),
        "config_requirements_read": summarize_config_requirements(
            config_requirements_read_response
        ),
        "received_contains_network_proxy": "networkProxy" in serialized_received
        or "network_proxy" in serialized_received,
        "stderr_contains_failed_start_managed_network_proxy": (
            "failed to start managed network proxy" in stderr_lower
        ),
        "stderr_contains_managed_network": "managed network" in stderr_lower,
        "stderr_contains_network_proxy": "network proxy" in stderr_lower,
    }


def status_type(status: Any) -> Any:
    if isinstance(status, dict):
        return status.get("type")
    return status


def normalized_live_sequence(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/commandExecution/requestApproval":
            context = params.get("networkApprovalContext")
            sequence.append(
                {
                    "event": "approvalRequest",
                    "network": context is not None,
                    "hasNetworkHost": (context or {}).get("host") is not None,
                    "hasProposedNetworkAmendments": bool(
                        params.get("proposedNetworkPolicyAmendments")
                    ),
                    "commandPresent": params.get("command") is not None,
                }
            )
        elif method == "serverRequest/resolved":
            sequence.append(
                {
                    "event": "serverRequestResolved",
                    "requestIdPresent": params.get("requestId") is not None,
                }
            )
        elif method in {"item/started", "item/completed"}:
            item = params.get("item") or {}
            if item.get("type") != "commandExecution":
                continue
            sequence.append(
                {
                    "event": "started" if method == "item/started" else "completed",
                    "status": status_type(item.get("status")),
                    "exitCode": item.get("exitCode"),
                    "aggregatedOutputPresent": item.get("aggregatedOutput") is not None,
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    return sequence


def summarize_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
    rollout_files = sorted((codex_home / "sessions").glob("**/*.jsonl"))
    rollouts = []
    for path in rollout_files:
        lines = read_json_lines(path)
        text = path.read_text(errors="replace")
        rollouts.append(
            {
                "path": str(path),
                "line_count": len(lines),
                "contains_network_host": NETWORK_HOST in text,
                "contains_network_rule_saved": "network rule saved" in text,
                "contains_exec_function_call": "exec_command" in text,
                "contains_function_call_output": "function_call_output" in text,
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def summarize_chat_network_package(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_path = package / "timeline.ndjson"
        journal_path = package / "journal.ndjson"
        timeline_lines = read_json_lines(timeline_path)
        journal_lines = read_json_lines(journal_path)
        timeline_text = timeline_path.read_text(errors="replace") if timeline_path.exists() else ""
        journal_text = journal_path.read_text(errors="replace") if journal_path.exists() else ""
        packages.append(
            {
                "package": str(package),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_has_command_call": any(
                    line.get("type") == "command_call" for line in timeline_lines
                ),
                "timeline_has_command_output": any(
                    line.get("type") == "command_output" for line in timeline_lines
                ),
                "timeline_contains_network_host": NETWORK_HOST in timeline_text,
                "journal_contains_network_host": NETWORK_HOST in journal_text,
                "journal_contains_network_rule_saved": "network rule saved" in journal_text,
                "journal_contains_exec_function_call": "exec_command" in journal_text,
                "journal_contains_function_call_output": "function_call_output" in journal_text,
            }
        )
    return {"package_count": len(packages), "packages": packages}


def run_scenario(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    managed_dir = run_root / tree_name / "managed"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with NetworkApprovalResponsesServer() as mock_server:
        write_network_config(codex_home, mock_server.url)
        managed_config_path = write_managed_network_requirements(managed_dir)
        codex_bin = codex_rs / "target/debug" / APP_SERVER_BIN
        previous_managed_path = os.environ.get("CODEX_APP_SERVER_MANAGED_CONFIG_PATH")
        os.environ["CODEX_APP_SERVER_MANAGED_CONFIG_PATH"] = str(managed_config_path)
        client = JsonRpcClient(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            app_server_subcommand=False,
        )
        approval_requests: list[dict[str, Any]] = []
        network_approval_request: dict[str, Any] | None = None
        try:
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "clientInfo": {"name": "msp-chat-validation", "version": "0.0.0"},
                        "experimentalApi": True,
                    },
                }
            )
            initialize_response = client.receive_until_response(1, timeout_seconds=30)

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 10,
                    "method": "config/read",
                    "params": {
                        "includeLayers": True,
                        "cwd": str(workspace),
                    },
                }
            )
            config_read_response = client.receive_until_response(10, timeout_seconds=30)

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 11,
                    "method": "configRequirements/read",
                    "params": None,
                }
            )
            config_requirements_read_response = client.receive_until_response(
                11, timeout_seconds=30
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "thread/start",
                    "params": {},
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
                        "clientUserMessageId": f"client-user-network-approval-{tree_name}",
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

            while True:
                message = client.receive_until(
                    lambda msg: msg.get("method")
                    in {
                        "item/commandExecution/requestApproval",
                        "turn/completed",
                    },
                    timeout_seconds=90,
                    description="network approval request or turn completion",
                )
                if message.get("method") == "turn/completed":
                    turn_completed_notification = message
                    break
                approval_requests.append(message)
                if (message.get("params") or {}).get("networkApprovalContext") is None:
                    client.send(
                        {
                            "jsonrpc": "2.0",
                            "id": message.get("id"),
                            "result": {"decision": "accept"},
                        }
                    )
                    continue

                network_approval_request = message
                deny_amendment = choose_deny_amendment(message)
                client.send(
                    {
                        "jsonrpc": "2.0",
                        "id": message.get("id"),
                        "result": {
                            "decision": {
                                "applyNetworkPolicyAmendment": {
                                    "networkPolicyAmendment": deny_amendment,
                                }
                            }
                        },
                    }
                )
                turn_completed_notification = client.receive_until_method(
                    "turn/completed", timeout_seconds=90
                )
                break

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
                    "method": "thread/list",
                    "params": {},
                }
            )
            thread_list_response = client.receive_until_response(5, timeout_seconds=30)
        finally:
            stderr = client.close()
            if previous_managed_path is None:
                os.environ.pop("CODEX_APP_SERVER_MANAGED_CONFIG_PATH", None)
            else:
                os.environ["CODEX_APP_SERVER_MANAGED_CONFIG_PATH"] = previous_managed_path

    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "managed_config_path": str(managed_config_path),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "config_read_response": config_read_response,
        "config_requirements_read_response": config_requirements_read_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "approval_requests": approval_requests,
        "network_approval_request": network_approval_request,
        "normalized_network_approval_request": normalize_network_request(
            network_approval_request or {},
            started_thread_id,
        ),
        "turn_completed_notification": turn_completed_notification,
        "thread_read_response": thread_read_response,
        "thread_list_response": thread_list_response,
        "normalized_live_sequence": normalized_live_sequence(client.received),
        "normalized_thread_read_visible": normalize_thread_read_visible(thread_read_response),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-8000:],
        "process_exit_code": client.process.returncode,
    }
    result["app_server_diagnostics"] = summarize_app_server_diagnostics(
        config_read_response,
        config_requirements_read_response,
        client.received,
        stderr,
    )
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_network_summary"] = summarize_chat_network_package(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_original_rollouts(codex_home)
    return result


def scenario_ok(result: dict[str, Any]) -> bool:
    request = result["normalized_network_approval_request"]
    mock = result["mock_server_summary"]
    visible = result["normalized_thread_read_visible"]
    if result["network_approval_request"] is None:
        return False
    if "result" not in result["turn_start_response"]:
        return False
    if "result" not in result["thread_read_response"]:
        return False
    if not request["thread_id_matches"]:
        return False
    if request["network_host"] != NETWORK_HOST:
        return False
    if request["network_protocol"] != "http":
        return False
    if request["proposed_actions"] != ["allow", "deny"]:
        return False
    if "applyNetworkPolicyAmendment" not in request["available_decision_kinds"]:
        return False
    if not mock["contains_network_function_output"]:
        return False
    if not visible["contains_final_text"]:
        return False
    if not any(event["event"] == "serverRequestResolved" for event in result["normalized_live_sequence"]):
        return False
    if result["tree"] == "chat-backend":
        packages = result["chat_network_summary"]["packages"]
        return any(
            package["timeline_has_command_call"]
            and package["timeline_has_command_output"]
            and package["journal_contains_network_host"]
            and package["journal_contains_function_call_output"]
            for package in packages
        )
    rollouts = result["original_rollout_summary"]["rollouts"]
    return any(
        rollout["contains_network_host"]
        and rollout["contains_function_call_output"]
        for rollout in rollouts
    )


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# App-Server Network Approval Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow T06 network approval smoke. It drives the real app-server",
        "stdio path in both vendored trees with managed network requirements loaded",
        "through `CODEX_APP_SERVER_MANAGED_CONFIG_PATH`, then applies a deny network",
        "policy amendment through `item/commandExecution/requestApproval`.",
        "",
        "It does not prove full T06 approval data fidelity, zsh subcommand",
        "`approval_id` routing, permission profile approval, crash recovery, or",
        "final Codex parity.",
        "",
        "## Result",
        "",
        f"- all scenarios ok: `{summary['all_scenarios_ok']}`",
        f"- normalized network request equal: `{summary['normalized_network_request_equal']}`",
        f"- normalized live sequence equal: `{summary['normalized_live_sequence_equal']}`",
        f"- normalized thread/read visible equal: `{summary['normalized_thread_read_visible_equal']}`",
        f"- mock response request counts equal: `{summary['mock_response_request_counts_equal']}`",
        f"- `.chat` package network evidence ok: `{summary['chat_package_network_ok']}`",
        "",
        "## Evidence",
        "",
        "- `summary.json`",
        "- `original/network-approval-response.json`",
        "- `chat-backend/network-approval-response.json`",
        "",
    ]
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-network-approval-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    binary_checks = {
        "original_cli": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat_backend_cli": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
        "original_app_server": ensure_app_server_binary(
            ORIGINAL_CODEX_RS,
            args.build_if_missing,
        ),
        "chat_backend_app_server": ensure_app_server_binary(
            CHAT_BACKEND_CODEX_RS,
            args.build_if_missing,
        ),
    }

    run_root = output_dir / "run"
    original = run_scenario(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat = run_scenario(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    chat_packages = chat.get("chat_network_summary", {}).get("packages", [])
    summary = {
        "generated_at": utc_now_iso(),
        "binary_checks": binary_checks,
        "original_ok": scenario_ok(original),
        "chat_backend_ok": scenario_ok(chat),
        "normalized_network_request_equal": (
            original["normalized_network_approval_request"]
            == chat["normalized_network_approval_request"]
        ),
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat["normalized_live_sequence"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"]
            == chat["normalized_thread_read_visible"]
        ),
        "mock_response_request_counts_equal": (
            original["mock_server_summary"]["response_request_count"]
            == chat["mock_server_summary"]["response_request_count"]
        ),
        "chat_package_network_ok": any(
            package["timeline_has_command_call"]
            and package["timeline_has_command_output"]
            and package["journal_contains_network_host"]
            and package["journal_contains_function_call_output"]
            for package in chat_packages
        ),
        "original": {
            "normalized_network_request": original["normalized_network_approval_request"],
            "normalized_live_sequence": original["normalized_live_sequence"],
            "mock_server_summary": original["mock_server_summary"],
            "app_server_diagnostics": original["app_server_diagnostics"],
            "original_rollout_summary": original.get("original_rollout_summary"),
        },
        "chat_backend": {
            "normalized_network_request": chat["normalized_network_approval_request"],
            "normalized_live_sequence": chat["normalized_live_sequence"],
            "mock_server_summary": chat["mock_server_summary"],
            "app_server_diagnostics": chat["app_server_diagnostics"],
            "chat_network_summary": chat.get("chat_network_summary"),
        },
    }
    summary["all_scenarios_ok"] = (
        summary["original_ok"]
        and summary["chat_backend_ok"]
        and summary["normalized_network_request_equal"]
        and summary["normalized_live_sequence_equal"]
        and summary["normalized_thread_read_visible_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["chat_package_network_ok"]
    )

    write_json(output_dir / "original/network-approval-response.json", original)
    write_json(output_dir / "chat-backend/network-approval-response.json", chat)
    write_json(output_dir / "summary.json", summary)
    write_report(output_dir, summary)

    if not summary["all_scenarios_ok"]:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
