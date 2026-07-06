#!/usr/bin/env python3
"""Run command approval parity smoke for original vs `.chat` backend Codex."""

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


ACCEPT_USER_TEXT = "Run the command approval accept smoke."
DECLINE_USER_TEXT = "Run the command approval decline smoke."
ACCEPT_FINAL_TEXT = "Approval accept smoke complete."
DECLINE_FINAL_TEXT = "Approval decline smoke complete."
ACCEPT_CALL_ID = "call-approval-accept"
DECLINE_CALL_ID = "call-approval-decline"
ACCEPT_COMMAND = "printf 'APPROVAL_ACCEPT_STDOUT\\n'"
DECLINE_COMMAND = "printf 'APPROVAL_DECLINE_SHOULD_NOT_RUN\\n'"


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


class ApprovalResponsesServer:
    def __init__(self, decision: str) -> None:
        self.decision = decision
        if decision == "accept":
            call_id = ACCEPT_CALL_ID
            command = ACCEPT_COMMAND
            final_text = ACCEPT_FINAL_TEXT
        elif decision == "decline":
            call_id = DECLINE_CALL_ID
            command = DECLINE_COMMAND
            final_text = DECLINE_FINAL_TEXT
        else:
            raise ValueError(f"unsupported decision: {decision}")

        self.responses = [
            ev_shell_command_call(f"resp-approval-{decision}-1", call_id, command),
            ev_final_message(
                f"resp-approval-{decision}-2",
                f"msg-approval-{decision}-final",
                final_text,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "ApprovalResponsesServer":
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
                f"resp-approval-{self.decision}-extra",
                f"msg-approval-{self.decision}-extra",
                f"extra {self.decision}",
            )
        return self.responses[index - 1]

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        serialized_bodies = [json.dumps(request["json"], ensure_ascii=False) for request in response_requests]
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "contains_accept_function_output": any(
                ACCEPT_CALL_ID in body and "function_call_output" in body
                for body in serialized_bodies
            ),
            "contains_decline_function_output": any(
                DECLINE_CALL_ID in body and "function_call_output" in body
                for body in serialized_bodies
            ),
            "contains_accept_stdout": any("APPROVAL_ACCEPT_STDOUT" in body for body in serialized_bodies),
            "contains_decline_rejection": any(
                "exec command rejected by user" in body for body in serialized_bodies
            ),
            "contains_decline_command_output": any(
                "APPROVAL_DECLINE_SHOULD_NOT_RUN" in body for body in serialized_bodies
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
                server: ApprovalResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def write_approval_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "untrusted"
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


def status_type(value: Any) -> Any:
    if isinstance(value, dict):
        return value.get("type")
    return value


def normalize_approval_request(message: dict[str, Any], expected: dict[str, str]) -> dict[str, Any]:
    params = message.get("params") or {}
    command = params.get("command") or ""
    cwd = params.get("cwd")
    if isinstance(cwd, dict):
        cwd_display = cwd.get("path") or cwd.get("value") or json.dumps(cwd, sort_keys=True)
    else:
        cwd_display = cwd
    return {
        "method": message.get("method"),
        "has_request_id": message.get("id") is not None,
        "thread_id_matches": params.get("threadId") == expected.get("thread_id"),
        "turn_id_matches": params.get("turnId") == expected.get("turn_id"),
        "item_id": params.get("itemId"),
        "item_id_matches": params.get("itemId") == expected.get("call_id"),
        "approval_id_present": params.get("approvalId") is not None,
        "environment_id": params.get("environmentId"),
        "reason_present": params.get("reason") is not None,
        "network_approval_context_present": params.get("networkApprovalContext") is not None,
        "command_contains_expected_marker": expected.get("command_marker") in command,
        "cwd_present": cwd_display is not None,
        "cwd_contains_workspace": isinstance(cwd_display, str) and "workspace" in cwd_display,
        "command_actions_count": len(params.get("commandActions") or []),
        "additional_permissions_present": params.get("additionalPermissions") is not None,
        "available_decisions": params.get("availableDecisions"),
    }


def normalize_command_item(item: dict[str, Any]) -> dict[str, Any]:
    output = item.get("aggregatedOutput")
    output_text = output or ""
    return {
        "id": item.get("id"),
        "command": item.get("command"),
        "source": item.get("source"),
        "status": status_type(item.get("status")),
        "exitCode": item.get("exitCode"),
        "aggregatedOutputPresent": output is not None,
        "contains_accept_stdout": "APPROVAL_ACCEPT_STDOUT" in output_text,
        "contains_decline_command_output": "APPROVAL_DECLINE_SHOULD_NOT_RUN" in output_text,
        "contains_rejection": "exec command rejected by user" in output_text,
    }


def command_items_from_thread_read(response: dict[str, Any]) -> list[dict[str, Any]]:
    thread = ((response.get("result") or {}).get("thread") or {})
    commands = []
    for turn in thread.get("turns") or []:
        for item in turn.get("items") or []:
            if item.get("type") == "commandExecution":
                commands.append(normalize_command_item(item))
    return commands


def normalize_thread_read_visible(response: dict[str, Any], expected_text: str) -> dict[str, Any]:
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
        "contains_expected_final_text": expected_text in serialized,
    }


def normalized_live_sequence(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/commandExecution/requestApproval":
            sequence.append(
                {
                    "event": "approvalRequest",
                    "itemId": params.get("itemId"),
                    "environmentId": params.get("environmentId"),
                    "commandActionsCount": len(params.get("commandActions") or []),
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
            event: dict[str, Any] = {
                "event": "started" if method == "item/started" else "completed",
                "item": normalize_command_item(item),
            }
            sequence.append(event)
        elif method == "item/commandExecution/outputDelta":
            delta = params.get("delta") or ""
            sequence.append(
                {
                    "event": "outputDelta",
                    "itemId": params.get("itemId"),
                    "contains_accept_stdout": "APPROVAL_ACCEPT_STDOUT" in delta,
                    "contains_decline_command_output": "APPROVAL_DECLINE_SHOULD_NOT_RUN" in delta,
                    "contains_rejection": "exec command rejected by user" in delta,
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    return sequence


def summarize_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = [
            (((line.get("source_transport") or {}).get("payload") or {}).get("payload") or {})
            for line in journal_lines
        ]
        packages.append(
            {
                "package": str(package),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "journal_line_count": len(journal_lines),
                "timeline_has_command_call": any(
                    line.get("type") == "command_call" for line in timeline_lines
                ),
                "timeline_has_command_output": any(
                    line.get("type") == "command_output" for line in timeline_lines
                ),
                "timeline_has_policy_request": any(
                    line.get("type") == "policy_request" for line in timeline_lines
                ),
                "timeline_has_policy_decision": any(
                    line.get("type") == "policy_decision" for line in timeline_lines
                ),
                "journal_source_response_types": [
                    payload.get("type") for payload in journal_payloads
                ],
                "journal_has_shell_function_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                    for payload in journal_payloads
                ),
                "journal_has_function_call_output": any(
                    payload.get("type") == "function_call_output"
                    for payload in journal_payloads
                ),
                "journal_contains_accept_stdout": any(
                    "APPROVAL_ACCEPT_STDOUT" in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
                "journal_contains_decline_rejection": any(
                    "exec command rejected by user" in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
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
        item_keys = []
        rollout_items = []
        for line in lines:
            item_keys.append(sorted(key for key in line.keys() if key != "timestamp"))
            rollout_items.append(line)
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "item_keys": item_keys,
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
                    and (item.get("payload") or {}).get("type")
                    == "function_call_output"
                ],
                "turn_context_approval_policies": [
                    ((item.get("payload") or {}).get("approval_policy"))
                    for item in rollout_items
                    if item.get("type") == "turn_context"
                ],
                "contains_accept_stdout": any(
                    "APPROVAL_ACCEPT_STDOUT" in json.dumps(item, ensure_ascii=False)
                    for item in rollout_items
                ),
                "contains_decline_rejection": any(
                    "exec command rejected by user" in json.dumps(item, ensure_ascii=False)
                    for item in rollout_items
                ),
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def run_scenario(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    decision: str,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    scenario_root = run_root / tree_name / decision
    workspace = scenario_root / "workspace"
    codex_home = scenario_root / "codex-home"
    chat_root = scenario_root / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    call_id = ACCEPT_CALL_ID if decision == "accept" else DECLINE_CALL_ID
    command_marker = "APPROVAL_ACCEPT_STDOUT" if decision == "accept" else "APPROVAL_DECLINE"
    user_text = ACCEPT_USER_TEXT if decision == "accept" else DECLINE_USER_TEXT
    final_text = ACCEPT_FINAL_TEXT if decision == "accept" else DECLINE_FINAL_TEXT
    rpc_decision = "accept" if decision == "accept" else "decline"

    with ApprovalResponsesServer(decision) as mock_server:
        write_approval_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        turn_start_response: dict[str, Any] = {}
        approval_request: dict[str, Any] = {}
        turn_completed_notification: dict[str, Any] = {}
        thread_read_response: dict[str, Any] = {}
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
                        "clientUserMessageId": f"client-user-command-approval-{decision}",
                        "input": [
                            {
                                "type": "text",
                                "text": user_text,
                                "textElements": [],
                            }
                        ],
                    },
                }
            )
            turn_start_response = client.receive_until_response(3, timeout_seconds=30)
            turn_id = ((turn_start_response.get("result") or {}).get("turn") or {}).get("id")

            approval_request = client.receive_until_method(
                "item/commandExecution/requestApproval", timeout_seconds=30
            )
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": approval_request.get("id"),
                    "result": {"decision": rpc_decision},
                }
            )

            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=90
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
        finally:
            stderr = client.close()

    expected = {
        "thread_id": started_thread_id,
        "turn_id": turn_id,
        "call_id": call_id,
        "command_marker": command_marker,
    }
    result = {
        "tree": tree_name,
        "decision": decision,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "approval_request": approval_request,
        "normalized_approval_request": normalize_approval_request(
            approval_request,
            expected,
        ),
        "turn_completed_notification": turn_completed_notification,
        "thread_read_response": thread_read_response,
        "normalized_live_sequence": normalized_live_sequence(client.received),
        "normalized_thread_read_command_items": command_items_from_thread_read(
            thread_read_response
        ),
        "normalized_thread_read_visible": normalize_thread_read_visible(
            thread_read_response,
            final_text,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_original_rollouts(codex_home)
    return result


def scenario_ok(result: dict[str, Any], decision: str) -> bool:
    request = result["normalized_approval_request"]
    live_sequence = result["normalized_live_sequence"]
    visible = result["normalized_thread_read_visible"]
    mock = result["mock_server_summary"]
    if "result" not in result["turn_start_response"]:
        return False
    if "result" not in result["thread_read_response"]:
        return False
    if not request["thread_id_matches"] or not request["turn_id_matches"]:
        return False
    if not request["item_id_matches"] or not request["command_contains_expected_marker"]:
        return False
    if not any(event["event"] == "serverRequestResolved" for event in result["normalized_live_sequence"]):
        return False
    if not visible["contains_expected_final_text"]:
        return False
    if result["tree"] == "chat-backend":
        packages = result["chat_timeline_summary"]["packages"]
        if not any(package["timeline_has_command_call"] for package in packages):
            return False
        if not any(package["timeline_has_command_output"] for package in packages):
            return False
        if not any(package["journal_has_shell_function_call"] for package in packages):
            return False
        if not any(package["journal_has_function_call_output"] for package in packages):
            return False
    else:
        rollouts = result["original_rollout_summary"]["rollouts"]
        if not any("shell_command" in rollout["function_call_names"] for rollout in rollouts):
            return False
        if not any(rollout["function_call_output_call_ids"] for rollout in rollouts):
            return False
    if decision == "accept":
        return (
            mock["contains_accept_function_output"]
            and mock["contains_accept_stdout"]
            and any(
                event.get("event") == "completed"
                and (event.get("item") or {}).get("status") == "completed"
                and (event.get("item") or {}).get("exitCode") == 0
                and (event.get("item") or {}).get("contains_accept_stdout")
                for event in live_sequence
            )
        )
    return (
        mock["contains_decline_function_output"]
        and mock["contains_decline_rejection"]
        and any(
            event.get("event") == "completed"
            and (event.get("item") or {}).get("status") == "declined"
            and not (event.get("item") or {}).get("aggregatedOutputPresent")
            for event in live_sequence
        )
        and any(
            event.get("event") == "completed"
            and (event.get("item") or {}).get("status") == "declined"
            and (event.get("item") or {}).get("contains_rejection")
            for event in live_sequence
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-command-approval-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    results: dict[str, dict[str, dict[str, Any]]] = {
        "original": {},
        "chat-backend": {},
    }
    for decision in ["accept", "decline"]:
        results["original"][decision] = run_scenario(
            "original",
            ORIGINAL_CODEX_RS,
            run_root,
            config_overrides=[],
            decision=decision,
        )
        chat_store_root = run_root / "chat-backend" / decision / "chat-store"
        results["chat-backend"][decision] = run_scenario(
            "chat-backend",
            CHAT_BACKEND_CODEX_RS,
            run_root,
            config_overrides=[
                f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
            ],
            decision=decision,
        )

    scenario_summaries: dict[str, Any] = {}
    for decision in ["accept", "decline"]:
        original = results["original"][decision]
        chat = results["chat-backend"][decision]
        scenario_summaries[decision] = {
            "original_ok": scenario_ok(original, decision),
            "chat_backend_ok": scenario_ok(chat, decision),
            "normalized_approval_request_equal": (
                original["normalized_approval_request"] == chat["normalized_approval_request"]
            ),
            "normalized_live_sequence_equal": (
                original["normalized_live_sequence"] == chat["normalized_live_sequence"]
            ),
            "normalized_thread_read_command_items_equal": (
                original["normalized_thread_read_command_items"]
                == chat["normalized_thread_read_command_items"]
            ),
            "mock_response_request_counts_equal": (
                original["mock_server_summary"]["response_request_count"]
                == chat["mock_server_summary"]["response_request_count"]
            ),
            "mock_server_summaries": {
                "original": original["mock_server_summary"],
                "chat-backend": chat["mock_server_summary"],
            },
            "original_normalized_approval_request": original["normalized_approval_request"],
            "chat_backend_normalized_approval_request": chat["normalized_approval_request"],
            "original_normalized_live_sequence": original["normalized_live_sequence"],
            "chat_backend_normalized_live_sequence": chat["normalized_live_sequence"],
            "original_normalized_thread_read_command_items": original[
                "normalized_thread_read_command_items"
            ],
            "chat_backend_normalized_thread_read_command_items": chat[
                "normalized_thread_read_command_items"
            ],
            "normalized_thread_read_visible_equal": (
                original["normalized_thread_read_visible"]
                == chat["normalized_thread_read_visible"]
            ),
            "original_normalized_thread_read_visible": original[
                "normalized_thread_read_visible"
            ],
            "chat_backend_normalized_thread_read_visible": chat[
                "normalized_thread_read_visible"
            ],
            "chat_timeline_summary": chat["chat_timeline_summary"],
        }

    all_chat_timeline_packages = [
        package
        for decision in ["accept", "decline"]
        for package in results["chat-backend"][decision]["chat_timeline_summary"]["packages"]
    ]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-command-approval-smoke",
        "binary_checks": binary_checks,
        "scenario_summaries": scenario_summaries,
        "all_scenarios_ok": all(
            scenario["original_ok"]
            and scenario["chat_backend_ok"]
            and scenario["normalized_approval_request_equal"]
            and scenario["normalized_live_sequence_equal"]
            and scenario["normalized_thread_read_command_items_equal"]
            and scenario["normalized_thread_read_visible_equal"]
            and scenario["mock_response_request_counts_equal"]
            for scenario in scenario_summaries.values()
        ),
        "chat_timeline_has_command_call": all(
            package["timeline_has_command_call"] for package in all_chat_timeline_packages
        ),
        "chat_timeline_has_command_output_for_accept": any(
            package["timeline_has_command_output"]
            for package in results["chat-backend"]["accept"]["chat_timeline_summary"]["packages"]
        ),
        "chat_timeline_policy_events_observed": any(
            package["timeline_has_policy_request"] or package["timeline_has_policy_decision"]
            for package in all_chat_timeline_packages
        ),
        "approval_event_persistence_note": (
            "The smoke verifies the user-visible approval request/decision flow and "
            "the persisted command outcome parity. It records whether neutral "
            "policy_request/policy_decision events are present in the .chat timeline; "
            "absence here is not yet claimed as full T06 conformance."
        ),
        "not_yet_proven": [
            "approval cache AcceptForSession",
            "zsh subcommand approval_id routing",
            "file-change approval",
            "network approval",
            "permission profile request/response persistence",
            "cold resume after an approval-heavy turn",
            "complete T06 data fidelity report",
        ],
    }

    for tree_name in ["original", "chat-backend"]:
        for decision in ["accept", "decline"]:
            write_json(
                output_dir / tree_name / f"{decision}-approval-response.json",
                results[tree_name][decision],
            )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Command Approval Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that returns `shell_command` function calls under
`approval_policy = "untrusted"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, and relevant Codex approval
source files were read.

## Scope

This smoke covers parity matrix slice T06 at smoke-test depth for ordinary
command execution approval. It runs both an approval accept path and an approval
decline path against the original backend and the `.chat` backend.

It verifies:

- `item/commandExecution/requestApproval` is emitted in both backends.
- normalized approval request fields match.
- the client decision resolves the server request in both backends.
- accept produces the same completed command item with stdout and exit `0`.
- decline produces the same declined command item with no exit code or output.
- `thread/read includeTurns=true` exposes the same command item state.
- `.chat` timeline command classification is recorded for the adapted backend.

It records whether neutral `policy_request` / `policy_decision` events are
present, but this smoke alone does not claim full T06 persistence conformance.

## Result

```json
{json.dumps(scenario_summaries, indent=2, sort_keys=True)}
```

## `.chat` Timeline Policy Observation

- command call present in every `.chat` scenario: `{summary['chat_timeline_has_command_call']}`
- command output present in accept `.chat` scenario: `{summary['chat_timeline_has_command_output_for_accept']}`
- neutral policy events observed: `{summary['chat_timeline_policy_events_observed']}`

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/accept-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/original/decline-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/accept-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/decline-approval-response.json
```

## Not Yet Proven

This smoke does not prove approval cache `AcceptForSession`, zsh subcommand
approval routing, file-change approval, network approval, permission profile
approval, cold resume after approval, or complete T06 data fidelity.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    ok = (
        summary["all_scenarios_ok"]
        and summary["chat_timeline_has_command_call"]
        and summary["chat_timeline_has_command_output_for_accept"]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
