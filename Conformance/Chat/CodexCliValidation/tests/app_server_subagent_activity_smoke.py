#!/usr/bin/env python3
"""Run focused MultiAgentV2 subagent persistence parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend.

It covers a narrow data-fidelity slice:

- a parent turn calls MultiAgentV2 `spawn_agent`;
- the spawned child receives a persisted agent-message communication task;
- a later parent turn calls MultiAgentV2 `send_message`;
- original rollout and `.chat` journal retain matching `SubAgentActivity`
  facts, communication metadata, and agent-message communication facts;
- `.chat` timeline exposes neutral mappings for the retained facts.

This does not prove interrupted subagent activity, wait/followup variants,
detached review-mode variants, top-level `InterAgentCommunication` parity,
complete inter-agent replay parity, or final user-indistinguishability.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import pathlib
import sys
import threading
import time
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    read_json_lines,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_pagination_relation_smoke import (  # noqa: E402
    send_thread_list,
    thread_ids_from_list,
)
from app_server_spawn_relation_smoke import (  # noqa: E402
    receive_thread_turn_completed,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_start,
)


ROOT_SPAWN_PROMPT = "Subagent activity validation spawn turn."
ROOT_SEND_PROMPT = "Subagent activity validation send-message turn."
CHILD_BOOT_PROMPT = "Subagent activity child boot prompt."
QUEUED_MESSAGE = "Subagent activity queued note."
ROOT_SPAWN_FINAL = "Subagent activity spawn turn complete."
ROOT_SEND_FINAL = "Subagent activity send-message turn complete."
CHILD_FINAL = "Subagent activity child complete."
SPAWN_CALL_ID = "call-subagent-activity-spawn"
SEND_CALL_ID = "call-subagent-activity-send"
TASK_NAME = "worker"
AGENT_PATH = f"/root/{TASK_NAME}"
MULTI_AGENT_V2_NAMESPACE = "agents"


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


def ev_assistant_message(response_id: str, message_id: str, text: str) -> bytes:
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


def ev_function_call(
    response_id: str,
    call_id: str,
    name: str,
    arguments: dict[str, Any],
) -> bytes:
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": call_id,
                    "namespace": MULTI_AGENT_V2_NAMESPACE,
                    "name": name,
                    "arguments": json.dumps(arguments, separators=(",", ":")),
                },
            },
            ev_completed(response_id),
        ]
    )


class SubagentActivityResponsesServer:
    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "SubagentActivityResponsesServer":
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

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

    def response_request_bodies(self) -> list[str]:
        with self._lock:
            requests = list(self.requests)
        return [
            json.dumps(request["json"], ensure_ascii=False)
            for request in requests
            if request["path"].endswith("/responses")
        ]

    def response_for_body(self, body_text: str) -> bytes:
        if ROOT_SEND_PROMPT in body_text:
            if SEND_CALL_ID in body_text:
                return ev_assistant_message(
                    "resp-root-send-final",
                    "msg-root-send-final",
                    ROOT_SEND_FINAL,
                )
            return ev_function_call(
                "resp-root-send-call",
                SEND_CALL_ID,
                "send_message",
                {"target": TASK_NAME, "message": QUEUED_MESSAGE},
            )
        if ROOT_SPAWN_PROMPT in body_text:
            if SPAWN_CALL_ID in body_text:
                return ev_assistant_message(
                    "resp-root-spawn-final",
                    "msg-root-spawn-final",
                    ROOT_SPAWN_FINAL,
                )
            return ev_function_call(
                "resp-root-spawn-call",
                SPAWN_CALL_ID,
                "spawn_agent",
                {
                    "message": CHILD_BOOT_PROMPT,
                    "task_name": TASK_NAME,
                    "fork_turns": "none",
                },
            )
        if CHILD_BOOT_PROMPT in body_text:
            return ev_assistant_message(
                "resp-child-final",
                "msg-child-final",
                CHILD_FINAL,
            )
        return ev_assistant_message("resp-fallback", "msg-fallback", "fallback response")

    def summary(self) -> dict[str, Any]:
        bodies = self.response_request_bodies()
        return {
            "request_count": len(self.requests),
            "response_request_count": len(bodies),
            "contains_root_spawn_prompt": any(ROOT_SPAWN_PROMPT in body for body in bodies),
            "contains_root_send_prompt": any(ROOT_SEND_PROMPT in body for body in bodies),
            "contains_child_boot_prompt": any(CHILD_BOOT_PROMPT in body for body in bodies),
            "contains_spawn_tool_output": any(SPAWN_CALL_ID in body for body in bodies),
            "contains_send_tool_output": any(SEND_CALL_ID in body for body in bodies),
            "contains_v2_tool_namespace": any(
                MULTI_AGENT_V2_NAMESPACE in body for body in bodies
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
                body_text = json.dumps(body_json, ensure_ascii=False)
                server: SubagentActivityResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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
                body = server.response_for_body(body_text)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        return Handler


def write_multi_agent_v2_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write(
            f"""

