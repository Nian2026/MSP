#!/usr/bin/env python3
"""Run command-approval cold-resume parity smoke for original vs `.chat` backend."""

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
from app_server_command_approval_smoke import normalized_live_sequence
from app_server_command_approval_smoke import summarize_chat_timeline
from app_server_command_approval_smoke import summarize_original_rollouts
from app_server_command_approval_smoke import write_approval_config
from app_server_cold_resume_smoke import chat_journal_line_count
from app_server_cold_resume_smoke import chat_timeline_line_count
from app_server_cold_resume_smoke import original_line_count
from app_server_cold_resume_smoke import send_initialize
from app_server_cold_resume_smoke import send_thread_list
from app_server_cold_resume_smoke import send_thread_read
from app_server_cold_resume_smoke import send_thread_resume
from app_server_cold_resume_smoke import send_thread_start
from app_server_cold_resume_smoke import send_turn_start
from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import JsonRpcClient
from app_server_durable_turn_smoke import ensure_binary
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import summarize_path_observation
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json


FIRST_USER_TEXT = "Run the command approval cold-resume validation."
SECOND_USER_TEXT = "Continue after command approval cold resume."
FIRST_FINAL_TEXT = "Command approval cold-resume first turn complete."
SECOND_FINAL_TEXT = "Command approval cold-resume follow-up complete."
CALL_ID = "call-approval-cold-resume"
COMMAND = "printf 'APPROVAL_ACCEPT_STDOUT\\n'"
STDOUT_MARKER = "APPROVAL_ACCEPT_STDOUT"


class ApprovalColdResumeResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_shell_command_call(
                "resp-approval-cold-resume-call",
                CALL_ID,
                COMMAND,
            ),
            ev_final_message(
                "resp-approval-cold-resume-first-final",
                "msg-approval-cold-resume-first-final",
                FIRST_FINAL_TEXT,
            ),
            ev_final_message(
                "resp-approval-cold-resume-second-final",
                "msg-approval-cold-resume-second-final",
                SECOND_FINAL_TEXT,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "ApprovalColdResumeResponsesServer":
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
                "resp-approval-cold-resume-extra",
                "msg-approval-cold-resume-extra",
                "extra command approval cold resume response",
            )
        return self.responses[index - 1]

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
                server: ApprovalColdResumeResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def response_request_bodies(requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        request["json"]
        for request in requests
        if request.get("path", "").endswith("/responses")
    ]


def response_input_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
    serialized_bodies = [json.dumps(body, ensure_ascii=False) for body in bodies]
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "paths": [request["path"] for request in requests],
        "first_response_model": first_body.get("model"),
        "second_response_model": second_body.get("model"),
        "third_response_model": third_body.get("model"),
        "first_response_input_contains_first_user_text": response_input_contains(
            first_body,
            FIRST_USER_TEXT,
        ),
        "second_response_input_contains_call_id": response_input_contains(
            second_body,
            CALL_ID,
        ),
        "second_response_input_contains_stdout": response_input_contains(
            second_body,
            STDOUT_MARKER,
        ),
        "third_response_input_contains_first_user_text": response_input_contains(
            third_body,
            FIRST_USER_TEXT,
        ),
        "third_response_input_contains_first_final_text": response_input_contains(
            third_body,
            FIRST_FINAL_TEXT,
        ),
        "third_response_input_contains_call_id": response_input_contains(
            third_body,
            CALL_ID,
        ),
        "third_response_input_contains_stdout": response_input_contains(
            third_body,
            STDOUT_MARKER,
        ),
        "third_response_input_contains_second_user_text": response_input_contains(
            third_body,
            SECOND_USER_TEXT,
        ),
        "contains_function_call_output": any(
            CALL_ID in body and "function_call_output" in body
            for body in serialized_bodies
        ),
        "contains_stdout": any(STDOUT_MARKER in body for body in serialized_bodies),
    }


