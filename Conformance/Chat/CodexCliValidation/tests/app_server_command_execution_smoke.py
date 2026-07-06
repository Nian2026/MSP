#!/usr/bin/env python3
"""Run command execution parity smoke for original vs `.chat` backend Codex."""

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
from app_server_durable_turn_smoke import write_mock_config


USER_TEXT = "Run the command execution .chat parity smoke."
FINAL_TEXT = "Command execution smoke complete."
SUCCESS_CALL_ID = "call-command-success"
FAIL_CALL_ID = "call-command-failure"
SUCCESS_COMMAND = (
    "printf 'CMD_OK_STDOUT\\n'; sleep 0.1; printf 'CMD_OK_STDERR\\n' >&2"
)
FAIL_COMMAND = (
    "printf 'CMD_FAIL_STDOUT\\n'; sleep 0.1; printf 'CMD_FAIL_STDERR\\n' >&2; exit 7"
)


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


def ev_final_message(response_id: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-command-final",
                    "content": [{"type": "output_text", "text": FINAL_TEXT}],
                },
            },
            ev_completed(response_id),
        ]
    )


class SequenceResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_shell_command_call("resp-command-1", SUCCESS_CALL_ID, SUCCESS_COMMAND),
            ev_shell_command_call("resp-command-2", FAIL_CALL_ID, FAIL_COMMAND),
            ev_final_message("resp-command-3"),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "SequenceResponsesServer":
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
            return ev_final_message("resp-command-extra")
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
            "contains_success_function_output": any(
                SUCCESS_CALL_ID in body and "function_call_output" in body
                for body in serialized_bodies
            ),
            "contains_failure_function_output": any(
                FAIL_CALL_ID in body and "function_call_output" in body
                for body in serialized_bodies
            ),
            "contains_success_stdout": any("CMD_OK_STDOUT" in body for body in serialized_bodies),
            "contains_failure_stdout": any(
                "CMD_FAIL_STDOUT" in body for body in serialized_bodies
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
                server: SequenceResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def status_type(value: Any) -> Any:
    if isinstance(value, dict):
        return value.get("type")
    return value


def command_items_from_thread_read(response: dict[str, Any]) -> list[dict[str, Any]]:
    thread = ((response.get("result") or {}).get("thread") or {})
    commands = []
    for turn in thread.get("turns") or []:
        for item in turn.get("items") or []:
            if item.get("type") == "commandExecution":
                output = item.get("aggregatedOutput") or ""
                commands.append(
                    {
                        "command": item.get("command"),
                        "source": item.get("source"),
                        "status": status_type(item.get("status")),
                        "exitCode": item.get("exitCode"),
                        "contains_ok_stdout": "CMD_OK_STDOUT" in output,
                        "contains_ok_stderr": "CMD_OK_STDERR" in output,
                        "contains_fail_stdout": "CMD_FAIL_STDOUT" in output,
                        "contains_fail_stderr": "CMD_FAIL_STDERR" in output,
                    }
                )
    return commands


def command_items_from_completed_notifications(
    received: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    commands = []
    for message in received:
        if message.get("method") != "item/completed":
            continue
        item = ((message.get("params") or {}).get("item") or {})
        if item.get("type") != "commandExecution":
            continue
        output = item.get("aggregatedOutput") or ""
        commands.append(
            {
                "command": item.get("command"),
                "source": item.get("source"),
                "status": status_type(item.get("status")),
                "exitCode": item.get("exitCode"),
                "contains_ok_stdout": "CMD_OK_STDOUT" in output,
                "contains_ok_stderr": "CMD_OK_STDERR" in output,
                "contains_fail_stdout": "CMD_FAIL_STDOUT" in output,
                "contains_fail_stderr": "CMD_FAIL_STDERR" in output,
            }
        )
    return commands


def normalized_live_command_event_sequence(
    received: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method in {"item/started", "item/completed"}:
            item = params.get("item") or {}
            if item.get("type") != "commandExecution":
                continue
            event: dict[str, Any] = {
                "event": "started" if method == "item/started" else "completed",
                "itemId": item.get("id"),
                "command": item.get("command"),
                "source": item.get("source"),
                "status": status_type(item.get("status")),
            }
            if method == "item/completed":
                event.update(
                    {
                        "exitCode": item.get("exitCode"),
                        "aggregatedOutput": item.get("aggregatedOutput"),
                    }
                )
            sequence.append(event)
        elif method == "item/commandExecution/outputDelta":
            sequence.append(
                {
                    "event": "outputDelta",
                    "itemId": params.get("itemId"),
                    "delta": params.get("delta"),
                }
            )
    return sequence


def notification_summary(received: list[dict[str, Any]]) -> dict[str, Any]:
    output_deltas = [
        message
        for message in received
        if message.get("method") == "item/commandExecution/outputDelta"
    ]
    serialized = json.dumps(output_deltas, ensure_ascii=False)
    return {
        "output_delta_count": len(output_deltas),
        "contains_ok_stdout": "CMD_OK_STDOUT" in serialized,
        "contains_ok_stderr": "CMD_OK_STDERR" in serialized,
        "contains_fail_stdout": "CMD_FAIL_STDOUT" in serialized,
        "contains_fail_stderr": "CMD_FAIL_STDERR" in serialized,
    }


def summarize_command_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        command_events = [line for line in timeline_lines if str(line.get("type")).startswith("command")]
        packages.append(
            {
                "package": str(package),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "command_event_types": [line.get("type") for line in command_events],
                "command_event_count": len(command_events),
                "source_response_types": [
                    ((line.get("body") or {}).get("source_response_type"))
                    for line in command_events
                ],
                "call_ids": [
                    ((line.get("body") or {}).get("call_id"))
                    for line in command_events
                ],
            }
        )
    return {
        "package_count": len(packages),
        "packages": packages,
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

    with SequenceResponsesServer() as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
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
                        "clientUserMessageId": "client-user-command-smoke",
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

    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_completed_notification": turn_completed_notification,
        "thread_read_response": thread_read_response,
        "normalized_thread_read_command_items": command_items_from_thread_read(
            thread_read_response
        ),
        "normalized_live_command_items": command_items_from_completed_notifications(
            client.received
        ),
        "normalized_live_command_event_sequence": normalized_live_command_event_sequence(
            client.received
        ),
        "notification_summary": notification_summary(client.received),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["command_timeline_summary"] = summarize_command_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-command-execution-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_live_commands = original_result["normalized_live_command_items"]
    chat_live_commands = chat_result["normalized_live_command_items"]
    original_live_sequence = original_result["normalized_live_command_event_sequence"]
    chat_live_sequence = chat_result["normalized_live_command_event_sequence"]
    original_thread_read_commands = original_result["normalized_thread_read_command_items"]
    chat_thread_read_commands = chat_result["normalized_thread_read_command_items"]
    command_timeline_summary = chat_result["command_timeline_summary"]
    command_event_types = [
        event_type
        for package in command_timeline_summary["packages"]
        for event_type in package["command_event_types"]
    ]
    exit_codes = [item["exitCode"] for item in chat_live_commands]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-command-execution-smoke",
        "binary_checks": binary_checks,
        "original_turn_start_exit_ok": "result" in original_result["turn_start_response"],
        "chat_backend_turn_start_exit_ok": "result" in chat_result["turn_start_response"],
        "original_thread_read_exit_ok": "result" in original_result["thread_read_response"],
        "chat_backend_thread_read_exit_ok": "result" in chat_result["thread_read_response"],
        "normalized_live_command_items_equal": original_live_commands == chat_live_commands,
        "normalized_live_command_event_sequence_equal": (
            original_live_sequence == chat_live_sequence
        ),
        "normalized_thread_read_command_items_equal": (
            original_thread_read_commands == chat_thread_read_commands
        ),
        "original_normalized_live_command_items": original_live_commands,
        "chat_backend_normalized_live_command_items": chat_live_commands,
        "original_normalized_live_command_event_sequence": original_live_sequence,
        "chat_backend_normalized_live_command_event_sequence": chat_live_sequence,
        "original_normalized_thread_read_command_items": original_thread_read_commands,
        "chat_backend_normalized_thread_read_command_items": chat_thread_read_commands,
        "chat_backend_exit_codes": exit_codes,
        "chat_backend_has_success_exit": 0 in exit_codes,
        "chat_backend_has_failure_exit": 7 in exit_codes,
        "notification_summaries": {
            "original": original_result["notification_summary"],
            "chat-backend": chat_result["notification_summary"],
        },
        "mock_server_summaries": {
            "original": original_result["mock_server_summary"],
            "chat-backend": chat_result["mock_server_summary"],
        },
        "mock_response_request_counts_equal": (
            original_result["mock_server_summary"]["response_request_count"]
            == chat_result["mock_server_summary"]["response_request_count"]
        ),
        "chat_timeline_has_command_call": "command_call" in command_event_types,
        "chat_timeline_has_command_output": "command_output" in command_event_types,
        "command_timeline_summary": command_timeline_summary,
        "chat_package_summary": chat_result["chat_package_summary"],
        "original_storage_summary": original_result["original_storage_summary"],
        "not_yet_proven": [
            "approval/permission command flow",
            "artifact-producing commands",
            "crash recovery during command execution",
            "complete command data fidelity report",
        ],
    }

    write_json(output_dir / "original/command-execution-response.json", original_result)
    write_json(output_dir / "chat-backend/command-execution-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Command Execution Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API that returns two `shell_command` function calls followed by a
final assistant message.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, and relevant Codex command
source files were read.

## Scope

This smoke covers parity matrix slices T01, T02, and T03 at smoke-test depth:
successful command execution, non-zero command execution, stdout/stderr marker
presence and ordering, exit status preservation, model-visible
`function_call_output` round-trip, live command event sequence parity, and
`.chat` command timeline classification.

It does not prove approval flows, artifacts, or crash recovery.

## Result

- original `turn/start` response succeeded: `{summary['original_turn_start_exit_ok']}`
- `.chat` backend `turn/start` response succeeded: `{summary['chat_backend_turn_start_exit_ok']}`
- original `thread/read` response succeeded: `{summary['original_thread_read_exit_ok']}`
- `.chat` backend `thread/read` response succeeded: `{summary['chat_backend_thread_read_exit_ok']}`
- normalized live command execution items equal: `{summary['normalized_live_command_items_equal']}`
- normalized live command event sequence equal: `{summary['normalized_live_command_event_sequence_equal']}`
- normalized `thread/read` command item lists equal: `{summary['normalized_thread_read_command_items_equal']}`
- mock Responses request counts equal: `{summary['mock_response_request_counts_equal']}`
- `.chat` timeline has `command_call`: `{summary['chat_timeline_has_command_call']}`
- `.chat` timeline has `command_output`: `{summary['chat_timeline_has_command_output']}`
- `.chat` backend exit codes: `{summary['chat_backend_exit_codes']}`

## Normalized Commands

```json
{json.dumps({'original': original_live_commands, 'chat-backend': chat_live_commands}, indent=2, sort_keys=True)}
```

## Normalized Live Command Event Sequence

```json
{json.dumps({'original': original_live_sequence, 'chat-backend': chat_live_sequence}, indent=2, sort_keys=True)}
```

## `.chat` Command Timeline

```json
{json.dumps(command_timeline_summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-execution-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/command-execution-response.json
```
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    ok = (
        summary["original_turn_start_exit_ok"]
        and summary["chat_backend_turn_start_exit_ok"]
        and summary["original_thread_read_exit_ok"]
        and summary["chat_backend_thread_read_exit_ok"]
        and summary["normalized_live_command_items_equal"]
        and summary["normalized_live_command_event_sequence_equal"]
        and summary["normalized_thread_read_command_items_equal"]
        and summary["mock_response_request_counts_equal"]
        and summary["chat_timeline_has_command_call"]
        and summary["chat_timeline_has_command_output"]
        and summary["chat_backend_has_success_exit"]
        and summary["chat_backend_has_failure_exit"]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