[features.multi_agent_v2]
enabled = true
max_concurrent_threads_per_session = 4
min_wait_timeout_ms = 0
max_wait_timeout_ms = 30000
default_wait_timeout_ms = 50
root_agent_usage_hint_text = ""
subagent_usage_hint_text = ""
tool_namespace = "{MULTI_AGENT_V2_NAMESPACE}"
hide_spawn_agent_metadata = true
non_code_mode_only = false
"""
        )


def send_turn_start_with_text(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
    text: str,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "clientUserMessageId": f"client-user-message-{request_id}",
                "input": [{"type": "text", "text": text, "textElements": []}],
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_read(
    client: JsonRpcClient,
    request_id: int,
    thread_id: str | None,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/read",
            "params": {"threadId": thread_id, "includeTurns": True},
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def normalize_subagent_items(response: dict[str, Any]) -> list[dict[str, Any]]:
    thread = (response.get("result") or {}).get("thread") or {}
    normalized = []
    for turn in thread.get("turns") or []:
        for item in turn.get("items") or []:
            if item.get("type") == "subAgentActivity":
                normalized.append(
                    {
                        "kind": item.get("kind"),
                        "agent_thread_id_present": item.get("agentThreadId") is not None,
                        "agent_path": item.get("agentPath"),
                    }
                )
    return normalized


def normalize_thread_read_visibility(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    serialized = json.dumps(thread.get("turns") or [], ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(thread.get("turns") or []),
        "contains_root_spawn_prompt": ROOT_SPAWN_PROMPT in serialized,
        "contains_root_send_prompt": ROOT_SEND_PROMPT in serialized,
        "contains_child_boot_prompt": CHILD_BOOT_PROMPT in serialized,
        "contains_root_spawn_final": ROOT_SPAWN_FINAL in serialized,
        "contains_root_send_final": ROOT_SEND_FINAL in serialized,
        "contains_child_final": CHILD_FINAL in serialized,
        "subagent_items": normalize_subagent_items(response),
    }


def rollout_item_payload_from_original_line(line: dict[str, Any]) -> dict[str, Any]:
    return {"type": line.get("type"), "payload": line.get("payload")}


def rollout_item_payload_from_chat_journal_line(line: dict[str, Any]) -> dict[str, Any]:
    return ((line.get("source_transport") or {}).get("payload") or {})


def collect_facts_from_payloads(payloads: list[dict[str, Any]]) -> dict[str, Any]:
    subagent_activities = []
    inter_agent_communications = []
    inter_agent_metadata = []
    agent_messages = []
    type_counts: dict[str, int] = {}
    for payload in payloads:
        source_type = payload.get("type")
        if not isinstance(source_type, str):
            continue
        type_counts[source_type] = type_counts.get(source_type, 0) + 1
        source_payload = payload.get("payload") or {}
        if source_type == "event_msg" and source_payload.get("type") == "sub_agent_activity":
            activity = source_payload
            subagent_activities.append(
                {
                    "event_id": activity.get("event_id"),
                    "kind": activity.get("kind"),
                    "agent_thread_id_present": activity.get("agent_thread_id") is not None,
                    "agent_path": activity.get("agent_path"),
                }
            )
        elif source_type == "inter_agent_communication":
            communication = source_payload
            inter_agent_communications.append(
                {
                    "author": communication.get("author"),
                    "recipient": communication.get("recipient"),
                    "other_recipient_count": len(communication.get("other_recipients") or []),
                    "content": communication.get("content"),
                    "encrypted_content": communication.get("encrypted_content"),
                    "trigger_turn": communication.get("trigger_turn"),
                }
            )
        elif source_type == "inter_agent_communication_metadata":
            inter_agent_metadata.append({"trigger_turn": source_payload.get("trigger_turn")})
        elif source_type == "response_item" and source_payload.get("type") == "agent_message":
            content = source_payload.get("content") or []
            agent_messages.append(
                {
                    "author": source_payload.get("author"),
                    "recipient": source_payload.get("recipient"),
                    "text": "\n".join(
                        item.get("text") or ""
                        for item in content
                        if item.get("type") in {"input_text", "output_text"}
                    ),
                    "encrypted_content": "\n".join(
                        item.get("encrypted_content") or ""
                        for item in content
                        if item.get("type") == "encrypted_content"
                    ),
                }
            )
    return {
        "type_counts": type_counts,
        "subagent_activities": sorted(
            subagent_activities,
            key=lambda item: (item.get("event_id") or "", item.get("kind") or ""),
        ),
        "inter_agent_communications": sorted(
            inter_agent_communications,
            key=lambda item: (
                item.get("author") or "",
                item.get("recipient") or "",
                item.get("encrypted_content") or "",
            ),
        ),
        "inter_agent_metadata": sorted(
            inter_agent_metadata,
            key=lambda item: str(item.get("trigger_turn")),
        ),
        "agent_messages": sorted(
            agent_messages,
            key=lambda item: (
                item.get("author") or "",
                item.get("recipient") or "",
                item.get("text") or "",
                item.get("encrypted_content") or "",
            ),
        ),
    }


def child_thread_id_from_original_storage(codex_home: pathlib.Path) -> str | None:
    for rollout in sorted(codex_home.rglob("*.jsonl")):
        if "/sessions/" not in rollout.as_posix():
            continue
        for line in read_json_lines(rollout):
            if line.get("type") != "event_msg":
                continue
            payload = line.get("payload") or {}
            if (
                payload.get("type") == "sub_agent_activity"
                and payload.get("event_id") == SPAWN_CALL_ID
                and payload.get("kind") == "started"
            ):
                child_thread_id = payload.get("agent_thread_id")
                if isinstance(child_thread_id, str):
                    return child_thread_id
    return None


def child_thread_id_from_chat_storage(chat_root: pathlib.Path) -> str | None:
    for package in sorted(chat_root.glob("*.chat")):
        for line in read_json_lines(package / "journal.ndjson"):
            source_transport = line.get("source_transport") or {}
            payload = (source_transport.get("payload") or {}).get("payload") or {}
            if (
                payload.get("type") == "sub_agent_activity"
                and payload.get("event_id") == SPAWN_CALL_ID
                and payload.get("kind") == "started"
            ):
                child_thread_id = payload.get("agent_thread_id")
                if isinstance(child_thread_id, str):
                    return child_thread_id
    return None


def wait_for_child_thread_id(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    *,
    timeout_seconds: int = 30,
) -> str:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if tree_name == "chat-backend":
            child_thread_id = child_thread_id_from_chat_storage(chat_root)
        else:
            child_thread_id = child_thread_id_from_original_storage(codex_home)
        if child_thread_id is not None:
            return child_thread_id
        time.sleep(0.1)
    raise TimeoutError(f"timed out waiting for spawned child thread id in {tree_name}")


def summarize_original_subagent_storage(codex_home: pathlib.Path) -> dict[str, Any]:
    rollouts = []
    payloads = []
    for rollout in sorted(codex_home.rglob("*.jsonl")):
        lines = read_json_lines(rollout)
        rollouts.append(
            {
                "path": rollout.relative_to(codex_home).as_posix(),
                "line_count": len(lines),
            }
        )
        payloads.extend(rollout_item_payload_from_original_line(line) for line in lines)
    facts = collect_facts_from_payloads(payloads)
    facts["rollouts"] = rollouts
    facts["total_line_count"] = sum(rollout["line_count"] for rollout in rollouts)
    return facts


def summarize_chat_subagent_storage(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    payloads = []
    subagent_timeline_mappings = []
    inter_agent_timeline_mappings = []
    metadata_timeline_mappings = []
    for package in sorted(chat_root.glob("*.chat")):
        journal_lines = read_json_lines(package / "journal.ndjson")
        timeline_lines = read_json_lines(package / "timeline.ndjson")
        timeline_by_id: dict[str, dict[str, Any]] = {}
        packages.append(
            {
                "package": package.name,
                "journal_line_count": len(journal_lines),
                "timeline_line_count": len(timeline_lines),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
            }
        )
        for line in timeline_lines:
            event_id = line.get("id")
            if isinstance(event_id, str):
                timeline_by_id[event_id] = line
        for line in journal_lines:
            payload = rollout_item_payload_from_chat_journal_line(line)
            payloads.append(payload)
            event_id = line.get("event_id")
            source_type = payload.get("type")
            source_payload = payload.get("payload") or {}
            if source_type == "event_msg" and source_payload.get("type") == "sub_agent_activity":
                subagent_timeline_mappings.append(
                    timeline_by_id.get(event_id, {}).get("type")
                )
            elif source_type == "inter_agent_communication":
                inter_agent_timeline_mappings.append(
                    timeline_by_id.get(event_id, {}).get("type")
                )
            elif source_type == "inter_agent_communication_metadata":
                metadata_timeline_mappings.append(
                    timeline_by_id.get(event_id, {}).get("type")
                )
    facts = collect_facts_from_payloads(payloads)
    facts["packages"] = packages
    facts["total_journal_line_count"] = sum(
        package["journal_line_count"] for package in packages
    )
    facts["total_timeline_line_count"] = sum(
        package["timeline_line_count"] for package in packages
    )
    facts["subagent_activity_timeline_mappings"] = sorted(
        subagent_timeline_mappings
    )
    facts["inter_agent_timeline_mappings"] = sorted(
        inter_agent_timeline_mappings
    )
    facts["inter_agent_metadata_timeline_mappings"] = sorted(
        metadata_timeline_mappings
    )
    return facts


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

    with SubagentActivityResponsesServer() as mock_server:
        write_multi_agent_v2_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            parent_thread_id, thread_start_response = send_thread_start(client, 10, workspace)

            spawn_turn_response = send_turn_start_with_text(
                client,
                20,
                parent_thread_id,
                ROOT_SPAWN_PROMPT,
            )
            parent_spawn_completed = receive_thread_turn_completed(client, parent_thread_id)
            child_thread_id = wait_for_child_thread_id(
                tree_name,
                codex_home,
                chat_root,
            )

            send_turn_response = send_turn_start_with_text(
                client,
                30,
                parent_thread_id,
                ROOT_SEND_PROMPT,
            )
            parent_send_completed = receive_thread_turn_completed(client, parent_thread_id)

            parent_read = send_thread_read(client, 40, parent_thread_id)
            child_read = send_thread_read(client, 41, child_thread_id)
            final_direct_children = send_thread_list(
                client,
                42,
                limit=10,
                parent_thread_id=parent_thread_id,
            )

            server_summary = mock_server.summary()
        finally:
            stderr = client.close()

    if tree_name == "chat-backend":
        storage_summary = summarize_chat_subagent_storage(chat_root)
    else:
        storage_summary = summarize_original_subagent_storage(codex_home)

    return {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "parent_thread_id": parent_thread_id,
        "child_thread_id": child_thread_id,
        "spawn_turn_response": spawn_turn_response,
        "send_turn_response": send_turn_response,
        "parent_spawn_completed": parent_spawn_completed,
        "parent_send_completed": parent_send_completed,
        "parent_read": parent_read,
        "child_read": child_read,
        "final_direct_children": final_direct_children,
        "normalized_parent_read": normalize_thread_read_visibility(parent_read),
        "normalized_child_read": normalize_thread_read_visibility(child_read),
        "normalized_direct_child_ids_present": [
            child_id is not None for child_id in thread_ids_from_list(final_direct_children)
        ],
        "mock_server_summary": server_summary,
        "storage_summary": storage_summary,
        "fallback_storage_summary": None
        if tree_name == "chat-backend"
        else summarize_original_storage(codex_home),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-subagent-activity-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)
    (output_dir / "original").mkdir()
    (output_dir / "chat-backend").mkdir()

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

    original_storage = original_result["storage_summary"]
    chat_storage = chat_result["storage_summary"]
    expected_subagent_activities = [
        {
            "event_id": SEND_CALL_ID,
            "kind": "interacted",
            "agent_thread_id_present": True,
            "agent_path": AGENT_PATH,
        },
        {
            "event_id": SPAWN_CALL_ID,
            "kind": "started",
            "agent_thread_id_present": True,
            "agent_path": AGENT_PATH,
        },
    ]
    expected_inter_agent_metadata = [
        {"trigger_turn": False},
        {"trigger_turn": True},
    ]
    expected_child_boot_agent_message = {
        "author": "/root",
        "recipient": AGENT_PATH,
        "encrypted_content": CHILD_BOOT_PROMPT,
    }
    expected_child_final_agent_message = {
        "author": AGENT_PATH,
        "recipient": "/root",
        "encrypted_content": "",
    }

    def contains_agent_message(
        messages: list[dict[str, Any]],
        expected: dict[str, Any],
        text_fragment: str,
    ) -> bool:
        return any(
            message.get("author") == expected["author"]
            and message.get("recipient") == expected["recipient"]
            and message.get("encrypted_content") == expected["encrypted_content"]
            and text_fragment in (message.get("text") or "")
            for message in messages
        )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-subagent-activity-smoke",
        "binary_checks": binary_checks,
        "mock_requests_cover_v2_flow": all(
            original_result["mock_server_summary"].get(key)
            and chat_result["mock_server_summary"].get(key)
            for key in [
                "contains_root_spawn_prompt",
                "contains_root_send_prompt",
                "contains_child_boot_prompt",
                "contains_spawn_tool_output",
                "contains_send_tool_output",
            ]
        ),
        "parent_read_normalized_equal": (
            original_result["normalized_parent_read"]
            == chat_result["normalized_parent_read"]
        ),
        "child_read_normalized_equal": (
            original_result["normalized_child_read"] == chat_result["normalized_child_read"]
        ),
        "direct_child_id_presence_equal": (
            original_result["normalized_direct_child_ids_present"]
            == chat_result["normalized_direct_child_ids_present"]
        ),
        "original_subagent_activities_match_expected": (
            original_storage["subagent_activities"] == expected_subagent_activities
        ),
        "chat_backend_subagent_activities_match_expected": (
            chat_storage["subagent_activities"] == expected_subagent_activities
        ),
        "subagent_activities_equal": (
            original_storage["subagent_activities"] == chat_storage["subagent_activities"]
        ),
        "top_level_inter_agent_communications_equal": (
            original_storage["inter_agent_communications"]
            == chat_storage["inter_agent_communications"]
        ),
        "top_level_inter_agent_communication_absent_in_this_flow": (
            not original_storage["inter_agent_communications"]
            and not chat_storage["inter_agent_communications"]
        ),
        "original_inter_agent_metadata_match_expected": (
            original_storage["inter_agent_metadata"] == expected_inter_agent_metadata
        ),
        "chat_backend_inter_agent_metadata_match_expected": (
            chat_storage["inter_agent_metadata"] == expected_inter_agent_metadata
        ),
        "inter_agent_metadata_equal": (
            original_storage["inter_agent_metadata"] == chat_storage["inter_agent_metadata"]
        ),
        "agent_messages_equal": (
            original_storage["agent_messages"] == chat_storage["agent_messages"]
        ),
        "original_child_boot_agent_message_present": contains_agent_message(
            original_storage["agent_messages"],
            expected_child_boot_agent_message,
            "Message Type: NEW_TASK",
        ),
        "chat_backend_child_boot_agent_message_present": contains_agent_message(
            chat_storage["agent_messages"],
            expected_child_boot_agent_message,
            "Message Type: NEW_TASK",
        ),
        "original_child_final_agent_message_present": contains_agent_message(
            original_storage["agent_messages"],
            expected_child_final_agent_message,
            CHILD_FINAL,
        ),
        "chat_backend_child_final_agent_message_present": contains_agent_message(
            chat_storage["agent_messages"],
            expected_child_final_agent_message,
            CHILD_FINAL,
        ),
        "aggregate_line_counts_equal": (
            original_storage["total_line_count"] == chat_storage["total_journal_line_count"]
        ),
        "chat_subagent_timeline_mapped_to_status_changed": (
            chat_storage["subagent_activity_timeline_mappings"]
            == ["status_changed", "status_changed"]
        ),
        "chat_inter_agent_timeline_mapped_to_runtime_event": (
            chat_storage["inter_agent_timeline_mappings"] == []
        ),
        "chat_inter_agent_metadata_timeline_mapped_to_runtime_event": (
            chat_storage["inter_agent_metadata_timeline_mappings"]
            == ["runtime_event", "runtime_event"]
        ),
        "original": {
            "normalized_parent_read": original_result["normalized_parent_read"],
            "normalized_child_read": original_result["normalized_child_read"],
            "mock_server_summary": original_result["mock_server_summary"],
            "storage_summary": original_storage,
        },
        "chat_backend": {
            "normalized_parent_read": chat_result["normalized_parent_read"],
            "normalized_child_read": chat_result["normalized_child_read"],
            "mock_server_summary": chat_result["mock_server_summary"],
            "storage_summary": chat_storage,
        },
        "not_yet_proven": [
            "SubAgentActivity Interrupted variants",
            "top-level InterAgentCommunication parity",
            "wait_agent and followup_task variants",
            "detached/interrupted review-mode variants",
            "complete inter-agent replay parity",
            "semantic promotion beyond status_changed/runtime_event mappings",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/subagent-activity-response.json", original_result)
    write_json(output_dir / "chat-backend/subagent-activity-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Subagent Activity Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers a focused MultiAgentV2 data-fidelity slice:

```text
parent turn -> agents.spawn_agent(worker)
worker receives InterAgentCommunication initial task
parent turn -> agents.send_message(worker)
thread/read parent and child
rollout/journal/timeline storage inspection
```

## Result

- mock requests cover v2 flow: `{summary['mock_requests_cover_v2_flow']}`
- parent read normalized equal: `{summary['parent_read_normalized_equal']}`
- child read normalized equal: `{summary['child_read_normalized_equal']}`
- direct child id presence equal: `{summary['direct_child_id_presence_equal']}`
- original subagent activities match expected: `{summary['original_subagent_activities_match_expected']}`
- `.chat` subagent activities match expected: `{summary['chat_backend_subagent_activities_match_expected']}`
- subagent activities equal: `{summary['subagent_activities_equal']}`
- top-level inter-agent communications equal: `{summary['top_level_inter_agent_communications_equal']}`
- top-level inter-agent communication absent in this flow: `{summary['top_level_inter_agent_communication_absent_in_this_flow']}`
- original inter-agent metadata match expected: `{summary['original_inter_agent_metadata_match_expected']}`
- `.chat` inter-agent metadata match expected: `{summary['chat_backend_inter_agent_metadata_match_expected']}`
- inter-agent metadata equal: `{summary['inter_agent_metadata_equal']}`
- agent messages equal: `{summary['agent_messages_equal']}`
- original child boot agent message present: `{summary['original_child_boot_agent_message_present']}`
- `.chat` child boot agent message present: `{summary['chat_backend_child_boot_agent_message_present']}`
- original child final agent message present: `{summary['original_child_final_agent_message_present']}`
- `.chat` child final agent message present: `{summary['chat_backend_child_final_agent_message_present']}`
- aggregate original rollout vs `.chat` journal line counts equal: `{summary['aggregate_line_counts_equal']}`
- `.chat` subagent timeline maps to status_changed: `{summary['chat_subagent_timeline_mapped_to_status_changed']}`
- `.chat` top-level inter-agent timeline has no events in this flow: `{summary['chat_inter_agent_timeline_mapped_to_runtime_event']}`
- `.chat` inter-agent metadata timeline maps to runtime_event: `{summary['chat_inter_agent_metadata_timeline_mapped_to_runtime_event']}`

## Original Storage Facts

```json
{json.dumps(summary['original']['storage_summary'], indent=2, sort_keys=True)}
```

## `.chat` Storage Facts

```json
{json.dumps(summary['chat_backend']['storage_summary'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/subagent-activity-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/subagent-activity-response.json
```

## Not Yet Proven

This smoke does not prove interrupted subagent activity, top-level
InterAgentCommunication parity, wait/followup variants, detached/interrupted
review-mode variants, complete inter-agent replay parity, semantic promotion
beyond current neutral timeline mappings, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["mock_requests_cover_v2_flow"],
            summary["parent_read_normalized_equal"],
            summary["child_read_normalized_equal"],
            summary["original_subagent_activities_match_expected"],
            summary["chat_backend_subagent_activities_match_expected"],
            summary["subagent_activities_equal"],
            summary["top_level_inter_agent_communications_equal"],
            summary["top_level_inter_agent_communication_absent_in_this_flow"],
            summary["original_inter_agent_metadata_match_expected"],
            summary["chat_backend_inter_agent_metadata_match_expected"],
            summary["inter_agent_metadata_equal"],
            summary["agent_messages_equal"],
            summary["original_child_boot_agent_message_present"],
            summary["chat_backend_child_boot_agent_message_present"],
            summary["original_child_final_agent_message_present"],
            summary["chat_backend_child_final_agent_message_present"],
            summary["aggregate_line_counts_equal"],
            summary["chat_subagent_timeline_mapped_to_status_changed"],
            summary["chat_inter_agent_timeline_mapped_to_runtime_event"],
            summary["chat_inter_agent_metadata_timeline_mapped_to_runtime_event"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