def status_type(value: Any) -> Any:
    if isinstance(value, dict):
        return value.get("type")
    return value


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_ephemeral": thread.get("ephemeral"),
        "thread_history_mode": thread.get("historyMode"),
        "thread_source": thread.get("source"),
        "thread_status_type": status_type(thread.get("status")),
        "model": thread.get("model"),
        "model_provider": thread.get("modelProvider"),
        "preview": thread.get("preview"),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in turn.get("items") or []] for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
        "contains_second_user_text": SECOND_USER_TEXT in serialized,
        "contains_first_final_text": FIRST_FINAL_TEXT in serialized,
        "contains_second_final_text": SECOND_FINAL_TEXT in serialized,
        "contains_call_id": CALL_ID in serialized,
        "contains_stdout": STDOUT_MARKER in serialized,
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


def receive_command_approval_turn(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": "client-user-command-approval-cold-resume-1",
                "input": [
                    {
                        "type": "text",
                        "text": FIRST_USER_TEXT,
                        "textElements": [],
                    }
                ],
            },
        }
    )
    turn_start_response = client.receive_until_response(request_id, timeout_seconds=30)
    turn_id = ((turn_start_response.get("result") or {}).get("turn") or {}).get("id")
    approval_request: dict[str, Any] = {}
    turn_completed_notification: dict[str, Any] = {}
    notification_errors: list[str] = []
    if "error" not in turn_start_response:
        try:
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
        except TimeoutError as exc:
            notification_errors.append(str(exc))
    return {
        "response": turn_start_response,
        "turn_id": turn_id,
        "approval_request": approval_request,
        "turn_completed": turn_completed_notification,
        "notification_errors": notification_errors,
    }


def command_cold_resume_package_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    event_types = set(package.get("timeline_event_types") or [])
    return (
        package.get("manifest_format") == "msp.chat"
        and package.get("timeline_line_count", 0) >= 8
        and package.get("journal_line_count", 0) >= 8
        and "message" in event_types
        and "command_call" in event_types
        and "command_output" in event_types
    )


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

    with ApprovalColdResumeResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_turn_start_response = receive_command_approval_turn(
                first_client,
                3,
                started_thread_id,
            )
            first_thread_read_response = send_thread_read(
                first_client,
                4,
                started_thread_id,
            )
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            thread_resume_response = send_thread_resume(second_client, 102, started_thread_id)
            resumed_thread_id = (
                ((thread_resume_response.get("result") or {}).get("thread") or {}).get("id")
                or started_thread_id
            )
            post_resume_thread_read_response = send_thread_read(
                second_client,
                103,
                resumed_thread_id,
            )
            second_turn_start_response = send_turn_start(
                second_client,
                104,
                resumed_thread_id,
                "client-user-command-approval-cold-resume-2",
                SECOND_USER_TEXT,
            )
            final_thread_read_response = send_thread_read(
                second_client,
                105,
                resumed_thread_id,
            )
            final_thread_list_response = send_thread_list(second_client, 106)
        finally:
            second_stderr = second_client.close()

    expected = {
        "thread_id": started_thread_id,
        "turn_id": first_turn_start_response.get("turn_id"),
        "call_id": CALL_ID,
        "command_marker": STDOUT_MARKER,
    }
    result = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "first_process": {
            "command": first_client.command,
            "initialize_response": first_initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": first_turn_start_response,
            "thread_read_response": first_thread_read_response,
            "normalized_approval_request": normalize_approval_request(
                first_turn_start_response["approval_request"],
                expected,
            ),
            "normalized_live_sequence": normalized_live_sequence(first_client.received),
            "normalized_thread_read_command_items": command_items_from_thread_read(
                first_thread_read_response
            ),
            "jsonrpc_sent": first_client.sent,
            "jsonrpc_received": first_client.received,
            "stderr_tail": first_stderr[-6000:],
            "process_exit_code": first_client.process.returncode,
        },
        "second_process": {
            "command": second_client.command,
            "initialize_response": second_initialize_response,
            "thread_resume_response": thread_resume_response,
            "post_resume_thread_read_response": post_resume_thread_read_response,
            "turn_start_response": second_turn_start_response,
            "final_thread_read_response": final_thread_read_response,
            "final_thread_list_response": final_thread_list_response,
            "jsonrpc_sent": second_client.sent,
            "jsonrpc_received": second_client.received,
            "stderr_tail": second_stderr[-6000:],
            "process_exit_code": second_client.process.returncode,
        },
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "normalized_resume": normalize_thread_response(thread_resume_response),
        "normalized_post_resume_read": normalize_thread_response(
            post_resume_thread_read_response
        ),
        "normalized_final_read": normalize_thread_response(final_thread_read_response),
        "normalized_final_list": normalize_thread_list_response(
            final_thread_list_response,
            started_thread_id,
        ),
        "thread_read_path_observations": {
            "first_read": summarize_path_observation(
                first_thread_read_response,
                started_thread_id,
            ),
            "post_resume_read": summarize_path_observation(
                post_resume_thread_read_response,
                started_thread_id,
            ),
            "final_read": summarize_path_observation(
                final_thread_read_response,
                started_thread_id,
            ),
        },
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_timeline_summary"] = summarize_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_original_rollouts(codex_home)
    return result


