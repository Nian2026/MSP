#!/usr/bin/env python3
"""Run file-change approval parity smokes for original vs `.chat` backend Codex."""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
from dataclasses import dataclass
import datetime as dt
import http.server
import json
import pathlib
import sys
import threading
from typing import Any

from app_server_command_approval_smoke import ev_completed
from app_server_command_approval_smoke import ev_final_message
from app_server_command_approval_smoke import ev_response_created
from app_server_command_approval_smoke import sse
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


ADD_README_PATCH = """*** Begin Patch
*** Add File: README.md
+new line
*** End Patch
"""

UPDATE_README_PATCH = """*** Begin Patch
*** Update File: README.md
@@
-new line
+updated line
*** End Patch
"""


@dataclass(frozen=True)
class FileChangeTurn:
    user_text: str
    call_id: str
    patch_text: str
    final_text: str
    decision: str | None
    expected_status: str
    expect_request: bool


@dataclass(frozen=True)
class FileChangeScenario:
    name: str
    turns: tuple[FileChangeTurn, ...]
    expected_readme_contents: str | None


SCENARIOS: tuple[FileChangeScenario, ...] = (
    FileChangeScenario(
        name="accept",
        expected_readme_contents="new line\n",
        turns=(
            FileChangeTurn(
                user_text="Apply the file change approval accept smoke patch.",
                call_id="patch-call-accept",
                patch_text=ADD_README_PATCH,
                final_text="File change approval accept smoke complete.",
                decision="accept",
                expected_status="completed",
                expect_request=True,
            ),
        ),
    ),
    FileChangeScenario(
        name="decline",
        expected_readme_contents=None,
        turns=(
            FileChangeTurn(
                user_text="Apply the file change approval decline smoke patch.",
                call_id="patch-call-decline",
                patch_text=ADD_README_PATCH,
                final_text="File change approval decline smoke complete.",
                decision="decline",
                expected_status="declined",
                expect_request=True,
            ),
        ),
    ),
    FileChangeScenario(
        name="accept-for-session",
        expected_readme_contents="updated line\n",
        turns=(
            FileChangeTurn(
                user_text="Apply the first AcceptForSession patch.",
                call_id="patch-call-session-1",
                patch_text=ADD_README_PATCH,
                final_text="File change approval AcceptForSession patch 1 complete.",
                decision="acceptForSession",
                expected_status="completed",
                expect_request=True,
            ),
            FileChangeTurn(
                user_text="Apply the second AcceptForSession patch without another prompt.",
                call_id="patch-call-session-2",
                patch_text=UPDATE_README_PATCH,
                final_text="File change approval AcceptForSession patch 2 complete.",
                decision=None,
                expected_status="completed",
                expect_request=False,
            ),
        ),
    ),
)


def ev_apply_patch_shell_command_call(
    response_id: str,
    call_id: str,
    patch_text: str,
) -> bytes:
    command = f"apply_patch <<'EOF'\n{patch_text}\nEOF\n"
    arguments = json.dumps({"command": command}, separators=(",", ":"))
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


class FileChangeResponsesServer:
    def __init__(self, scenario: FileChangeScenario) -> None:
        self.scenario = scenario
        self.responses: list[bytes] = []
        for index, turn in enumerate(scenario.turns, start=1):
            self.responses.append(
                ev_apply_patch_shell_command_call(
                    f"resp-file-change-{scenario.name}-{index}-patch",
                    turn.call_id,
                    turn.patch_text,
                )
            )
            self.responses.append(
                ev_final_message(
                    f"resp-file-change-{scenario.name}-{index}-final",
                    f"msg-file-change-{scenario.name}-{index}-final",
                    turn.final_text,
                )
            )
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "FileChangeResponsesServer":
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
                f"resp-file-change-{self.scenario.name}-extra",
                f"msg-file-change-{self.scenario.name}-extra",
                f"extra file change response for {self.scenario.name}",
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
        call_ids = [turn.call_id for turn in self.scenario.turns]
        final_texts = [turn.final_text for turn in self.scenario.turns]
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "function_output_call_ids": [
                call_id
                for call_id in call_ids
                if any(call_id in body and "function_call_output" in body for body in serialized_bodies)
            ],
            "final_texts_seen": [
                text for text in final_texts if any(text in body for body in serialized_bodies)
            ],
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
                server: FileChangeResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def normalize_file_change_item(item: dict[str, Any]) -> dict[str, Any]:
    changes = item.get("changes") or []
    serialized_changes = json.dumps(changes, ensure_ascii=False)
    return {
        "id": item.get("id"),
        "type": item.get("type"),
        "status": status_type(item.get("status")),
        "change_count": len(changes),
        "has_readme_path": "README.md" in serialized_changes,
        "has_new_line": "new line" in serialized_changes,
        "has_updated_line": "updated line" in serialized_changes,
    }


