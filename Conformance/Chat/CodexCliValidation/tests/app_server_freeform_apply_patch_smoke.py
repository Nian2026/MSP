#!/usr/bin/env python3
"""Run freeform apply_patch parity smoke for Codex `.chat` backend."""

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
from app_server_file_change_approval_smoke import ADD_README_PATCH
from app_server_file_change_approval_smoke import normalize_file_change_item
from app_server_file_change_approval_smoke import normalize_file_change_request
from app_server_file_change_approval_smoke import receive_file_change_completed
from app_server_file_change_approval_smoke import receive_file_change_started


USER_TEXT = "Apply the freeform apply_patch parity smoke patch."
FINAL_TEXT = "Freeform apply_patch parity smoke complete."
PATCH_CALL_ID = "freeform-patch-call"
README_CONTENT = "new line\n"


def freeform_model_info() -> dict[str, Any]:
    return {
        "slug": "mock-model",
        "display_name": "mock-model",
        "description": "Mock model with freeform apply_patch enabled.",
        "default_reasoning_level": "medium",
        "supported_reasoning_levels": [
            {"effort": "low", "description": "low"},
            {"effort": "medium", "description": "medium"},
        ],
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": 0,
        "additional_speed_tiers": [],
        "service_tiers": [],
        "default_service_tier": None,
        "availability_nux": None,
        "upgrade": None,
        "base_instructions": "base instructions",
        "model_messages": None,
        "include_skills_usage_instructions": False,
        "supports_reasoning_summaries": False,
        "default_reasoning_summary": "auto",
        "support_verbosity": False,
        "default_verbosity": None,
        "apply_patch_tool_type": "freeform",
        "web_search_tool_type": "text",
        "truncation_policy": {"mode": "bytes", "limit": 10000},
        "supports_parallel_tool_calls": False,
        "supports_image_detail_original": False,
        "context_window": 272000,
        "max_context_window": 272000,
        "auto_compact_token_limit": None,
        "comp_hash": None,
        "effective_context_window_percent": 95,
        "experimental_supported_tools": [],
        "input_modalities": ["text"],
        "supports_search_tool": False,
        "use_responses_lite": False,
        "auto_review_model_override": None,
        "tool_mode": None,
        "multi_agent_version": None,
    }


def ev_apply_patch_custom_tool_call(response_id: str, call_id: str, patch_text: str) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "custom_tool_call",
                    "call_id": call_id,
                    "name": "apply_patch",
                    "input": patch_text,
                },
            },
            ev_completed(response_id),
        ]
    )


class FreeformApplyPatchResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_apply_patch_custom_tool_call(
                "resp-freeform-apply-patch",
                PATCH_CALL_ID,
                ADD_README_PATCH,
            ),
            ev_final_message(
                "resp-freeform-apply-patch-final",
                "msg-freeform-apply-patch-final",
                FINAL_TEXT,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "FreeformApplyPatchResponsesServer":
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
                "resp-freeform-extra",
                "msg-freeform-extra",
                "extra freeform apply_patch response",
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
            "function_output_call_ids": [
                PATCH_CALL_ID
                for body in serialized_bodies
                if PATCH_CALL_ID in body
                and (
                    "custom_tool_call_output" in body
                    or "function_call_output" in body
                )
            ],
            "contains_patch_output": any("Patch applied" in body for body in serialized_bodies),
            "final_texts_seen": [
                FINAL_TEXT for body in serialized_bodies if FINAL_TEXT in body
            ],
        }

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
                server: FreeformApplyPatchResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def write_freeform_models_cache(codex_home: pathlib.Path) -> None:
    cache = {
        "fetched_at": utc_now_iso(),
        "etag": None,
        "client_version": "0.0.0",
        "models": [freeform_model_info()],
    }
    write_json(codex_home / "models_cache.json", cache)


def normalize_thread_read_visible(response: dict[str, Any]) -> dict[str, Any]:
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
        "contains_final_text": FINAL_TEXT in serialized,
        "contains_file_change_item": "fileChange" in serialized,
        "contains_completed_file_change": (
            "fileChange" in serialized and "completed" in serialized
        ),
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