def first_process_ok(result: dict[str, Any]) -> bool:
    turn = result["first_process"]["turn_start_response"]
    request = result["first_process"]["normalized_approval_request"]
    live_sequence = result["first_process"]["normalized_live_sequence"]
    if "result" not in turn["response"]:
        return False
    if turn["notification_errors"]:
        return False
    if not request["thread_id_matches"] or not request["turn_id_matches"]:
        return False
    if not request["item_id_matches"] or not request["command_contains_expected_marker"]:
        return False
    return any(
            event.get("event") == "completed"
            and (event.get("item") or {}).get("status") == "completed"
            and (event.get("item") or {}).get("exitCode") == 0
            and (event.get("item") or {}).get("contains_accept_stdout")
            for event in live_sequence
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-command-approval-cold-resume-smoke-"
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
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original = run_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_backend = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_resume = original["normalized_resume"]
    chat_resume = chat_backend["normalized_resume"]
    original_post_resume_read = original["normalized_post_resume_read"]
    chat_post_resume_read = chat_backend["normalized_post_resume_read"]
    original_final_read = original["normalized_final_read"]
    chat_final_read = chat_backend["normalized_final_read"]
    original_final_list = original["normalized_final_list"]
    chat_final_list = chat_backend["normalized_final_list"]
    original_mock = original["mock_server_summary"]
    chat_mock = chat_backend["mock_server_summary"]
    original_storage = original["original_storage_summary"]
    chat_package = chat_backend["chat_package_summary"]
    original_lines = original_line_count(original_storage)
    chat_journal_lines = chat_journal_line_count(chat_package)
    chat_timeline_lines = chat_timeline_line_count(chat_package)
    journal_line_count_matches_original = (
        original_lines is not None and original_lines == chat_journal_lines
    )

    mock_third_turn_context_ok = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["third_response_input_contains_first_user_text"],
            chat_mock["third_response_input_contains_first_user_text"],
            original_mock["third_response_input_contains_first_final_text"],
            chat_mock["third_response_input_contains_first_final_text"],
            original_mock["third_response_input_contains_call_id"],
            chat_mock["third_response_input_contains_call_id"],
            original_mock["third_response_input_contains_stdout"],
            chat_mock["third_response_input_contains_stdout"],
            original_mock["third_response_input_contains_second_user_text"],
            chat_mock["third_response_input_contains_second_user_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-command-approval-cold-resume-smoke",
        "binary_checks": binary_checks,
        "original_first_process_ok": first_process_ok(original),
        "chat_backend_first_process_ok": first_process_ok(chat_backend),
        "original_resume_exit_ok": "result"
        in original["second_process"]["thread_resume_response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_backend["second_process"]["thread_resume_response"],
        "original_second_turn_exit_ok": "result"
        in original["second_process"]["turn_start_response"]["response"],
        "chat_backend_second_turn_exit_ok": "result"
        in chat_backend["second_process"]["turn_start_response"]["response"],
        "original_second_turn_notifications_ok": not original["second_process"][
            "turn_start_response"
        ]["notification_errors"],
        "chat_backend_second_turn_notifications_ok": not chat_backend["second_process"][
            "turn_start_response"
        ]["notification_errors"],
        "normalized_first_approval_request_equal": (
            original["first_process"]["normalized_approval_request"]
            == chat_backend["first_process"]["normalized_approval_request"]
        ),
        "normalized_first_live_sequence_equal": (
            original["first_process"]["normalized_live_sequence"]
            == chat_backend["first_process"]["normalized_live_sequence"]
        ),
        "normalized_first_thread_read_command_items_equal": (
            original["first_process"]["normalized_thread_read_command_items"]
            == chat_backend["first_process"]["normalized_thread_read_command_items"]
        ),
        "normalized_resume_equal": original_resume == chat_resume,
        "normalized_post_resume_read_equal": (
            original_post_resume_read == chat_post_resume_read
        ),
        "normalized_final_read_equal": original_final_read == chat_final_read,
        "normalized_final_list_equal": original_final_list == chat_final_list,
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
            == 3
        ),
        "mock_function_output_context_equal": (
            original_mock["contains_function_call_output"]
            == chat_mock["contains_function_call_output"]
            == True
        ),
        "mock_stdout_context_equal": (
            original_mock["contains_stdout"] == chat_mock["contains_stdout"] == True
        ),
        "mock_third_turn_context_ok": mock_third_turn_context_ok,
        "chat_package_resume_ok": command_cold_resume_package_ok(chat_package),
        "journal_line_count_matches_original": journal_line_count_matches_original,
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_resume": original_resume,
        "chat_backend_normalized_resume": chat_resume,
        "original_normalized_post_resume_read": original_post_resume_read,
        "chat_backend_normalized_post_resume_read": chat_post_resume_read,
        "original_normalized_final_read": original_final_read,
        "chat_backend_normalized_final_read": chat_final_read,
        "original_normalized_final_list": original_final_list,
        "chat_backend_normalized_final_list": chat_final_list,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_first_live_sequence": original["first_process"]["normalized_live_sequence"],
        "chat_backend_first_live_sequence": chat_backend["first_process"][
            "normalized_live_sequence"
        ],
        "chat_timeline_summary": chat_backend["chat_timeline_summary"],
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "thread_read_path_observations": {
            "original": original["thread_read_path_observations"],
            "chat-backend": chat_backend["thread_read_path_observations"],
        },
        "all_scenarios_ok": False,
        "not_yet_proven": [
            "zsh subcommand approval_id routing",
            "network approval",
            "permission profile request/response persistence",
            "complete T06 data fidelity report",
            "pending unload race after idle unload delay",
            "compaction parity",
            "crash recovery parity",
            "final user-indistinguishability under normal Codex usage",
        ],
    }
    summary["all_scenarios_ok"] = all(
        [
            summary["original_first_process_ok"],
            summary["chat_backend_first_process_ok"],
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_second_turn_exit_ok"],
            summary["chat_backend_second_turn_exit_ok"],
            summary["original_second_turn_notifications_ok"],
            summary["chat_backend_second_turn_notifications_ok"],
            summary["normalized_first_approval_request_equal"],
            summary["normalized_first_live_sequence_equal"],
            summary["normalized_first_thread_read_command_items_equal"],
            summary["normalized_resume_equal"],
            summary["normalized_post_resume_read_equal"],
            summary["normalized_final_read_equal"],
            summary["normalized_final_list_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_function_output_context_equal"],
            summary["mock_stdout_context_equal"],
            summary["mock_third_turn_context_ok"],
            summary["chat_package_resume_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )

    write_json(output_dir / "original/command-approval-cold-resume-response.json", original)
    write_json(
        output_dir / "chat-backend/command-approval-cold-resume-response.json",
        chat_backend,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Command Approval Cold Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with `approval_policy = "untrusted"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant vendored Codex approval/resume source files were read.

## Scope

This smoke covers the T06/R01 intersection for a completed shell command
approval turn:

- first app-server process starts a thread;
- mock model emits a `shell_command` call;
- app-server emits `item/commandExecution/requestApproval`;
- the client accepts the request;
- the command completes with stdout and exit `0`;
- the first turn completes and is durably stored;
- a fresh app-server process resumes the thread;
- a second turn confirms the resumed model input still contains the first user
  text, command call id, command stdout, first final answer, and second user
  text;
- final `thread/read` and `thread/list` remain normalized-equal.

This proves only this completed command-approval cold-resume slice. It does not
prove zsh subcommand `approval_id` routing, network approval, permission profile
approval, compaction, crash recovery, complete data fidelity, or final
user-indistinguishability.

## Result

- original first command approval turn ok: `{summary['original_first_process_ok']}`
- `.chat` backend first command approval turn ok: `{summary['chat_backend_first_process_ok']}`
- original `thread/resume` response succeeded: `{summary['original_resume_exit_ok']}`
- `.chat` backend `thread/resume` response succeeded: `{summary['chat_backend_resume_exit_ok']}`
- original second `turn/start` response succeeded: `{summary['original_second_turn_exit_ok']}`
- `.chat` backend second `turn/start` response succeeded: `{summary['chat_backend_second_turn_exit_ok']}`
- normalized first approval request fields equal: `{summary['normalized_first_approval_request_equal']}`
- normalized first live command sequence equal: `{summary['normalized_first_live_sequence_equal']}`
- normalized first thread/read command items equal: `{summary['normalized_first_thread_read_command_items_equal']}`
- normalized original vs `.chat` `thread/resume` fields equal: `{summary['normalized_resume_equal']}`
- normalized original vs `.chat` post-resume `thread/read` fields equal: `{summary['normalized_post_resume_read_equal']}`
- normalized original vs `.chat` final `thread/read` fields equal: `{summary['normalized_final_read_equal']}`
- normalized original vs `.chat` final `thread/list` fields equal: `{summary['normalized_final_list_equal']}`
- third model request included prior command approval context: `{summary['mock_third_turn_context_ok']}`
- durable `.chat` package remained readable after resume: `{summary['chat_package_resume_ok']}`
- `.chat` journal line count matched original rollout line count: `{summary['journal_line_count_matches_original']}`

## Normalized Resume

```json
{json.dumps({'original': original_resume, 'chat-backend': chat_resume}, indent=2, sort_keys=True)}
```

## Final Thread Read

```json
{json.dumps({'original': original_final_read, 'chat-backend': chat_final_read}, indent=2, sort_keys=True)}
```

## First Live Command Sequence

```json
{json.dumps({'original': summary['original_first_live_sequence'], 'chat-backend': summary['chat_backend_first_live_sequence']}, indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat-backend': chat_mock}, indent=2, sort_keys=True)}
```

## `.chat` Package Observation

```json
{json.dumps(chat_package, indent=2, sort_keys=True)}
```

## `.chat` Timeline Observation

```json
{json.dumps(chat_backend['chat_timeline_summary'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/command-approval-cold-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/command-approval-cold-resume-response.json
```

## Not Yet Proven

This smoke does not prove zsh subcommand `approval_id` routing, network
approval, permission profile approval, complete T06 data fidelity, pending
unload after the idle unload delay, compaction, crash recovery, or final
user-indistinguishability under normal Codex usage.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
