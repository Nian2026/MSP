#!/usr/bin/env python3
"""Run command additional-permissions parity smoke for original vs `.chat` backend."""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import pathlib
import shlex
import sys
import threading
from typing import Any

from app_server_command_approval_smoke import command_items_from_thread_read
from app_server_command_approval_smoke import normalize_approval_request
from app_server_command_approval_smoke import normalize_thread_read_visible
from app_server_command_approval_smoke import normalized_live_sequence
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


USER_TEXT = "Run the command additional-permissions approval smoke."
FINAL_TEXT = "Additional permissions approval smoke complete."
CALL_ID = "call-command-additional-permissions"
FIXTURE_NAME = "additional-permissions-readable.txt"
FIXTURE_MARKER = "ADDITIONAL_PERMISSIONS_READ_OK"


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


def ev_shell_command_call(
    response_id: str,
    call_id: str,
    command: str,
    fixture_path: pathlib.Path,
) -> bytes:
    arguments = json.dumps(
        {
            "command": command,
            "workdir": None,
            "timeout_ms": 10000,
            "sandbox_permissions": "with_additional_permissions",
            "additional_permissions": {
                "file_system": {
                    "read": [str(fixture_path)],
                },
            },
            "justification": "Read the validation fixture for this one command.",
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


class AdditionalPermissionsResponsesServer:
    def __init__(self, command: str, fixture_path: pathlib.Path) -> None:
        self.responses = [
            ev_shell_command_call(
                "resp-additional-permissions-call",
                CALL_ID,
                command,
                fixture_path,
            ),
            ev_final_message(
                "resp-additional-permissions-final",
                "msg-additional-permissions-final",
                FINAL_TEXT,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "AdditionalPermissionsResponsesServer":
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
                "resp-additional-permissions-extra",
                "msg-additional-permissions-extra",
                "extra additional permissions response",
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
            "contains_function_call_output": any(
                CALL_ID in body and "function_call_output" in body for body in serialized_bodies
            ),
            "contains_fixture_marker": any(FIXTURE_MARKER in body for body in serialized_bodies),
            "contains_additional_permissions_arguments": any(
                "additional_permissions" in body and "with_additional_permissions" in body
                for body in serialized_bodies
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
                server: AdditionalPermissionsResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def write_additional_permissions_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
approval_policy = "on-request"
sandbox_mode = "read-only"
suppress_unstable_features_warning = true

model_provider = "mock_provider"

[features]
exec_permission_approvals = true

[model_providers.mock_provider]
name = "Mock provider for test"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)


def summarize_additional_permissions(params: dict[str, Any], fixture_path: pathlib.Path) -> dict[str, Any]:
    additional_permissions = params.get("additionalPermissions")
    file_system = (additional_permissions or {}).get("fileSystem") or {}
    read_paths = file_system.get("read") or []
    write_paths = file_system.get("write")
    serialized = json.dumps(additional_permissions, ensure_ascii=False, sort_keys=True)
    return {
        "present": additional_permissions is not None,
        "has_file_system": bool(file_system),
        "read_count": len(read_paths),
        "write_present": write_paths is not None,
        "contains_fixture_path": str(fixture_path) in serialized,
        "contains_fixture_name": FIXTURE_NAME in serialized,
    }


def normalize_additional_permissions_approval_request(
    message: dict[str, Any],
    expected: dict[str, str],
    fixture_path: pathlib.Path,
) -> dict[str, Any]:
    normalized = normalize_approval_request(message, expected)
    params = message.get("params") or {}
    normalized["additional_permissions_detail"] = summarize_additional_permissions(
        params,
        fixture_path,
    )
    normalized["available_decisions_present"] = params.get("availableDecisions") is not None
    return normalized


def summarize_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        journal_lines = read_json_lines(package / "journal.ndjson")
        journal_payloads = [
            (((line.get("source_transport") or {}).get("payload") or {}).get("payload") or {})
            for line in journal_lines
        ]
        serialized_timeline = json.dumps(timeline_lines, ensure_ascii=False)
        serialized_journal = json.dumps(journal_payloads, ensure_ascii=False)
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
                "timeline_contains_fixture_marker": FIXTURE_MARKER in serialized_timeline,
                "timeline_contains_additional_permissions": "additional_permissions"
                in serialized_timeline,
                "journal_source_response_types": [
                    payload.get("type") for payload in journal_payloads
                ],
                "journal_has_shell_function_call": any(
                    payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                    for payload in journal_payloads
                ),
                "journal_has_function_call_output": any(
                    payload.get("type") == "function_call_output" for payload in journal_payloads
                ),
                "journal_contains_fixture_marker": FIXTURE_MARKER in serialized_journal,
                "journal_contains_additional_permissions": "additional_permissions"
                in serialized_journal,
                "journal_contains_with_additional_permissions": "with_additional_permissions"
                in serialized_journal,
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
                "contains_fixture_marker": FIXTURE_MARKER in serialized_lines,
                "contains_additional_permissions": "additional_permissions" in serialized_lines,
                "contains_with_additional_permissions": "with_additional_permissions"
                in serialized_lines,
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    fixture_path: pathlib.Path,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    scenario_root = run_root / tree_name
    workspace = scenario_root / "workspace"
    codex_home = scenario_root / "codex-home"
    chat_root = scenario_root / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    command = f"cat {shlex.quote(str(fixture_path))}"

    with AdditionalPermissionsResponsesServer(command, fixture_path) as mock_server:
        write_additional_permissions_config(codex_home, mock_server.url)
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
                        "clientUserMessageId": "client-user-command-additional-permissions",
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

            approval_request = client.receive_until_method(
                "item/commandExecution/requestApproval",
                timeout_seconds=30,
            )
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": approval_request.get("id"),
                    "result": {"decision": "accept"},
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
        finally:
            stderr = client.close()

    expected = {
        "thread_id": started_thread_id,
        "turn_id": turn_id,
        "call_id": CALL_ID,
        "command_marker": FIXTURE_NAME,
    }
    result = {
        "tree": tree_name,
        "command": client.command,
        "shell_command": command,
        "fixture_path": str(fixture_path),
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "approval_request": approval_request,
        "normalized_approval_request": normalize_additional_permissions_approval_request(
            approval_request,
            expected,
            fixture_path,
        ),
        "turn_completed_notification": turn_completed_notification,
        "thread_read_response": thread_read_response,
        "normalized_live_sequence": normalized_live_sequence(client.received),
        "normalized_thread_read_command_items": command_items_from_thread_read(
            thread_read_response
        ),
        "normalized_thread_read_visible": normalize_thread_read_visible(
            thread_read_response,
            FINAL_TEXT,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "jsonrpc_received_contains_fixture_marker": FIXTURE_MARKER
        in json.dumps(client.received, ensure_ascii=False),
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


def scenario_ok(result: dict[str, Any]) -> bool:
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
    if not request["additional_permissions_present"]:
        return False
    detail = request["additional_permissions_detail"]
    if not detail["present"] or not detail["contains_fixture_path"]:
        return False
    if not any(event["event"] == "serverRequestResolved" for event in live_sequence):
        return False
    if not result["jsonrpc_received_contains_fixture_marker"]:
        return False
    if not visible["contains_expected_final_text"]:
        return False
    if not mock["contains_function_call_output"] or not mock["contains_fixture_marker"]:
        return False
    if result["tree"] == "chat-backend":
        packages = result["chat_timeline_summary"]["packages"]
        return any(
            package["timeline_has_command_call"]
            and package["timeline_has_command_output"]
            and package["journal_has_shell_function_call"]
            and package["journal_has_function_call_output"]
            and package["journal_contains_additional_permissions"]
            and package["journal_contains_with_additional_permissions"]
            and package["journal_contains_fixture_marker"]
            for package in packages
        )
    rollouts = result["original_rollout_summary"]["rollouts"]
    return any(
        "shell_command" in rollout["function_call_names"]
        and rollout["function_call_output_call_ids"]
        and rollout["contains_additional_permissions"]
        and rollout["contains_with_additional_permissions"]
        and rollout["contains_fixture_marker"]
        for rollout in rollouts
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-command-additional-permissions-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    fixture_dir = output_dir / "fixtures"
    fixture_dir.mkdir(parents=True)
    fixture_path = fixture_dir / FIXTURE_NAME
    fixture_path.write_text(FIXTURE_MARKER + "\n")

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
        fixture_path=fixture_path,
    )
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
        fixture_path=fixture_path,
    )

    original_ok = scenario_ok(original)
    chat_ok = scenario_ok(chat)
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-command-additional-permissions-smoke",
        "fixture_path": str(fixture_path),
        "binary_checks": binary_checks,
        "original_ok": original_ok,
        "chat_backend_ok": chat_ok,
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
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"] == chat["normalized_thread_read_visible"]
        ),
        "mock_response_request_counts_equal": (
            original["mock_server_summary"]["response_request_count"]
            == chat["mock_server_summary"]["response_request_count"]
        ),
        "mock_function_output_contains_fixture_marker": (
            original["mock_server_summary"]["contains_fixture_marker"]
            and chat["mock_server_summary"]["contains_fixture_marker"]
        ),
        "chat_timeline_has_command_call": any(
            package["timeline_has_command_call"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_timeline_has_command_output": any(
            package["timeline_has_command_output"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_additional_permissions": any(
            package["journal_contains_additional_permissions"]
            and package["journal_contains_with_additional_permissions"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "chat_journal_retains_fixture_marker": any(
            package["journal_contains_fixture_marker"]
            for package in chat["chat_timeline_summary"]["packages"]
        ),
        "original_normalized_approval_request": original["normalized_approval_request"],
        "chat_backend_normalized_approval_request": chat["normalized_approval_request"],
        "original_normalized_live_sequence": original["normalized_live_sequence"],
        "chat_backend_normalized_live_sequence": chat["normalized_live_sequence"],
        "chat_timeline_summary": chat["chat_timeline_summary"],
        "all_scenarios_ok": False,
        "not_yet_proven": [
            "zsh subcommand approval_id routing",
            "network approval",
            "permission profile request_permissions tool approval",
            "complete T06 data fidelity report",
            "crash recovery during approval flow",
        ],
    }
    summary["all_scenarios_ok"] = (
        summary["original_ok"]
        and summary["chat_backend_ok"]
        and summary["normalized_approval_request_equal"]
        and summary["normalized_live_sequence_equal"]
        and summary["normalized_thread_read_command_items_equal"]
        and summary["normalized_thread_read_visible_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["mock_function_output_contains_fixture_marker"]
        and summary["chat_timeline_has_command_call"]
        and summary["chat_timeline_has_command_output"]
        and summary["chat_journal_retains_additional_permissions"]
        and summary["chat_journal_retains_fixture_marker"]
    )

    write_json(output_dir / "original" / "additional-permissions-response.json", original)
    write_json(output_dir / "chat-backend" / "additional-permissions-response.json", chat)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Command Additional Permissions Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that returns a `shell_command` with
`sandbox_permissions = "with_additional_permissions"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant Codex additional-permissions source files were read.

## Scope

This smoke covers a narrow T06 slice: shell command approval with inline
additional filesystem read permission under `approval_policy = "on-request"`.

It verifies:

- `item/commandExecution/requestApproval` is emitted in both backends.
- the experimental `additionalPermissions` field is present with the requested
  fixture path when the client advertises `experimentalApi`.
- accepting the approval lets the command read the fixture and return stdout.
- normalized live command sequence and `thread/read` visibility match.
- the `.chat` backend records `command_call` and `command_output`.
- the `.chat` journal retains the original shell source transport, including
  `additional_permissions` and `with_additional_permissions`.

This smoke does not claim complete T06 conformance.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/additional-permissions-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/additional-permissions-response.json
```

## Not Yet Proven

This smoke does not prove zsh subcommand `approval_id` routing, network
approval, `request_permissions` tool approval, complete T06 data fidelity,
crash recovery during approval, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
