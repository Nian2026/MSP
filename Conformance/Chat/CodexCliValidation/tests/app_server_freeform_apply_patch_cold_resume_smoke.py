#!/usr/bin/env python3
"""Run freeform apply_patch cold-resume parity smoke for Codex `.chat` backend."""

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

from app_server_cold_resume_smoke import chat_journal_line_count
from app_server_cold_resume_smoke import chat_timeline_line_count
from app_server_cold_resume_smoke import original_line_count
from app_server_cold_resume_smoke import send_initialize
from app_server_cold_resume_smoke import send_thread_list
from app_server_cold_resume_smoke import send_thread_read
from app_server_cold_resume_smoke import send_thread_resume
from app_server_cold_resume_smoke import send_thread_start
from app_server_cold_resume_smoke import send_turn_start
from app_server_command_approval_smoke import ev_final_message
from app_server_command_approval_smoke import status_type
from app_server_command_approval_smoke import write_approval_config
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
from app_server_file_change_approval_smoke import ADD_README_PATCH
from app_server_file_change_approval_smoke import normalize_file_change_item
from app_server_file_change_approval_smoke import normalize_file_change_request
from app_server_file_change_approval_smoke import receive_file_change_completed
from app_server_file_change_approval_smoke import receive_file_change_started
from app_server_freeform_apply_patch_smoke import PATCH_CALL_ID
from app_server_freeform_apply_patch_smoke import README_CONTENT
from app_server_freeform_apply_patch_smoke import ev_apply_patch_custom_tool_call
from app_server_freeform_apply_patch_smoke import freeform_model_info
from app_server_freeform_apply_patch_smoke import normalized_live_sequence
from app_server_freeform_apply_patch_smoke import summarize_freeform_chat_timeline
from app_server_freeform_apply_patch_smoke import summarize_freeform_original_rollouts
from app_server_freeform_apply_patch_smoke import write_freeform_models_cache


FIRST_USER_TEXT = "Apply the freeform apply_patch before cold resume."
FIRST_FINAL_TEXT = "Freeform apply_patch before cold resume complete."
SECOND_USER_TEXT = "Continue after freeform apply_patch cold resume."
SECOND_FINAL_TEXT = "Freeform apply_patch cold resume follow-up complete."


class FreeformApplyPatchColdResumeResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_apply_patch_custom_tool_call(
                "resp-freeform-apply-patch-cold-resume-patch",
                PATCH_CALL_ID,
                ADD_README_PATCH,
            ),
            ev_final_message(
                "resp-freeform-apply-patch-cold-resume-first-final",
                "msg-freeform-apply-patch-cold-resume-first-final",
                FIRST_FINAL_TEXT,
            ),
            ev_final_message(
                "resp-freeform-apply-patch-cold-resume-second-final",
                "msg-freeform-apply-patch-cold-resume-second-final",
                SECOND_FINAL_TEXT,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "FreeformApplyPatchColdResumeResponsesServer":
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
                [
                    request
                    for request in self.requests
                    if request["path"].endswith("/responses")
                ]
            )
        if index < 1 or index > len(self.responses):
            return ev_final_message(
                "resp-freeform-apply-patch-cold-resume-extra",
                "msg-freeform-apply-patch-cold-resume-extra",
                "extra freeform apply_patch cold resume response",
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
                    body = json.dumps({"models": [freeform_model_info()]}).encode()
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
                server: FreeformApplyPatchColdResumeResponsesServer = (
                    self.server.mock_server  # type: ignore[attr-defined]
                )
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


def response_input_contains_tool_output(body: dict[str, Any]) -> bool:
    serialized = json.dumps(body.get("input"), ensure_ascii=False)
    return (
        PATCH_CALL_ID in serialized
        and (
            "custom_tool_call_output" in serialized
            or "function_call_output" in serialized
        )
    )


def summarize_mock_requests(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    first_body = bodies[0] if len(bodies) > 0 else {}
    second_body = bodies[1] if len(bodies) > 1 else {}
    third_body = bodies[2] if len(bodies) > 2 else {}
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
        "second_response_input_contains_patch_call_id": response_input_contains(
            second_body,
            PATCH_CALL_ID,
        ),
        "second_response_input_contains_tool_output": response_input_contains_tool_output(
            second_body,
        ),
        "third_response_input_contains_first_user_text": response_input_contains(
            third_body,
            FIRST_USER_TEXT,
        ),
        "third_response_input_contains_first_final_text": response_input_contains(
            third_body,
            FIRST_FINAL_TEXT,
        ),
        "third_response_input_contains_patch_call_id": response_input_contains(
            third_body,
            PATCH_CALL_ID,
        ),
        "third_response_input_contains_tool_output": response_input_contains_tool_output(
            third_body,
        ),
        "third_response_input_contains_second_user_text": response_input_contains(
            third_body,
            SECOND_USER_TEXT,
        ),
    }


def normalize_thread_response(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized_turns = json.dumps(turns, ensure_ascii=False)
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
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_first_user_text": FIRST_USER_TEXT in serialized_turns,
        "contains_first_final_text": FIRST_FINAL_TEXT in serialized_turns,
        "contains_second_user_text": SECOND_USER_TEXT in serialized_turns,
        "contains_second_final_text": SECOND_FINAL_TEXT in serialized_turns,
        "contains_patch_call_id": PATCH_CALL_ID in serialized_turns,
        "contains_file_change_item": "fileChange" in serialized_turns,
        "contains_completed_file_change": (
            "fileChange" in serialized_turns and "completed" in serialized_turns
        ),
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


def first_freeform_file_change_turn_ok(result: dict[str, Any]) -> bool:
    first_process = result["first_process"]
    request = first_process["normalized_file_change_request"]
    started = first_process["normalized_file_change_started"]
    completed = first_process["normalized_file_change_completed"]
    return all(
        [
            "result" in first_process["turn_start_response"],
            request is not None,
            request["thread_id_matches"],
            request["turn_id_matches"],
            request["item_id_matches"],
            started["id"] == PATCH_CALL_ID,
            started["status"] == "inProgress",
            started["has_readme_path"],
            completed["id"] == PATCH_CALL_ID,
            completed["status"] == "completed",
            completed["has_readme_path"],
        ]
    )


def chat_package_freeform_file_change_ok(summary: dict[str, Any]) -> bool:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return False
    package = packages[0]
    return (
        package["timeline_tool_call_count"] >= 1
        and package["timeline_tool_output_count"] >= 1
        and package["timeline_command_call_count"] == 0
        and package["timeline_command_output_count"] == 0
        and package["journal_custom_apply_patch_call_count"] >= 1
        and package["journal_custom_tool_call_output_count"] >= 1
        and package["journal_has_patch_call_id"]
        and package["journal_has_patch_text"]
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
    readme_path = workspace / "README.md"

    with FreeformApplyPatchColdResumeResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        write_freeform_models_cache(codex_home)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            started_thread_id, thread_start_response = send_thread_start(
                first_client,
                2,
                workspace,
            )
            first_client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "turn/start",
                    "params": {
                        "threadId": started_thread_id,
                        "clientUserMessageId": "client-user-freeform-cold-resume-1",
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
            first_turn_start_response = first_client.receive_until_response(
                3,
                timeout_seconds=30,
            )
            first_turn_id = (
                ((first_turn_start_response.get("result") or {}).get("turn") or {}).get("id")
            )
            expected = {"thread_id": started_thread_id, "turn_id": first_turn_id}

            file_change_started = receive_file_change_started(first_client, PATCH_CALL_ID)
            file_change_request = first_client.receive_until(
                lambda message: message.get("method") == "item/fileChange/requestApproval"
                and (message.get("params") or {}).get("itemId") == PATCH_CALL_ID,
                timeout_seconds=30,
                description="freeform fileChange requestApproval before cold resume",
            )
            first_client.send(
                {
                    "jsonrpc": "2.0",
                    "id": file_change_request.get("id"),
                    "result": {"decision": "accept"},
                }
            )
            file_change_completed = receive_file_change_completed(
                first_client,
                PATCH_CALL_ID,
            )
            first_turn_completed = first_client.receive_until_method(
                "turn/completed",
                timeout_seconds=90,
            )
            first_thread_read_response = send_thread_read(
                first_client,
                4,
                started_thread_id,
            )
            first_live_sequence = normalized_live_sequence(first_client.received)
        finally:
            first_stderr = first_client.close()

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            thread_resume_response = send_thread_resume(
                second_client,
                102,
                started_thread_id,
            )
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
                "client-user-freeform-cold-resume-2",
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

    readme_contents = readme_path.read_text() if readme_path.exists() else None
    result = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "readme_contents": readme_contents,
        "first_process": {
            "command": first_client.command,
            "initialize_response": first_initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": first_turn_start_response,
            "turn_id": first_turn_id,
            "file_change_started": file_change_started,
            "normalized_file_change_started": normalize_file_change_item(
                ((file_change_started.get("params") or {}).get("item") or {})
            ),
            "file_change_request": file_change_request,
            "normalized_file_change_request": normalize_file_change_request(
                file_change_request,
                expected,
                PATCH_CALL_ID,
            ),
            "file_change_completed": file_change_completed,
            "normalized_file_change_completed": normalize_file_change_item(
                ((file_change_completed.get("params") or {}).get("item") or {})
            ),
            "turn_completed": first_turn_completed,
            "thread_read_response": first_thread_read_response,
            "normalized_live_sequence": first_live_sequence,
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
        "normalized_first_read": normalize_thread_response(first_thread_read_response),
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
        result["chat_timeline_summary"] = summarize_freeform_chat_timeline(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_rollout_summary"] = summarize_freeform_original_rollouts(
            codex_home
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-freeform-apply-patch-cold-resume-smoke-"
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

    original_storage = original_result["original_storage_summary"]
    chat_package = chat_result["chat_package_summary"]
    original_lines = original_line_count(original_storage)
    chat_journal_lines = chat_journal_line_count(chat_package)
    chat_timeline_lines = chat_timeline_line_count(chat_package)
    journal_line_count_matches_original = (
        original_lines is not None and original_lines == chat_journal_lines
    )

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    mock_context_equal = original_mock == chat_mock
    mock_cold_resume_context_ok = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["third_response_input_contains_first_user_text"],
            chat_mock["third_response_input_contains_first_user_text"],
            original_mock["third_response_input_contains_first_final_text"],
            chat_mock["third_response_input_contains_first_final_text"],
            original_mock["third_response_input_contains_patch_call_id"],
            chat_mock["third_response_input_contains_patch_call_id"],
            original_mock["third_response_input_contains_tool_output"],
            chat_mock["third_response_input_contains_tool_output"],
            original_mock["third_response_input_contains_second_user_text"],
            chat_mock["third_response_input_contains_second_user_text"],
        ]
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-freeform-apply-patch-cold-resume-smoke",
        "binary_checks": binary_checks,
        "original_first_freeform_file_change_ok": first_freeform_file_change_turn_ok(
            original_result
        ),
        "chat_backend_first_freeform_file_change_ok": first_freeform_file_change_turn_ok(
            chat_result
        ),
        "workspace_file_contents_equal": (
            original_result["readme_contents"]
            == chat_result["readme_contents"]
            == README_CONTENT
        ),
        "original_resume_exit_ok": "result"
        in original_result["second_process"]["thread_resume_response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_result["second_process"]["thread_resume_response"],
        "original_second_turn_exit_ok": "result"
        in original_result["second_process"]["turn_start_response"]["response"],
        "chat_backend_second_turn_exit_ok": "result"
        in chat_result["second_process"]["turn_start_response"]["response"],
        "original_second_turn_notifications_ok": not original_result["second_process"][
            "turn_start_response"
        ]["notification_errors"],
        "chat_backend_second_turn_notifications_ok": not chat_result["second_process"][
            "turn_start_response"
        ]["notification_errors"],
        "normalized_first_live_sequence_equal": (
            original_result["first_process"]["normalized_live_sequence"]
            == chat_result["first_process"]["normalized_live_sequence"]
        ),
        "normalized_first_read_equal": (
            original_result["normalized_first_read"] == chat_result["normalized_first_read"]
        ),
        "normalized_resume_equal": (
            original_result["normalized_resume"] == chat_result["normalized_resume"]
        ),
        "normalized_post_resume_read_equal": (
            original_result["normalized_post_resume_read"]
            == chat_result["normalized_post_resume_read"]
        ),
        "normalized_final_read_equal": (
            original_result["normalized_final_read"] == chat_result["normalized_final_read"]
        ),
        "normalized_final_list_equal": (
            original_result["normalized_final_list"] == chat_result["normalized_final_list"]
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"] == chat_mock["response_request_count"] == 3
        ),
        "mock_context_equal": mock_context_equal,
        "mock_cold_resume_context_ok": mock_cold_resume_context_ok,
        "chat_package_resume_ok": (
            len(chat_package.get("packages") or []) == 1
            and (chat_timeline_lines or 0) >= 4
            and (chat_journal_lines or 0) >= 4
        ),
        "chat_package_freeform_file_change_ok": chat_package_freeform_file_change_ok(
            chat_result["chat_timeline_summary"]
        ),
        "journal_line_count_matches_original": journal_line_count_matches_original,
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_first_live_sequence": original_result["first_process"][
            "normalized_live_sequence"
        ],
        "chat_backend_normalized_first_live_sequence": chat_result["first_process"][
            "normalized_live_sequence"
        ],
        "original_normalized_resume": original_result["normalized_resume"],
        "chat_backend_normalized_resume": chat_result["normalized_resume"],
        "original_normalized_post_resume_read": original_result[
            "normalized_post_resume_read"
        ],
        "chat_backend_normalized_post_resume_read": chat_result[
            "normalized_post_resume_read"
        ],
        "original_normalized_final_read": original_result["normalized_final_read"],
        "chat_backend_normalized_final_read": chat_result["normalized_final_read"],
        "original_normalized_final_list": original_result["normalized_final_list"],
        "chat_backend_normalized_final_list": chat_result["normalized_final_list"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "chat_timeline_summary": chat_result["chat_timeline_summary"],
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observations"],
            "chat-backend": chat_result["thread_read_path_observations"],
        },
        "original_storage_summary": original_storage,
        "chat_package_summary": chat_package,
        "not_yet_proven": [
            "freeform apply_patch pending resume",
            "complete file-change data fidelity report",
        ],
        "all_scenarios_ok": False,
    }
    summary["all_scenarios_ok"] = all(
        [
            summary["original_first_freeform_file_change_ok"],
            summary["chat_backend_first_freeform_file_change_ok"],
            summary["workspace_file_contents_equal"],
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_second_turn_exit_ok"],
            summary["chat_backend_second_turn_exit_ok"],
            summary["original_second_turn_notifications_ok"],
            summary["chat_backend_second_turn_notifications_ok"],
            summary["normalized_first_live_sequence_equal"],
            summary["normalized_first_read_equal"],
            summary["normalized_resume_equal"],
            summary["normalized_post_resume_read_equal"],
            summary["normalized_final_read_equal"],
            summary["normalized_final_list_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_context_equal"],
            summary["mock_cold_resume_context_ok"],
            summary["chat_package_resume_ok"],
            summary["chat_package_freeform_file_change_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )

    write_json(
        output_dir / "original/freeform-apply-patch-cold-resume-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/freeform-apply-patch-cold-resume-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Freeform Apply Patch Cold Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with `approval_policy = "untrusted"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant Codex freeform apply_patch / cold-resume source and smoke files were
read.

## Scope

This smoke covers direct freeform `apply_patch` transport, completed
file-change approval, process shutdown, a fresh app-server process,
`thread/resume`, `thread/read includeTurns=true`, a follow-up `turn/start`, and
final `thread/read` / `thread/list`.

It is different from the shell heredoc apply_patch path. The model advertises
`apply_patch_tool_type = "freeform"` and emits a Responses `custom_tool_call`
named `apply_patch`, not a `shell_command` heredoc.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/freeform-apply-patch-cold-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/freeform-apply-patch-cold-resume-response.json
```

## Not Yet Proven

This smoke does not prove freeform apply_patch pending resume or complete
file-change data fidelity.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
