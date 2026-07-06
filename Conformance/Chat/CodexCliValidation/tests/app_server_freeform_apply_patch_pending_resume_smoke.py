#!/usr/bin/env python3
"""Run freeform apply_patch pending-resume parity smoke for Codex `.chat` backend."""

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
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json
from app_server_file_change_approval_smoke import ADD_README_PATCH
from app_server_file_change_approval_smoke import normalize_file_change_item
from app_server_file_change_approval_smoke import normalize_file_change_request
from app_server_file_change_approval_smoke import receive_file_change_completed
from app_server_file_change_approval_smoke import receive_file_change_started
from app_server_file_change_pending_resume_smoke import receive_file_change_request
from app_server_file_change_pending_resume_smoke import send_initialize
from app_server_file_change_pending_resume_smoke import send_thread_list
from app_server_file_change_pending_resume_smoke import send_thread_read
from app_server_file_change_pending_resume_smoke import send_thread_resume
from app_server_file_change_pending_resume_smoke import send_thread_start
from app_server_file_change_pending_resume_smoke import send_turn_start
from app_server_file_change_pending_resume_smoke import summarize_path_observation
from app_server_file_change_pending_resume_smoke import storage_line_count
from app_server_freeform_apply_patch_smoke import PATCH_CALL_ID
from app_server_freeform_apply_patch_smoke import README_CONTENT
from app_server_freeform_apply_patch_smoke import ev_apply_patch_custom_tool_call
from app_server_freeform_apply_patch_smoke import freeform_model_info
from app_server_freeform_apply_patch_smoke import summarize_freeform_chat_timeline
from app_server_freeform_apply_patch_smoke import summarize_freeform_original_rollouts
from app_server_freeform_apply_patch_smoke import write_freeform_models_cache


SEED_USER_TEXT = "Seed history before freeform apply_patch pending resume."
SEED_ASSISTANT_TEXT = "Seed history persisted before freeform apply_patch pending resume."
PATCH_USER_TEXT = "Apply freeform apply_patch and keep approval pending during resume."
PATCH_FINAL_TEXT = "Freeform apply_patch pending resume completed."


class FreeformApplyPatchPendingResumeResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_final_message(
                "resp-freeform-pending-resume-seed",
                "msg-freeform-pending-resume-seed",
                SEED_ASSISTANT_TEXT,
            ),
            ev_apply_patch_custom_tool_call(
                "resp-freeform-pending-resume-patch",
                PATCH_CALL_ID,
                ADD_README_PATCH,
            ),
            ev_final_message(
                "resp-freeform-pending-resume-final",
                "msg-freeform-pending-resume-final",
                PATCH_FINAL_TEXT,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "FreeformApplyPatchPendingResumeResponsesServer":
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
                "resp-freeform-pending-resume-extra",
                "msg-freeform-pending-resume-extra",
                "extra freeform apply_patch pending resume response",
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
                server: FreeformApplyPatchPendingResumeResponsesServer = (
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
        "first_response_input_contains_seed_user_text": response_input_contains(
            first_body,
            SEED_USER_TEXT,
        ),
        "second_response_input_contains_seed_user_text": response_input_contains(
            second_body,
            SEED_USER_TEXT,
        ),
        "second_response_input_contains_seed_assistant_text": response_input_contains(
            second_body,
            SEED_ASSISTANT_TEXT,
        ),
        "second_response_input_contains_patch_user_text": response_input_contains(
            second_body,
            PATCH_USER_TEXT,
        ),
        "third_response_input_contains_seed_user_text": response_input_contains(
            third_body,
            SEED_USER_TEXT,
        ),
        "third_response_input_contains_seed_assistant_text": response_input_contains(
            third_body,
            SEED_ASSISTANT_TEXT,
        ),
        "third_response_input_contains_patch_user_text": response_input_contains(
            third_body,
            PATCH_USER_TEXT,
        ),
        "third_response_input_contains_patch_call_id": response_input_contains(
            third_body,
            PATCH_CALL_ID,
        ),
        "third_response_input_contains_tool_output": response_input_contains(
            third_body,
            "custom_tool_call_output",
        )
        or response_input_contains(third_body, "Patch applied"),
    }


def normalize_pending_resume_response(
    response: dict[str, Any],
    thread_id: str | None,
    running_turn_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    thread = result.get("thread") or {}
    thread_turns = thread.get("turns") or []
    page = result.get("initialTurnsPage") or {}
    page_turns = page.get("data") or []
    all_turns = thread_turns + page_turns
    serialized = json.dumps(all_turns, ensure_ascii=False)
    running_turn = None
    if running_turn_id is not None:
        running_turn = next(
            (turn for turn in all_turns if turn.get("id") == running_turn_id),
            None,
        )
    return {
        "has_error": "error" in response,
        "thread_id_matches": thread_id is not None and thread.get("id") == thread_id,
        "thread_status_type": status_type(thread.get("status")),
        "thread_turn_count": len(thread_turns),
        "initial_turns_page_present": bool(page),
        "initial_turns_page_count": len(page_turns),
        "all_turn_statuses": [status_type(turn.get("status")) for turn in all_turns],
        "all_item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in all_turns
        ],
        "running_turn_present": running_turn is not None,
        "running_turn_status": status_type((running_turn or {}).get("status")),
        "contains_seed_user_text": SEED_USER_TEXT in serialized,
        "contains_seed_assistant_text": SEED_ASSISTANT_TEXT in serialized,
        "contains_patch_user_text": PATCH_USER_TEXT in serialized,
        "contains_file_change_item": "fileChange" in serialized,
        "contains_patch_call_id": PATCH_CALL_ID in serialized,
    }


def normalize_final_thread_read(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "thread_status_type": status_type(thread.get("status")),
        "path_present": thread.get("path") is not None,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "item_count_by_turn": [len(turn.get("items") or []) for turn in turns],
        "item_types_by_turn": [
            [item.get("type") for item in (turn.get("items") or [])]
            for turn in turns
        ],
        "contains_seed_user_text": SEED_USER_TEXT in serialized,
        "contains_seed_assistant_text": SEED_ASSISTANT_TEXT in serialized,
        "contains_patch_user_text": PATCH_USER_TEXT in serialized,
        "contains_patch_final_text": PATCH_FINAL_TEXT in serialized,
        "contains_file_change_item": "fileChange" in serialized,
        "contains_patch_call_id": PATCH_CALL_ID in serialized,
    }


def normalize_thread_list_response(
    response: dict[str, Any],
    thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    threads = result.get("data") or []
    listed = None
    if thread_id is not None:
        listed = next((thread for thread in threads if thread.get("id") == thread_id), None)
    if listed is None and threads:
        listed = threads[0]
    normalized: dict[str, Any] = {
        "has_error": "error" in response,
        "thread_count": len(threads),
        "contains_started_thread": listed is not None
        and thread_id is not None
        and listed.get("id") == thread_id,
        "next_cursor_present": result.get("nextCursor") is not None,
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }
    if listed is not None:
        normalized.update(
            {
                "listed_thread_ephemeral": listed.get("ephemeral"),
                "listed_thread_model_provider": listed.get("modelProvider"),
                "listed_thread_model": listed.get("model"),
                "listed_thread_name": listed.get("name"),
                "listed_thread_preview": listed.get("preview"),
                "listed_thread_source": listed.get("source"),
                "listed_thread_status_type": status_type(listed.get("status")),
                "listed_thread_turn_count": len(listed.get("turns") or []),
            }
        )
    return normalized


def normalized_request_replay(
    original_request: dict[str, Any],
    replayed_request: dict[str, Any],
    expected: dict[str, str | None],
) -> dict[str, Any]:
    return {
        "method_equal": original_request.get("method") == replayed_request.get("method"),
        "id_equal": original_request.get("id") == replayed_request.get("id"),
        "params_equal": (original_request.get("params") or {})
        == (replayed_request.get("params") or {}),
        "normalized_original": normalize_file_change_request(
            original_request,
            expected,  # type: ignore[arg-type]
            PATCH_CALL_ID,
        ),
        "normalized_replayed": normalize_file_change_request(
            replayed_request,
            expected,  # type: ignore[arg-type]
            PATCH_CALL_ID,
        ),
    }


def chat_package_pending_freeform_ok(summary: dict[str, Any]) -> bool:
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


def original_rollout_freeform_ok(summary: dict[str, Any]) -> bool:
    rollouts = summary.get("rollouts") or []
    return any(
        "apply_patch" in rollout["custom_tool_call_names"]
        and PATCH_CALL_ID in rollout["custom_tool_call_output_call_ids"]
        and rollout["contains_patch_call_id"]
        and rollout["contains_patch_text"]
        for rollout in rollouts
    )


def request_replay_ok(result: dict[str, Any]) -> bool:
    replay = result["normalized_request_replay"]
    original = replay["normalized_original"] or {}
    replayed = replay["normalized_replayed"] or {}
    return all(
        [
            replay["method_equal"],
            replay["id_equal"],
            replay["params_equal"],
            original.get("thread_id_matches"),
            original.get("turn_id_matches"),
            original.get("item_id_matches"),
            replayed.get("thread_id_matches"),
            replayed.get("turn_id_matches"),
            replayed.get("item_id_matches"),
        ]
    )


def final_read_ok(result: dict[str, Any]) -> bool:
    final_read = result["normalized_final_read"]
    completed = result["normalized_file_change_completed"]
    return all(
        [
            "result" in result["final_thread_read"],
            final_read["turn_count"] == 2,
            final_read["turn_statuses"] == ["completed", "completed"],
            final_read["contains_seed_user_text"],
            final_read["contains_seed_assistant_text"],
            final_read["contains_patch_user_text"],
            final_read["contains_patch_final_text"],
            final_read["contains_file_change_item"],
            final_read["contains_patch_call_id"],
            completed["id"] == PATCH_CALL_ID,
            completed["status"] == "completed",
            completed["has_readme_path"],
        ]
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

    with FreeformApplyPatchPendingResumeResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        write_freeform_models_cache(codex_home)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)

            seed_turn_id, seed_turn_response = send_turn_start(
                client,
                3,
                thread_id,
                "client-user-freeform-pending-resume-seed",
                SEED_USER_TEXT,
            )
            seed_turn_completed = client.receive_until_method(
                "turn/completed",
                timeout_seconds=60,
            )

            patch_turn_id, patch_turn_response = send_turn_start(
                client,
                4,
                thread_id,
                "client-user-freeform-pending-resume-patch",
                PATCH_USER_TEXT,
            )
            file_change_started = receive_file_change_started(client, PATCH_CALL_ID)
            original_request = receive_file_change_request(client, PATCH_CALL_ID)

            resume_response = send_thread_resume(client, 5, thread_id)
            replayed_request = receive_file_change_request(client, PATCH_CALL_ID)

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": replayed_request.get("id"),
                    "result": {"decision": "accept"},
                }
            )
            file_change_completed = receive_file_change_completed(client, PATCH_CALL_ID)
            turn_completed = client.receive_until(
                lambda message: message.get("method") == "turn/completed",
                timeout_seconds=90,
                description="turn/completed after replayed freeform file-change approval",
            )
            final_thread_read = send_thread_read(client, 6, thread_id)
            final_thread_list = send_thread_list(client, 7)
        finally:
            stderr = client.close()

    expected = {"thread_id": thread_id, "turn_id": patch_turn_id}
    readme_contents = readme_path.read_text() if readme_path.exists() else None
    result: dict[str, Any] = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "readme_contents": readme_contents,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "seed_turn_id": seed_turn_id,
        "seed_turn_response": seed_turn_response,
        "seed_turn_completed": seed_turn_completed,
        "patch_turn_id": patch_turn_id,
        "patch_turn_response": patch_turn_response,
        "file_change_started": file_change_started,
        "normalized_file_change_started": normalize_file_change_item(
            ((file_change_started.get("params") or {}).get("item") or {})
        ),
        "original_file_change_request": original_request,
        "normalized_original_file_change_request": normalize_file_change_request(
            original_request,
            expected,  # type: ignore[arg-type]
            PATCH_CALL_ID,
        ),
        "resume_response": resume_response,
        "normalized_resume": normalize_pending_resume_response(
            resume_response,
            thread_id,
            patch_turn_id,
        ),
        "replayed_file_change_request": replayed_request,
        "normalized_replayed_file_change_request": normalize_file_change_request(
            replayed_request,
            expected,  # type: ignore[arg-type]
            PATCH_CALL_ID,
        ),
        "normalized_request_replay": normalized_request_replay(
            original_request,
            replayed_request,
            expected,
        ),
        "file_change_completed": file_change_completed,
        "normalized_file_change_completed": normalize_file_change_item(
            ((file_change_completed.get("params") or {}).get("item") or {})
        ),
        "turn_completed": turn_completed,
        "final_thread_read": final_thread_read,
        "normalized_final_read": normalize_final_thread_read(final_thread_read),
        "final_thread_list": final_thread_list,
        "normalized_final_list": normalize_thread_list_response(final_thread_list, thread_id),
        "thread_read_path_observation": summarize_path_observation(
            final_thread_read,
            thread_id,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
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
            "app-server-freeform-apply-patch-pending-resume-smoke-"
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
    original_rollout_lines = storage_line_count(original_storage, "rollouts")
    chat_packages = chat_package.get("packages") or []
    chat_journal_lines = (
        chat_packages[0].get("journal_line_count") if len(chat_packages) == 1 else None
    )
    chat_timeline_lines = (
        chat_packages[0].get("timeline_line_count") if len(chat_packages) == 1 else None
    )
    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    mock_context_equal = original_mock == chat_mock
    mock_context_ok = all(
        [
            original_mock["response_request_count"] == 3,
            chat_mock["response_request_count"] == 3,
            original_mock["third_response_input_contains_seed_user_text"],
            chat_mock["third_response_input_contains_seed_user_text"],
            original_mock["third_response_input_contains_seed_assistant_text"],
            chat_mock["third_response_input_contains_seed_assistant_text"],
            original_mock["third_response_input_contains_patch_user_text"],
            chat_mock["third_response_input_contains_patch_user_text"],
            original_mock["third_response_input_contains_patch_call_id"],
            chat_mock["third_response_input_contains_patch_call_id"],
            original_mock["third_response_input_contains_tool_output"],
            chat_mock["third_response_input_contains_tool_output"],
        ]
    )

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-freeform-apply-patch-pending-resume-smoke",
        "binary_checks": binary_checks,
        "original_seed_turn_exit_ok": "result" in original_result["seed_turn_response"],
        "chat_backend_seed_turn_exit_ok": "result" in chat_result["seed_turn_response"],
        "original_patch_turn_exit_ok": "result" in original_result["patch_turn_response"],
        "chat_backend_patch_turn_exit_ok": "result" in chat_result["patch_turn_response"],
        "original_resume_exit_ok": "result" in original_result["resume_response"],
        "chat_backend_resume_exit_ok": "result" in chat_result["resume_response"],
        "original_request_replay_ok": request_replay_ok(original_result),
        "chat_backend_request_replay_ok": request_replay_ok(chat_result),
        "normalized_original_request_equal": (
            original_result["normalized_original_file_change_request"]
            == chat_result["normalized_original_file_change_request"]
        ),
        "normalized_replayed_request_equal": (
            original_result["normalized_replayed_file_change_request"]
            == chat_result["normalized_replayed_file_change_request"]
        ),
        "normalized_resume_equal": (
            original_result["normalized_resume"] == chat_result["normalized_resume"]
        ),
        "original_resume_saw_in_progress_file_change": all(
            [
                original_result["normalized_resume"]["running_turn_present"],
                original_result["normalized_resume"]["running_turn_status"] == "inProgress",
                original_result["normalized_resume"]["contains_file_change_item"],
                original_result["normalized_resume"]["contains_patch_call_id"],
            ]
        ),
        "chat_backend_resume_saw_in_progress_file_change": all(
            [
                chat_result["normalized_resume"]["running_turn_present"],
                chat_result["normalized_resume"]["running_turn_status"] == "inProgress",
                chat_result["normalized_resume"]["contains_file_change_item"],
                chat_result["normalized_resume"]["contains_patch_call_id"],
            ]
        ),
        "original_final_read_ok": final_read_ok(original_result),
        "chat_backend_final_read_ok": final_read_ok(chat_result),
        "normalized_final_read_equal": (
            original_result["normalized_final_read"] == chat_result["normalized_final_read"]
        ),
        "normalized_final_list_equal": (
            original_result["normalized_final_list"] == chat_result["normalized_final_list"]
        ),
        "workspace_file_contents_equal": (
            original_result["readme_contents"]
            == chat_result["readme_contents"]
            == README_CONTENT
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"] == chat_mock["response_request_count"] == 3
        ),
        "mock_context_equal": mock_context_equal,
        "mock_context_ok": mock_context_ok,
        "original_rollout_freeform_ok": original_rollout_freeform_ok(
            original_result["original_rollout_summary"]
        ),
        "chat_package_pending_freeform_ok": chat_package_pending_freeform_ok(
            chat_result["chat_timeline_summary"]
        ),
        "journal_line_count_matches_original": (
            original_rollout_lines is not None and original_rollout_lines == chat_journal_lines
        ),
        "original_rollout_line_count": original_rollout_lines,
        "chat_journal_line_count": chat_journal_lines,
        "chat_timeline_line_count": chat_timeline_lines,
        "original_normalized_resume": original_result["normalized_resume"],
        "chat_backend_normalized_resume": chat_result["normalized_resume"],
        "original_request_replay": original_result["normalized_request_replay"],
        "chat_backend_request_replay": chat_result["normalized_request_replay"],
        "original_normalized_final_read": original_result["normalized_final_read"],
        "chat_backend_normalized_final_read": chat_result["normalized_final_read"],
        "original_normalized_final_list": original_result["normalized_final_list"],
        "chat_backend_normalized_final_list": chat_result["normalized_final_list"],
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observation"],
            "chat-backend": chat_result["thread_read_path_observation"],
        },
        "original_storage_summary": original_storage,
        "original_rollout_summary": original_result["original_rollout_summary"],
        "chat_package_summary": chat_package,
        "chat_timeline_summary": chat_result["chat_timeline_summary"],
        "not_yet_proven": [
            "complete file-change data fidelity report",
        ],
        "all_scenarios_ok": False,
    }
    summary["all_scenarios_ok"] = all(
        [
            summary["original_seed_turn_exit_ok"],
            summary["chat_backend_seed_turn_exit_ok"],
            summary["original_patch_turn_exit_ok"],
            summary["chat_backend_patch_turn_exit_ok"],
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_request_replay_ok"],
            summary["chat_backend_request_replay_ok"],
            summary["normalized_original_request_equal"],
            summary["normalized_replayed_request_equal"],
            summary["normalized_resume_equal"],
            summary["original_resume_saw_in_progress_file_change"],
            summary["chat_backend_resume_saw_in_progress_file_change"],
            summary["original_final_read_ok"],
            summary["chat_backend_final_read_ok"],
            summary["normalized_final_read_equal"],
            summary["normalized_final_list_equal"],
            summary["workspace_file_contents_equal"],
            summary["mock_response_request_counts_equal"],
            summary["mock_context_equal"],
            summary["mock_context_ok"],
            summary["original_rollout_freeform_ok"],
            summary["chat_package_pending_freeform_ok"],
            summary["journal_line_count_matches_original"],
        ]
    )

    write_json(
        output_dir / "original/freeform-apply-patch-pending-resume-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/freeform-apply-patch-pending-resume-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Freeform Apply Patch Pending Resume Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API with `approval_policy = "untrusted"` and
`apply_patch_tool_type = "freeform"`.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report,
existing file-change/freeform smoke tests, and relevant Codex freeform
`apply_patch` source files were read.

## Scope

This smoke covers a running direct freeform `apply_patch` file-change turn whose
approval request is still pending, then calls `thread/resume` in the same
app-server process and verifies that the pending
`item/fileChange/requestApproval` request is replayed. It then accepts the
replayed request and verifies final file-change completion, `thread/read`,
`thread/list`, model context, workspace contents, and `.chat` timeline
classification.

It is different from the shell heredoc apply_patch pending-resume smoke: the
mock model advertises `apply_patch_tool_type = "freeform"` and emits a Responses
`custom_tool_call` named `apply_patch`, not a `shell_command` heredoc.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/freeform-apply-patch-pending-resume-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/freeform-apply-patch-pending-resume-response.json
```

## Not Yet Proven

This smoke does not prove a complete file-change data fidelity report.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
