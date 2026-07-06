#!/usr/bin/env python3
"""Run command approval cache parity smoke for original vs `.chat` backend Codex."""

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

from app_server_command_approval_smoke import command_items_from_thread_read
from app_server_command_approval_smoke import ev_final_message
from app_server_command_approval_smoke import ev_shell_command_call
from app_server_command_approval_smoke import normalize_approval_request
from app_server_command_approval_smoke import normalize_thread_read_visible
from app_server_command_approval_smoke import status_type
from app_server_command_approval_smoke import write_approval_config
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


USER_TEXT_1 = "Run the approval cache command once."
USER_TEXT_2 = "Run the approval cache command again."
FINAL_TEXT_1 = "Approval cache first command complete."
FINAL_TEXT_2 = "Approval cache second command complete."
CALL_ID_1 = "call-approval-cache-1"
CALL_ID_2 = "call-approval-cache-2"
COMMAND = "printf 'APPROVAL_CACHE_STDOUT\\n'"
STDOUT_MARKER = "APPROVAL_CACHE_STDOUT"


class ApprovalCacheResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_shell_command_call("resp-approval-cache-1", CALL_ID_1, COMMAND),
            ev_final_message("resp-approval-cache-2", "msg-approval-cache-final-1", FINAL_TEXT_1),
            ev_shell_command_call("resp-approval-cache-3", CALL_ID_2, COMMAND),
            ev_final_message("resp-approval-cache-4", "msg-approval-cache-final-2", FINAL_TEXT_2),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "ApprovalCacheResponsesServer":
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
                "resp-approval-cache-extra",
                "msg-approval-cache-extra",
                "extra approval cache response",
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
            "contains_first_function_output": any(
                CALL_ID_1 in body and "function_call_output" in body for body in serialized_bodies
            ),
            "contains_second_function_output": any(
                CALL_ID_2 in body and "function_call_output" in body for body in serialized_bodies
            ),
            "contains_first_stdout": any(
                CALL_ID_1 in body and STDOUT_MARKER in body for body in serialized_bodies
            ),
            "contains_second_stdout": any(
                CALL_ID_2 in body and STDOUT_MARKER in body for body in serialized_bodies
            ),
            "function_call_output_count": sum(
                1 for body in serialized_bodies if "function_call_output" in body
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
                server: ApprovalCacheResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def summarize_cache_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
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
                "timeline_command_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_call"
                ),
                "timeline_command_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_output"
                ),
                "timeline_has_policy_request": any(
                    line.get("type") == "policy_request" for line in timeline_lines
                ),
                "timeline_has_policy_decision": any(
                    line.get("type") == "policy_decision" for line in timeline_lines
                ),
                "journal_line_count": len(journal_lines),
                "journal_shell_function_call_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                ),
                "journal_function_call_output_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "function_call_output"
                ),
                "journal_contains_first_call": any(
                    CALL_ID_1 in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
                "journal_contains_second_call": any(
                    CALL_ID_2 in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_cache_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
        rollout_items = list(lines)
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "payload_types": [item.get("type") for item in rollout_items],
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
                "contains_first_call": any(
                    CALL_ID_1 in json.dumps(item, ensure_ascii=False) for item in rollout_items
                ),
                "contains_second_call": any(
                    CALL_ID_2 in json.dumps(item, ensure_ascii=False) for item in rollout_items
                ),
                "contains_stdout": any(
                    STDOUT_MARKER in json.dumps(item, ensure_ascii=False) for item in rollout_items
                ),
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def approval_requests(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        message
        for message in received
        if message.get("method") == "item/commandExecution/requestApproval"
    ]


def normalize_cache_command_item(item: dict[str, Any]) -> dict[str, Any]:
    output = item.get("aggregatedOutput")
    output_text = output or ""
    return {
        "id": item.get("id"),
        "command": item.get("command"),
        "source": item.get("source"),
        "status": status_type(item.get("status")),
        "exitCode": item.get("exitCode"),
        "aggregatedOutputPresent": output is not None,
        "contains_stdout_marker": STDOUT_MARKER in output_text,
    }


def normalized_cache_live_sequence(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
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
            sequence.append(
                {
                    "event": "started" if method == "item/started" else "completed",
                    "item": normalize_cache_command_item(item),
                }
            )
        elif method == "item/commandExecution/outputDelta":
            delta = params.get("delta") or ""
            sequence.append(
                {
                    "event": "outputDelta",
                    "itemId": params.get("itemId"),
                    "contains_stdout_marker": STDOUT_MARKER in delta,
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    return sequence


def completed_command_items(live_sequence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        event
        for event in live_sequence
        if event.get("event") == "completed"
        and (event.get("item") or {}).get("source") == "agent"
        and (event.get("item") or {}).get("status") == "completed"
    ]


def normalize_thread_read_cache_visible(response: dict[str, Any]) -> dict[str, Any]:
    base = normalize_thread_read_visible(response, FINAL_TEXT_2)
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    base.update(
        {
            "contains_first_final_text": FINAL_TEXT_1 in serialized,
            "contains_second_final_text": FINAL_TEXT_2 in serialized,
            "turn_count": len(turns),
            "turn_statuses": [status_type(turn.get("status")) for turn in turns],
            "item_types_by_turn": [
                [item.get("type") for item in turn.get("items") or []] for turn in turns
            ],
        }
    )
    return base


def run_scenario(
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

    with ApprovalCacheResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        first_turn_start_response: dict[str, Any] = {}
        first_approval_request: dict[str, Any] = {}
        first_turn_completed: dict[str, Any] = {}
        second_turn_start_response: dict[str, Any] = {}
        second_terminal_message: dict[str, Any] = {}
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
                        "clientUserMessageId": "client-user-command-approval-cache-1",
                        "input": [
                            {
                                "type": "text",
                                "text": USER_TEXT_1,
                                "textElements": [],
                            }
                        ],
                    },
                }
            )
            first_turn_start_response = client.receive_until_response(3, timeout_seconds=30)
            first_turn_id = (
                ((first_turn_start_response.get("result") or {}).get("turn") or {}).get("id")
            )

            first_approval_request = client.receive_until_method(
                "item/commandExecution/requestApproval", timeout_seconds=30
            )
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": first_approval_request.get("id"),
                    "result": {"decision": "acceptForSession"},
                }
            )
            first_turn_completed = client.receive_until_method(
                "turn/completed", timeout_seconds=90
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "turn/start",
                    "params": {
                        "threadId": started_thread_id,
                        "clientUserMessageId": "client-user-command-approval-cache-2",
                        "input": [
                            {
                                "type": "text",
                                "text": USER_TEXT_2,
                                "textElements": [],
                            }
                        ],
                    },
                }
            )
            second_turn_start_response = client.receive_until_response(4, timeout_seconds=30)
            second_turn_id = (
                ((second_turn_start_response.get("result") or {}).get("turn") or {}).get("id")
            )
            second_terminal_message = client.receive_until(
                lambda message: message.get("method")
                in {"item/commandExecution/requestApproval", "turn/completed"},
                timeout_seconds=90,
                description="second turn approval request or completion",
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "thread/read",
                    "params": {
                        "threadId": started_thread_id,
                        "includeTurns": True,
                    },
                }
            )
            thread_read_response = client.receive_until_response(5, timeout_seconds=30)
        finally:
            stderr = client.close()

    expected = {
        "thread_id": started_thread_id,
        "turn_id": first_turn_id,
        "call_id": CALL_ID_1,
        "command_marker": STDOUT_MARKER,
    }
    live_sequence = normalized_cache_live_sequence(client.received)
    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "first_turn_start_response": first_turn_start_response,
        "first_turn_id": first_turn_id,
        "first_approval_request": first_approval_request,
        "normalized_first_approval_request": normalize_approval_request(
            first_approval_request,
            expected,
        ),
        "first_turn_completed": first_turn_completed,
        "second_turn_start_response": second_turn_start_response,
        "second_turn_id": second_turn_id,
        "second_terminal_message": second_terminal_message,
        "second_turn_completed_without_approval": (
            second_terminal_message.get("method") == "turn/completed"
        ),
        "thread_read_response": thread_read_response,
        "approval_request_count": len(approval_requests(client.received)),
        "normalized_live_sequence": live_sequence,
        "completed_command_items": completed_command_items(live_sequence),
        "normalized_thread_read_command_items": command_items_from_thread_read(
            thread_read_response
        ),
        "normalized_thread_read_visible": normalize_thread_read_cache_visible(
            thread_read_response
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_cache_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_cache_original_rollouts(codex_home)
    return result


def scenario_ok(result: dict[str, Any]) -> bool:
    request = result["normalized_first_approval_request"]
    mock = result["mock_server_summary"]
    completed_items = result["completed_command_items"]
    visible = result["normalized_thread_read_visible"]
    if "result" not in result["first_turn_start_response"]:
        return False
    if "result" not in result["second_turn_start_response"]:
        return False
    if "result" not in result["thread_read_response"]:
        return False
    if not request["thread_id_matches"] or not request["turn_id_matches"]:
        return False
    if not request["item_id_matches"] or not request["command_contains_expected_marker"]:
        return False
    if result["approval_request_count"] != 1:
        return False
    if not result["second_turn_completed_without_approval"]:
        return False
    if len(completed_items) != 2:
        return False
    if not all((event.get("item") or {}).get("exitCode") == 0 for event in completed_items):
        return False
    if not all((event.get("item") or {}).get("contains_stdout_marker") for event in completed_items):
        return False
    if not visible["contains_first_final_text"] or not visible["contains_second_final_text"]:
        return False
    if not (
        mock["response_request_count"] == 4
        and mock["contains_first_function_output"]
        and mock["contains_second_function_output"]
        and mock["contains_first_stdout"]
        and mock["contains_second_stdout"]
        and mock["function_call_output_count"] >= 2
    ):
        return False
    if result["tree"] == "chat-backend":
        packages = result["chat_timeline_summary"]["packages"]
        return any(
            package["timeline_command_call_count"] >= 2
            and package["timeline_command_output_count"] >= 2
            and package["journal_shell_function_call_count"] >= 2
            and package["journal_function_call_output_count"] >= 2
            and package["journal_contains_first_call"]
            and package["journal_contains_second_call"]
            for package in packages
        )
    rollouts = result["original_rollout_summary"]["rollouts"]
    return any(
        rollout["function_call_names"].count("shell_command") >= 2
        and CALL_ID_1 in rollout["function_call_output_call_ids"]
        and CALL_ID_2 in rollout["function_call_output_call_ids"]
        and rollout["contains_first_call"]
        and rollout["contains_second_call"]
        and rollout["contains_stdout"]
        for rollout in rollouts
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-command-approval-cache-smoke-"
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
    original = run_scenario(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat_backend = run_scenario(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-command-approval-cache-smoke",
        "binary_checks": binary_checks,
        "original_ok": scenario_ok(original),
        "chat_backend_ok": scenario_ok(chat_backend),
        "approval_request_count_equal": (
            original["approval_request_count"] == chat_backend["approval_request_count"] == 1
        ),
        "second_turn_completed_without_approval_equal": (
            original["second_turn_completed_without_approval"]
            == chat_backend["second_turn_completed_without_approval"]
            == True
        ),
        "normalized_first_approval_request_equal": (
            original["normalized_first_approval_request"]
            == chat_backend["normalized_first_approval_request"]
        ),
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat_backend["normalized_live_sequence"]
        ),
        "normalized_thread_read_command_items_equal": (
            original["normalized_thread_read_command_items"]
            == chat_backend["normalized_thread_read_command_items"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"]
            == chat_backend["normalized_thread_read_visible"]
        ),
        "mock_response_request_counts_equal": (
            original["mock_server_summary"]["response_request_count"]
            == chat_backend["mock_server_summary"]["response_request_count"]
            == 4
        ),
        "mock_function_output_counts_equal": (
            original["mock_server_summary"]["function_call_output_count"]
            == chat_backend["mock_server_summary"]["function_call_output_count"]
        ),
        "original_mock_server_summary": original["mock_server_summary"],
        "chat_backend_mock_server_summary": chat_backend["mock_server_summary"],
        "original_normalized_live_sequence": original["normalized_live_sequence"],
        "chat_backend_normalized_live_sequence": chat_backend["normalized_live_sequence"],
        "original_normalized_thread_read_visible": original["normalized_thread_read_visible"],
        "chat_backend_normalized_thread_read_visible": chat_backend[
            "normalized_thread_read_visible"
        ],
        "chat_timeline_summary": chat_backend["chat_timeline_summary"],
        "all_scenarios_ok": False,
        "not_yet_proven": [
            "zsh subcommand approval_id routing",
            "file-change approval parity in the .chat backend harness",
            "network approval",
            "permission profile request/response persistence",
            "cold resume after approval-heavy turns",
            "complete T06 data fidelity report",
        ],
    }
    summary["all_scenarios_ok"] = all(
        [
            summary["original_ok"],
            summary["chat_backend_ok"],
            summary["approval_request_count_equal"],
            summary["second_turn_completed_without_approval_equal"],
            summary["normalized_first_approval_request_equal"],
            summary["normalized_live_sequence_equal"],
            summary["normalized_thread_read_command_items_equal"],
            summary["normalized_thread_read_visible_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_function_output_counts_equal"],
        ]
    )

    write_json(output_dir / "original" / "approval-cache-response.json", original)
    write_json(output_dir / "chat-backend" / "approval-cache-response.json", chat_backend)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Command Approval Cache Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with `approval_policy = "untrusted"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant Codex approval cache source files were read.

## Scope

This smoke extends parity matrix T06 beyond ordinary accept/decline. It verifies
the shell command approval cache behavior for `AcceptForSession` within a single
loaded thread:

- first turn emits `item/commandExecution/requestApproval`;
- client responds with `acceptForSession`;
- first command completes with stdout and exit `0`;
- second turn asks for the same command in the same cwd;
- second turn completes without a second approval request;
- both backends send two `function_call_output` payloads to the mock model;
- the adapted backend records two `command_call` and two `command_output`
  events in the `.chat` timeline.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/approval-cache-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/approval-cache-response.json
```

## Not Yet Proven

This smoke does not prove zsh subcommand `approval_id` routing, file-change
approval parity in this harness, network approval, permission profile approval,
cold resume after approval-heavy turns, or complete T06 data fidelity.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