def normalize_file_change_request(
    message: dict[str, Any] | None,
    expected: dict[str, str],
    expected_call_id: str,
) -> dict[str, Any] | None:
    if message is None:
        return None
    params = message.get("params") or {}
    return {
        "method": message.get("method"),
        "has_request_id": message.get("id") is not None,
        "thread_id_matches": params.get("threadId") == expected.get("thread_id"),
        "turn_id_matches": params.get("turnId") == expected.get("turn_id"),
        "item_id": params.get("itemId"),
        "item_id_matches": params.get("itemId") == expected_call_id,
        "reason_present": params.get("reason") is not None,
        "grant_root_present": params.get("grantRoot") is not None,
    }


def normalized_live_sequence(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/fileChange/requestApproval":
            sequence.append(
                {
                    "event": "fileChangeApprovalRequest",
                    "itemId": params.get("itemId"),
                    "reasonPresent": params.get("reason") is not None,
                    "grantRootPresent": params.get("grantRoot") is not None,
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
            if item.get("type") != "fileChange":
                continue
            sequence.append(
                {
                    "event": "started" if method == "item/started" else "completed",
                    "item": normalize_file_change_item(item),
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    return sequence


def normalize_thread_read_visible(
    response: dict[str, Any],
    final_texts: list[str],
) -> dict[str, Any]:
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
        "contains_all_final_texts": all(text in serialized for text in final_texts),
        "contains_file_change_item": "fileChange" in serialized,
        "contains_file_change_completed": "completed" in serialized and "fileChange" in serialized,
        "contains_file_change_declined": "declined" in serialized and "fileChange" in serialized,
    }


def summarize_file_change_chat_timeline(
    chat_root: pathlib.Path,
    call_ids: list[str],
) -> dict[str, Any]:
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
                "timeline_tool_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "tool_call"
                ),
                "timeline_tool_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "tool_output"
                ),
                "timeline_command_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_call"
                ),
                "timeline_command_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_output"
                ),
                "timeline_status_changed_count": sum(
                    1 for line in timeline_lines if line.get("type") == "status_changed"
                ),
                "journal_line_count": len(journal_lines),
                "journal_shell_apply_patch_call_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "function_call"
                    and payload.get("name") == "shell_command"
                    and "apply_patch" in json.dumps(payload, ensure_ascii=False)
                ),
                "journal_function_call_output_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "function_call_output"
                ),
                "journal_function_output_call_ids": [
                    call_id
                    for call_id in call_ids
                    if any(
                        call_id in json.dumps(payload, ensure_ascii=False)
                        and payload.get("type") == "function_call_output"
                        for payload in journal_payloads
                    )
                ],
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_file_change_original_rollouts(
    codex_home: pathlib.Path,
    call_ids: list[str],
) -> dict[str, Any]:
    files = sorted(
        path for path in codex_home.rglob("*") if path.is_file() and path.suffix == ".jsonl"
    )
    rollouts = []
    for path in files:
        lines = read_json_lines(path)
        rollouts.append(
            {
                "path": str(path.relative_to(codex_home)),
                "line_count": len(lines),
                "payload_types": [item.get("type") for item in lines],
                "function_call_names": [
                    ((item.get("payload") or {}).get("name"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call"
                ],
                "function_call_call_ids": [
                    ((item.get("payload") or {}).get("call_id"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call"
                ],
                "function_call_output_call_ids": [
                    ((item.get("payload") or {}).get("call_id"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "function_call_output"
                ],
                "event_msg_types": [
                    ((item.get("payload") or {}).get("type"))
                    for item in lines
                    if item.get("type") == "event_msg"
                ],
                "contains_all_patch_calls": all(
                    call_id in json.dumps(lines, ensure_ascii=False) for call_id in call_ids
                ),
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def receive_file_change_started(
    client: JsonRpcClient,
    call_id: str,
    timeout_seconds: int = 30,
) -> dict[str, Any]:
    return client.receive_until(
        lambda message: message.get("method") == "item/started"
        and ((message.get("params") or {}).get("item") or {}).get("type") == "fileChange"
        and ((message.get("params") or {}).get("item") or {}).get("id") == call_id,
        timeout_seconds=timeout_seconds,
        description=f"fileChange item/started for {call_id}",
    )


def receive_file_change_completed(
    client: JsonRpcClient,
    call_id: str,
    timeout_seconds: int = 90,
) -> dict[str, Any]:
    return client.receive_until(
        lambda message: message.get("method") == "item/completed"
        and ((message.get("params") or {}).get("item") or {}).get("type") == "fileChange"
        and ((message.get("params") or {}).get("item") or {}).get("id") == call_id,
        timeout_seconds=timeout_seconds,
        description=f"fileChange item/completed for {call_id}",
    )


def receive_file_change_completed_or_request(
    client: JsonRpcClient,
    call_id: str,
    timeout_seconds: int = 90,
) -> dict[str, Any]:
    return client.receive_until(
        lambda message: (
            message.get("method") == "item/fileChange/requestApproval"
            and (message.get("params") or {}).get("itemId") == call_id
        )
        or (
            message.get("method") == "item/completed"
            and ((message.get("params") or {}).get("item") or {}).get("type") == "fileChange"
            and ((message.get("params") or {}).get("item") or {}).get("id") == call_id
        ),
        timeout_seconds=timeout_seconds,
        description=f"fileChange completed or unexpected request for {call_id}",
    )


def run_scenario(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    scenario: FileChangeScenario,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    scenario_root = run_root / scenario.name / tree_name
    workspace = scenario_root / "workspace"
    codex_home = scenario_root / "codex-home"
    chat_root = scenario_root / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    readme_path = workspace / "README.md"

    with FileChangeResponsesServer(scenario) as mock_server:
        write_approval_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        thread_read_response: dict[str, Any] = {}
        turn_results: list[dict[str, Any]] = []
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
            thread_id = ((thread_start_response.get("result") or {}).get("thread") or {}).get("id")

            next_request_id = 3
            for turn_index, turn in enumerate(scenario.turns, start=1):
                client.send(
                    {
                        "jsonrpc": "2.0",
                        "id": next_request_id,
                        "method": "turn/start",
                        "params": {
                            "threadId": thread_id,
                            "clientUserMessageId": (
                                f"client-user-file-change-{scenario.name}-{turn_index}"
                            ),
                            "input": [
                                {
                                    "type": "text",
                                    "text": turn.user_text,
                                    "textElements": [],
                                }
                            ],
                        },
                    }
                )
                turn_start_response = client.receive_until_response(
                    next_request_id,
                    timeout_seconds=30,
                )
                next_request_id += 1
                turn_id = ((turn_start_response.get("result") or {}).get("turn") or {}).get("id")

                file_change_started = receive_file_change_started(client, turn.call_id)
                file_change_request: dict[str, Any] | None = None
                unexpected_file_change_request: dict[str, Any] | None = None

                if turn.expect_request:
                    file_change_request = client.receive_until(
                        lambda message: message.get("method")
                        == "item/fileChange/requestApproval"
                        and (message.get("params") or {}).get("itemId") == turn.call_id,
                        timeout_seconds=30,
                        description=f"fileChange requestApproval for {turn.call_id}",
                    )
                    client.send(
                        {
                            "jsonrpc": "2.0",
                            "id": file_change_request.get("id"),
                            "result": {"decision": turn.decision},
                        }
                    )
                    file_change_completed = receive_file_change_completed(client, turn.call_id)
                else:
                    completed_or_request = receive_file_change_completed_or_request(
                        client,
                        turn.call_id,
                    )
                    if completed_or_request.get("method") == "item/fileChange/requestApproval":
                        unexpected_file_change_request = completed_or_request
                        client.send(
                            {
                                "jsonrpc": "2.0",
                                "id": unexpected_file_change_request.get("id"),
                                "result": {"decision": "accept"},
                            }
                        )
                        file_change_completed = receive_file_change_completed(client, turn.call_id)
                    else:
                        file_change_completed = completed_or_request

                terminal_message = client.receive_until(
                    lambda message: message.get("method") == "turn/completed",
                    timeout_seconds=90,
                    description=f"turn/completed after {turn.call_id}",
                )

                expected = {"thread_id": thread_id, "turn_id": turn_id}
                turn_results.append(
                    {
                        "turn_index": turn_index,
                        "expected": {
                            "call_id": turn.call_id,
                            "decision": turn.decision,
                            "expected_status": turn.expected_status,
                            "expect_request": turn.expect_request,
                        },
                        "turn_start_response": turn_start_response,
                        "turn_id": turn_id,
                        "file_change_started": file_change_started,
                        "normalized_file_change_started": normalize_file_change_item(
                            ((file_change_started.get("params") or {}).get("item") or {})
                        ),
                        "file_change_request": file_change_request,
                        "normalized_file_change_request": normalize_file_change_request(
                            file_change_request,
                            expected,
                            turn.call_id,
                        ),
                        "unexpected_file_change_request": unexpected_file_change_request,
                        "file_change_completed": file_change_completed,
                        "normalized_file_change_completed": normalize_file_change_item(
                            ((file_change_completed.get("params") or {}).get("item") or {})
                        ),
                        "terminal_message": terminal_message,
                    }
                )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": next_request_id,
                    "method": "thread/read",
                    "params": {
                        "threadId": thread_id,
                        "includeTurns": True,
                    },
                }
            )
            thread_read_response = client.receive_until_response(next_request_id, timeout_seconds=30)
        finally:
            stderr = client.close()

    readme_contents = readme_path.read_text() if readme_path.exists() else None
    final_texts = [turn.final_text for turn in scenario.turns]
    call_ids = [turn.call_id for turn in scenario.turns]
    result = {
        "tree": tree_name,
        "scenario": scenario.name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_results": turn_results,
        "thread_read_response": thread_read_response,
        "normalized_live_sequence": normalized_live_sequence(client.received),
        "normalized_thread_read_visible": normalize_thread_read_visible(
            thread_read_response,
            final_texts,
        ),
        "readme_contents": readme_contents,
        "expected_readme_contents": scenario.expected_readme_contents,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_file_change_chat_timeline(chat_root, call_ids)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_file_change_original_rollouts(
            codex_home,
            call_ids,
        )
    return result


def turn_result_ok(turn_result: dict[str, Any]) -> bool:
    expected = turn_result["expected"]
    started = turn_result["normalized_file_change_started"]
    completed = turn_result["normalized_file_change_completed"]
    request = turn_result["normalized_file_change_request"]
    if "result" not in turn_result["turn_start_response"]:
        return False
    if started["id"] != expected["call_id"]:
        return False
    if not started["has_readme_path"]:
        return False
    if completed["id"] != expected["call_id"]:
        return False
    if completed["status"] != expected["expected_status"]:
        return False
    if expected["expect_request"]:
        if request is None:
            return False
        if not request["thread_id_matches"] or not request["turn_id_matches"]:
            return False
        if not request["item_id_matches"]:
            return False
    elif turn_result["unexpected_file_change_request"] is not None:
        return False
    return True


def scenario_ok(result: dict[str, Any], scenario: FileChangeScenario) -> bool:
    visible = result["normalized_thread_read_visible"]
    mock = result["mock_server_summary"]
    live_sequence = result["normalized_live_sequence"]
    expected_request_count = sum(1 for turn in scenario.turns if turn.expect_request)
    call_ids = [turn.call_id for turn in scenario.turns]
    if "result" not in result["thread_read_response"]:
        return False
    if result["readme_contents"] != scenario.expected_readme_contents:
        return False
    if not all(turn_result_ok(turn_result) for turn_result in result["turn_results"]):
        return False
    if visible["turn_count"] != len(scenario.turns):
        return False
    if not visible["contains_all_final_texts"] or not visible["contains_file_change_item"]:
        return False
    if mock["response_request_count"] != len(scenario.turns) * 2:
        return False
    if sorted(mock["function_output_call_ids"]) != sorted(call_ids):
        return False
    request_count = sum(
        1 for event in live_sequence if event.get("event") == "fileChangeApprovalRequest"
    )
    if request_count != expected_request_count:
        return False
    resolved_count = sum(
        1 for event in live_sequence if event.get("event") == "serverRequestResolved"
    )
    if resolved_count < expected_request_count:
        return False
    for turn in scenario.turns:
        if not any(
            event.get("event") == "completed"
            and (event.get("item") or {}).get("id") == turn.call_id
            and (event.get("item") or {}).get("status") == turn.expected_status
            for event in live_sequence
        ):
            return False
    if result["tree"] == "chat-backend":
        packages = result["chat_timeline_summary"]["packages"]
        return any(
            package["timeline_tool_call_count"] >= len(scenario.turns)
            and package["timeline_tool_output_count"] >= len(scenario.turns)
            and package["timeline_command_call_count"] == 0
            and package["timeline_command_output_count"] == 0
            and package["journal_shell_apply_patch_call_count"] >= len(scenario.turns)
            and sorted(package["journal_function_output_call_ids"]) == sorted(call_ids)
            for package in packages
        )
    rollouts = result["original_rollout_summary"]["rollouts"]
    return any(
        all(call_id in rollout["function_call_call_ids"] for call_id in call_ids)
        and all(call_id in rollout["function_call_output_call_ids"] for call_id in call_ids)
        and rollout["contains_all_patch_calls"]
        for rollout in rollouts
    )


def compare_scenario_results(
    original: dict[str, Any],
    chat_backend: dict[str, Any],
    scenario: FileChangeScenario,
) -> dict[str, Any]:
    original_ok = scenario_ok(original, scenario)
    chat_backend_ok = scenario_ok(chat_backend, scenario)
    return {
        "scenario": scenario.name,
        "original_ok": original_ok,
        "chat_backend_ok": chat_backend_ok,
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat_backend["normalized_live_sequence"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"]
            == chat_backend["normalized_thread_read_visible"]
        ),
        "mock_response_request_counts_equal": (
            original["mock_server_summary"]["response_request_count"]
            == chat_backend["mock_server_summary"]["response_request_count"]
            == len(scenario.turns) * 2
        ),
        "workspace_file_contents_equal": (
            original["readme_contents"]
            == chat_backend["readme_contents"]
            == scenario.expected_readme_contents
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
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-file-change-approval-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    scenario_summaries: dict[str, Any] = {}
    scenario_results: dict[str, dict[str, Any]] = {}
    for scenario in SCENARIOS:
        original = run_scenario(
            "original",
            ORIGINAL_CODEX_RS,
            run_root,
            scenario,
            config_overrides=[],
        )
        chat_store_root = run_root / scenario.name / "chat-backend" / "chat-store"
        chat_backend = run_scenario(
            "chat-backend",
            CHAT_BACKEND_CODEX_RS,
            run_root,
            scenario,
            config_overrides=[
                f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
            ],
        )
        scenario_results[scenario.name] = {
            "original": original,
            "chat-backend": chat_backend,
        }
        scenario_summaries[scenario.name] = compare_scenario_results(
            original,
            chat_backend,
            scenario,
        )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-file-change-approval-smoke",
        "covered_scenarios": [scenario.name for scenario in SCENARIOS],
        "binary_checks": binary_checks,
        "scenario_summaries": scenario_summaries,
        "all_scenarios_ok": False,
        "not_yet_proven": [
            "cold resume after file-change approval",
            "freeform apply_patch transport",
            "complete file-change data fidelity report",
        ],
    }
    summary["all_scenarios_ok"] = all(
        all(
            [
                scenario_summary["original_ok"],
                scenario_summary["chat_backend_ok"],
                scenario_summary["normalized_live_sequence_equal"],
                scenario_summary["normalized_thread_read_visible_equal"],
                scenario_summary["mock_response_request_counts_equal"],
                scenario_summary["workspace_file_contents_equal"],
            ]
        )
        for scenario_summary in scenario_summaries.values()
    )

    for scenario_name, results in scenario_results.items():
        write_json(
            output_dir / scenario_name / "original" / "file-change-approval-response.json",
            results["original"],
        )
        write_json(
            output_dir / scenario_name / "chat-backend" / "file-change-approval-response.json",
            results["chat-backend"],
        )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server File Change Approval Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with `approval_policy = "untrusted"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant Codex file-change approval source files were read.

## Scope

This smoke covers three file-change approval slices:

- `accept`: first prompt is accepted and the patch is applied.
- `decline`: first prompt is declined and the patch is not applied.
- `accept-for-session`: first prompt is accepted for the session; the second
  patch to the same file applies without a second approval prompt.

The mock model emits a `shell_command` transport call containing
`apply_patch <<'EOF'`, matching the upstream app-server test helper. Codex
intercepts that transport before normal shell execution and exposes it to
clients as a `fileChange` item plus, when needed,
`item/fileChange/requestApproval`.

It verifies:

- both backends emit the same `fileChange` started/completed live sequence;
- both backends emit the same file-change approval request shape when a prompt
  is expected;
- `decline` leaves the workspace file absent in both backends;
- `acceptForSession` suppresses the second approval prompt in both backends;
- `thread/read includeTurns=true` exposes the same user-visible thread shape;
- the `.chat` backend retains source transport while mapping canonical timeline
  entries as tool/file-change semantics rather than MSP command execution.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/accept/original/file-change-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/accept/chat-backend/file-change-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/decline/original/file-change-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/decline/chat-backend/file-change-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/accept-for-session/original/file-change-approval-response.json
{output_dir.relative_to(VALIDATION_DIR)}/accept-for-session/chat-backend/file-change-approval-response.json
```

## Not Yet Proven

This smoke does not prove cold resume after file-change approval, freeform
`apply_patch` transport, or complete file-change data fidelity.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