def summarize_freeform_chat_timeline(chat_root: pathlib.Path) -> dict[str, Any]:
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
                "journal_line_count": len(journal_lines),
                "journal_custom_apply_patch_call_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "custom_tool_call"
                    and payload.get("name") == "apply_patch"
                ),
                "journal_custom_tool_call_output_count": sum(
                    1
                    for payload in journal_payloads
                    if payload.get("type") == "custom_tool_call_output"
                ),
                "journal_has_patch_call_id": any(
                    PATCH_CALL_ID in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
                "journal_has_patch_text": any(
                    "*** Begin Patch" in json.dumps(payload, ensure_ascii=False)
                    for payload in journal_payloads
                ),
            }
        )
    return {"package_count": len(packages), "packages": packages}


def summarize_freeform_original_rollouts(codex_home: pathlib.Path) -> dict[str, Any]:
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
                "response_item_types": [
                    ((item.get("payload") or {}).get("type"))
                    for item in lines
                    if item.get("type") == "response_item"
                ],
                "custom_tool_call_names": [
                    ((item.get("payload") or {}).get("name"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type") == "custom_tool_call"
                ],
                "custom_tool_call_output_call_ids": [
                    ((item.get("payload") or {}).get("call_id"))
                    for item in lines
                    if item.get("type") == "response_item"
                    and (item.get("payload") or {}).get("type")
                    == "custom_tool_call_output"
                ],
                "contains_patch_call_id": PATCH_CALL_ID
                in json.dumps(lines, ensure_ascii=False),
                "contains_patch_text": "*** Begin Patch"
                in json.dumps(lines, ensure_ascii=False),
            }
        )
    return {"rollout_count": len(rollouts), "rollouts": rollouts}


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    tree_root = run_root / tree_name
    workspace = tree_root / "workspace"
    codex_home = tree_root / "codex-home"
    chat_root = tree_root / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    readme_path = workspace / "README.md"

    with FreeformApplyPatchResponsesServer() as mock_server:
        write_approval_config(codex_home, mock_server.url)
        write_freeform_models_cache(codex_home)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        turn_start_response: dict[str, Any] = {}
        file_change_started: dict[str, Any] = {}
        file_change_request: dict[str, Any] = {}
        file_change_completed: dict[str, Any] = {}
        turn_completed: dict[str, Any] = {}
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
            thread_id = ((thread_start_response.get("result") or {}).get("thread") or {}).get("id")

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "turn/start",
                    "params": {
                        "threadId": thread_id,
                        "clientUserMessageId": "client-user-freeform-apply-patch",
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
            expected = {"thread_id": thread_id, "turn_id": turn_id}

            file_change_started = receive_file_change_started(client, PATCH_CALL_ID)
            file_change_request = client.receive_until(
                lambda message: message.get("method") == "item/fileChange/requestApproval"
                and (message.get("params") or {}).get("itemId") == PATCH_CALL_ID,
                timeout_seconds=30,
                description="freeform fileChange requestApproval",
            )
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": file_change_request.get("id"),
                    "result": {"decision": "accept"},
                }
            )
            file_change_completed = receive_file_change_completed(client, PATCH_CALL_ID)
            turn_completed = client.receive_until_method("turn/completed", timeout_seconds=90)

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "thread/read",
                    "params": {
                        "threadId": thread_id,
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
        "turn_completed": turn_completed,
        "thread_read_response": thread_read_response,
        "normalized_thread_read_visible": normalize_thread_read_visible(
            thread_read_response,
        ),
        "normalized_live_sequence": normalized_live_sequence(client.received),
        "readme_contents": readme_path.read_text() if readme_path.exists() else None,
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
        result["original_rollout_summary"] = summarize_freeform_original_rollouts(codex_home)
    return result


def tree_ok(result: dict[str, Any]) -> bool:
    started = result["normalized_file_change_started"]
    request = result["normalized_file_change_request"]
    completed = result["normalized_file_change_completed"]
    visible = result["normalized_thread_read_visible"]
    mock = result["mock_server_summary"]
    if "result" not in result["turn_start_response"]:
        return False
    if result["readme_contents"] != README_CONTENT:
        return False
    if started["id"] != PATCH_CALL_ID or not started["has_readme_path"]:
        return False
    if request is None or not request["thread_id_matches"] or not request["turn_id_matches"]:
        return False
    if not request["item_id_matches"]:
        return False
    if completed["id"] != PATCH_CALL_ID or completed["status"] != "completed":
        return False
    if not visible["contains_final_text"] or not visible["contains_completed_file_change"]:
        return False
    if mock["response_request_count"] != 2:
        return False
    if PATCH_CALL_ID not in mock["function_output_call_ids"]:
        return False
    if result["tree"] == "chat-backend":
        packages = result["chat_timeline_summary"]["packages"]
        return any(
            package["timeline_tool_call_count"] >= 1
            and package["timeline_tool_output_count"] >= 1
            and package["timeline_command_call_count"] == 0
            and package["timeline_command_output_count"] == 0
            and package["journal_custom_apply_patch_call_count"] >= 1
            and package["journal_custom_tool_call_output_count"] >= 1
            and package["journal_has_patch_call_id"]
            and package["journal_has_patch_text"]
            for package in packages
        )
    rollouts = result["original_rollout_summary"]["rollouts"]
    return any(
        "apply_patch" in rollout["custom_tool_call_names"]
        and PATCH_CALL_ID in rollout["custom_tool_call_output_call_ids"]
        and rollout["contains_patch_call_id"]
        and rollout["contains_patch_text"]
        for rollout in rollouts
    )


def compare_results(original: dict[str, Any], chat_backend: dict[str, Any]) -> dict[str, Any]:
    original_ok = tree_ok(original)
    chat_backend_ok = tree_ok(chat_backend)
    return {
        "original_ok": original_ok,
        "chat_backend_ok": chat_backend_ok,
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat_backend["normalized_live_sequence"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"]
            == chat_backend["normalized_thread_read_visible"]
        ),
        "normalized_file_change_request_equal": (
            original["normalized_file_change_request"]
            == chat_backend["normalized_file_change_request"]
        ),
        "mock_response_request_counts_equal": (
            original["mock_server_summary"]["response_request_count"]
            == chat_backend["mock_server_summary"]["response_request_count"]
            == 2
        ),
        "workspace_file_contents_equal": (
            original["readme_contents"] == chat_backend["readme_contents"] == README_CONTENT
        ),
        "chat_backend_timeline_classification_ok": chat_backend_ok,
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
        / (
            "app-server-freeform-apply-patch-smoke-"
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
    original = run_tree("original", ORIGINAL_CODEX_RS, run_root, config_overrides=[])
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat_backend = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )
    comparison = compare_results(original, chat_backend)
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-freeform-apply-patch-smoke",
        "binary_checks": binary_checks,
        "comparison": comparison,
        "all_scenarios_ok": all(
            [
                comparison["original_ok"],
                comparison["chat_backend_ok"],
                comparison["normalized_live_sequence_equal"],
                comparison["normalized_thread_read_visible_equal"],
                comparison["normalized_file_change_request_equal"],
                comparison["mock_response_request_counts_equal"],
                comparison["workspace_file_contents_equal"],
                comparison["chat_backend_timeline_classification_ok"],
            ]
        ),
        "not_yet_proven": [
            "freeform apply_patch pending resume",
            "freeform apply_patch cold resume",
            "complete file-change data fidelity report",
        ],
    }

    write_json(output_dir / "original" / "freeform-apply-patch-response.json", original)
    write_json(
        output_dir / "chat-backend" / "freeform-apply-patch-response.json",
        chat_backend,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Freeform Apply Patch Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API. The mock model advertises `apply_patch_tool_type = "freeform"`
and emits a Responses `custom_tool_call` named `apply_patch`, not a
`shell_command` heredoc.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current progress report, and
relevant Codex freeform apply_patch source files were read.

## Scope

This smoke verifies the T06/file-change slice for direct freeform
`apply_patch` transport:

- both backends expose the freeform patch as an app-server `fileChange` item;
- both backends emit the same file-change approval request shape;
- accepting the request writes the same workspace file contents;
- `thread/read includeTurns=true` exposes the same user-visible thread shape;
- the `.chat` backend maps canonical timeline entries to `tool_call` and
  `tool_output`, not `command_call` / `command_output`;
- `journal.ndjson` retains the original `custom_tool_call` and
  `custom_tool_call_output` source transport.

## Result

```json
{json.dumps(summary, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/freeform-apply-patch-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/freeform-apply-patch-response.json
```

## Not Yet Proven

This smoke does not prove freeform apply_patch pending resume, freeform
apply_patch cold resume, or complete file-change data fidelity.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
