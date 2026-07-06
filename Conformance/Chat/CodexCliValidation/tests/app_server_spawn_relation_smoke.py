#!/usr/bin/env python3
"""Run positive spawned-child relation-filter parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend.

It covers a narrow L02 positive relation-filter slice:

- a parent thread spawns child A through `multi_agent_v1.spawn_agent`;
- child A spawns a grandchild through the same real tool path;
- the parent later spawns child B in a second turn;
- `thread/list parentThreadId=<parent>` returns both direct children;
- direct-child relation pagination with `limit=1` returns both pages;
- `thread/list ancestorThreadId=<parent>` returns children plus grandchild.

This does not prove descendant archive/delete ordering, cold history, search
pagination, crash recovery, complete data fidelity, or final
user-indistinguishability.
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
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_pagination_relation_smoke import (  # noqa: E402
    cursor_from_list,
    send_thread_list,
    thread_ids_from_list,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_start,
)


PARENT_TURN_1_PROMPT = "Spawn relation validation parent turn 1."
PARENT_TURN_2_PROMPT = "Spawn relation validation parent turn 2."
CHILD_A_PROMPT = "Inspect spawned child A."
CHILD_B_PROMPT = "Inspect spawned child B."
GRANDCHILD_PROMPT = "Inspect spawned grandchild."
PARENT_TURN_1_FINAL = "Spawn relation parent turn 1 complete."
PARENT_TURN_2_FINAL = "Spawn relation parent turn 2 complete."
CHILD_A_FINAL = "Spawn relation child A complete."
CHILD_B_FINAL = "Spawn relation child B complete."
GRANDCHILD_FINAL = "Spawn relation grandchild complete."

SPAWN_A_CALL_ID = "call-spawn-child-a"
SPAWN_B_CALL_ID = "call-spawn-child-b"
SPAWN_GRANDCHILD_CALL_ID = "call-spawn-grandchild"
MULTI_AGENT_V1_NAMESPACE = "multi_agent_v1"


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


def ev_spawn_agent_call(response_id: str, call_id: str, prompt: str) -> bytes:
    arguments = json.dumps({"message": prompt}, separators=(",", ":"))
    return sse(
        [
            ev_response_created(response_id),
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "call_id": call_id,
                    "namespace": MULTI_AGENT_V1_NAMESPACE,
                    "name": "spawn_agent",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def wait_for_next_unix_second() -> None:
    current_second = int(time.time())
    deadline = time.time() + 3
    while int(time.time()) <= current_second and time.time() < deadline:
        time.sleep(0.02)
    time.sleep(0.05)


class SpawnRelationResponsesServer:
    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "SpawnRelationResponsesServer":
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
        if PARENT_TURN_2_PROMPT in body_text:
            if SPAWN_B_CALL_ID in body_text:
                return ev_assistant_message(
                    "resp-parent-2-b",
                    "msg-parent-2-b",
                    PARENT_TURN_2_FINAL,
                )
            return ev_spawn_agent_call("resp-parent-2-a", SPAWN_B_CALL_ID, CHILD_B_PROMPT)
        if SPAWN_GRANDCHILD_CALL_ID in body_text:
            return ev_assistant_message("resp-child-a-2", "msg-child-a-2", CHILD_A_FINAL)
        if SPAWN_A_CALL_ID in body_text:
            return ev_assistant_message(
                "resp-parent-1-b",
                "msg-parent-1-b",
                PARENT_TURN_1_FINAL,
            )
        if PARENT_TURN_1_PROMPT in body_text:
            return ev_spawn_agent_call("resp-parent-1-a", SPAWN_A_CALL_ID, CHILD_A_PROMPT)
        if CHILD_A_PROMPT in body_text:
            wait_for_next_unix_second()
            return ev_spawn_agent_call(
                "resp-child-a-1",
                SPAWN_GRANDCHILD_CALL_ID,
                GRANDCHILD_PROMPT,
            )
        if GRANDCHILD_PROMPT in body_text:
            return ev_assistant_message(
                "resp-grandchild-1",
                "msg-grandchild-1",
                GRANDCHILD_FINAL,
            )
        if CHILD_B_PROMPT in body_text:
            return ev_assistant_message("resp-child-b-1", "msg-child-b-1", CHILD_B_FINAL)
        return ev_assistant_message("resp-fallback", "msg-fallback", "fallback response")

    def summary(self) -> dict[str, Any]:
        bodies = self.response_request_bodies()
        return {
            "request_count": len(self.requests),
            "response_request_count": len(bodies),
            "contains_parent_turn_1": any(PARENT_TURN_1_PROMPT in body for body in bodies),
            "contains_parent_turn_2": any(PARENT_TURN_2_PROMPT in body for body in bodies),
            "contains_child_a": any(CHILD_A_PROMPT in body for body in bodies),
            "contains_child_b": any(CHILD_B_PROMPT in body for body in bodies),
            "contains_grandchild": any(GRANDCHILD_PROMPT in body for body in bodies),
            "contains_spawn_a_output": any(SPAWN_A_CALL_ID in body for body in bodies),
            "contains_spawn_b_output": any(SPAWN_B_CALL_ID in body for body in bodies),
            "contains_spawn_grandchild_output": any(
                SPAWN_GRANDCHILD_CALL_ID in body for body in bodies
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
                server: SpawnRelationResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def write_spawn_mock_config(codex_home: pathlib.Path, server_url: str) -> None:
    write_mock_config(codex_home, server_url)
    with (codex_home / "config.toml").open("a") as handle:
        handle.write(
            """

[agents]
max_depth = 3
max_threads = 6
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
                "input": [
                    {
                        "type": "text",
                        "text": text,
                        "textElements": [],
                    }
                ],
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def receive_thread_turn_completed(
    client: JsonRpcClient,
    thread_id: str | None,
    timeout_seconds: int = 120,
) -> dict[str, Any]:
    return client.receive_until(
        lambda message: message.get("method") == "turn/completed"
        and (message.get("params") or {}).get("threadId") == thread_id,
        timeout_seconds,
        f"turn/completed for {thread_id}",
    )


def label_for_thread(thread: dict[str, Any], parent_thread_id: str | None) -> str:
    thread_id = thread.get("id")
    preview = thread.get("preview") or thread.get("name") or ""
    if thread_id == parent_thread_id:
        return "parent"
    if CHILD_A_PROMPT in preview:
        return "child-a"
    if CHILD_B_PROMPT in preview:
        return "child-b"
    if GRANDCHILD_PROMPT in preview:
        return "grandchild"
    return "unknown"


def normalize_relation_response(
    response: dict[str, Any],
    parent_thread_id: str | None,
) -> dict[str, Any]:
    result = response.get("result") or {}
    data = result.get("data") or []
    return {
        "has_error": "error" in response,
        "count": len(data),
        "labels": [label_for_thread(thread, parent_thread_id) for thread in data],
        "parent_labels": [
            "parent"
            if thread.get("parentThreadId") == parent_thread_id
            else label_for_parent_id(thread.get("parentThreadId"), response, parent_thread_id)
            for thread in data
        ],
        "parent_thread_ids_present": [
            thread.get("parentThreadId") is not None for thread in data
        ],
        "next_cursor_present": result.get("nextCursor") is not None,
        "next_cursor_has_thread_id_tiebreaker": isinstance(result.get("nextCursor"), str)
        and "|" in result.get("nextCursor", ""),
        "backwards_cursor_present": result.get("backwardsCursor") is not None,
    }


def label_for_parent_id(
    parent_id: str | None,
    response: dict[str, Any],
    root_parent_id: str | None,
) -> str | None:
    if parent_id is None:
        return None
    if parent_id == root_parent_id:
        return "parent"
    data = (response.get("result") or {}).get("data") or []
    for thread in data:
        if thread.get("id") == parent_id:
            return label_for_thread(thread, root_parent_id)
    return "other"


def normalize_all_threads(
    response: dict[str, Any],
    parent_thread_id: str | None,
) -> dict[str, Any]:
    data = (response.get("result") or {}).get("data") or []
    return {
        "count": len(data),
        "labels": [label_for_thread(thread, parent_thread_id) for thread in data],
        "parent_edges": sorted(
            [
                [
                    label_for_thread(thread, parent_thread_id),
                    "parent"
                    if thread.get("parentThreadId") == parent_thread_id
                    else label_for_parent_id(thread.get("parentThreadId"), response, parent_thread_id),
                ]
                for thread in data
                if thread.get("parentThreadId") is not None
            ]
        ),
    }


def relation_edges(normalized_relation: dict[str, Any]) -> list[list[str | None]]:
    return [
        [label, parent_label]
        for label, parent_label in zip(
            normalized_relation["labels"],
            normalized_relation["parent_labels"],
            strict=False,
        )
    ]


def wait_for_relation_counts(
    client: JsonRpcClient,
    request_id_base: int,
    parent_thread_id: str | None,
    *,
    direct_count: int,
    descendant_count: int,
    timeout_seconds: int = 60,
) -> tuple[dict[str, Any], dict[str, Any]]:
    deadline = time.time() + timeout_seconds
    attempt = 0
    last_direct: dict[str, Any] | None = None
    last_descendants: dict[str, Any] | None = None
    while time.time() < deadline:
        attempt += 1
        last_direct = send_thread_list(
            client,
            request_id_base + attempt * 2,
            limit=10,
            parent_thread_id=parent_thread_id,
        )
        last_descendants = send_thread_list(
            client,
            request_id_base + attempt * 2 + 1,
            limit=10,
            ancestor_thread_id=parent_thread_id,
        )
        if (
            len((last_direct.get("result") or {}).get("data") or []) == direct_count
            and len((last_descendants.get("result") or {}).get("data") or [])
            == descendant_count
        ):
            return last_direct, last_descendants
        time.sleep(0.25)
    raise TimeoutError(
        "timed out waiting for relation counts; "
        f"last_direct={last_direct}; last_descendants={last_descendants}"
    )


def wait_for_relation_labels(
    client: JsonRpcClient,
    request_id_base: int,
    parent_thread_id: str | None,
    *,
    expected_direct_labels: list[str],
    expected_descendant_labels: list[str],
    timeout_seconds: int = 60,
) -> tuple[dict[str, Any], dict[str, Any]]:
    deadline = time.time() + timeout_seconds
    attempt = 0
    last_direct: dict[str, Any] | None = None
    last_descendants: dict[str, Any] | None = None
    while time.time() < deadline:
        attempt += 1
        last_direct = send_thread_list(
            client,
            request_id_base + attempt * 2,
            limit=10,
            parent_thread_id=parent_thread_id,
        )
        last_descendants = send_thread_list(
            client,
            request_id_base + attempt * 2 + 1,
            limit=10,
            ancestor_thread_id=parent_thread_id,
        )
        normalized_direct = normalize_relation_response(last_direct, parent_thread_id)
        normalized_descendants = normalize_relation_response(
            last_descendants,
            parent_thread_id,
        )
        if (
            normalized_direct["labels"] == expected_direct_labels
            and normalized_descendants["labels"] == expected_descendant_labels
        ):
            return last_direct, last_descendants
        time.sleep(0.25)
    raise TimeoutError(
        "timed out waiting for relation labels; "
        f"last_direct={last_direct}; last_descendants={last_descendants}"
    )


def summarize_chat_relation_storage(chat_root: pathlib.Path) -> dict[str, Any]:
    base = summarize_chat_packages(chat_root)
    relation_packages = []
    for package in sorted(chat_root.glob("*.chat")):
        manifest_path = package / "manifest.json"
        index_path = package / "indexes/thread-metadata.json"
        timeline_path = package / "timeline.ndjson"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        index = json.loads(index_path.read_text()) if index_path.exists() else {}
        timeline_events = read_json_lines(timeline_path)
        relation_packages.append(
            {
                "package": package.name,
                "manifest_parent_thread_id": (
                    (manifest.get("create_params") or {}).get("parent_thread_id")
                ),
                "index_parent_thread_id": index.get("parent_thread_id"),
                "timeline_event_types": [event.get("type") for event in timeline_events],
            }
        )
    base["relation_packages"] = relation_packages
    return base


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

    with SpawnRelationResponsesServer() as mock_server:
        write_spawn_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            parent_thread_id, thread_start_response = send_thread_start(client, 10, workspace)

            turn_1_response = send_turn_start_with_text(
                client,
                20,
                parent_thread_id,
                PARENT_TURN_1_PROMPT,
            )
            parent_turn_1_completed = receive_thread_turn_completed(client, parent_thread_id)
            direct_after_turn_1, descendants_after_turn_1 = wait_for_relation_counts(
                client,
                100,
                parent_thread_id,
                direct_count=1,
                descendant_count=2,
            )

            wait_for_next_unix_second()
            turn_2_response = send_turn_start_with_text(
                client,
                30,
                parent_thread_id,
                PARENT_TURN_2_PROMPT,
            )
            parent_turn_2_completed = receive_thread_turn_completed(client, parent_thread_id)
            wait_for_relation_counts(
                client,
                200,
                parent_thread_id,
                direct_count=2,
                descendant_count=3,
            )
            direct_full, descendants_full = wait_for_relation_labels(
                client,
                240,
                parent_thread_id,
                expected_direct_labels=["child-b", "child-a"],
                expected_descendant_labels=["child-b", "grandchild", "child-a"],
            )

            direct_page_1 = send_thread_list(
                client,
                300,
                limit=1,
                parent_thread_id=parent_thread_id,
            )
            direct_page_1_cursor = cursor_from_list(direct_page_1)
            direct_page_2 = send_thread_list(
                client,
                301,
                limit=1,
                cursor=direct_page_1_cursor,
                parent_thread_id=parent_thread_id,
            )
            descendants_page_1 = send_thread_list(
                client,
                302,
                limit=2,
                ancestor_thread_id=parent_thread_id,
            )
            descendants_page_1_cursor = cursor_from_list(descendants_page_1)
            descendants_page_2 = send_thread_list(
                client,
                303,
                limit=2,
                cursor=descendants_page_1_cursor,
                ancestor_thread_id=parent_thread_id,
            )
            all_threads = send_thread_list(client, 304, limit=10)

            storage_summary = (
                summarize_chat_relation_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            server_summary = mock_server.summary()
        finally:
            stderr = client.close()

    result = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "parent_thread_id": parent_thread_id,
        "turn_1_response": turn_1_response,
        "turn_2_response": turn_2_response,
        "parent_turn_1_completed": parent_turn_1_completed,
        "parent_turn_2_completed": parent_turn_2_completed,
        "direct_after_turn_1": direct_after_turn_1,
        "descendants_after_turn_1": descendants_after_turn_1,
        "direct_full": direct_full,
        "descendants_full": descendants_full,
        "direct_pages": [direct_page_1, direct_page_2],
        "descendants_pages": [descendants_page_1, descendants_page_2],
        "all_threads": all_threads,
        "normalized_direct_after_turn_1": normalize_relation_response(
            direct_after_turn_1,
            parent_thread_id,
        ),
        "normalized_descendants_after_turn_1": normalize_relation_response(
            descendants_after_turn_1,
            parent_thread_id,
        ),
        "normalized_direct_full": normalize_relation_response(direct_full, parent_thread_id),
        "normalized_descendants_full": normalize_relation_response(
            descendants_full,
            parent_thread_id,
        ),
        "normalized_direct_pages": [
            normalize_relation_response(direct_page_1, parent_thread_id),
            normalize_relation_response(direct_page_2, parent_thread_id),
        ],
        "normalized_descendants_pages": [
            normalize_relation_response(descendants_page_1, parent_thread_id),
            normalize_relation_response(descendants_page_2, parent_thread_id),
        ],
        "normalized_all_threads": normalize_all_threads(all_threads, parent_thread_id),
        "direct_thread_ids": thread_ids_from_list(direct_full),
        "descendant_thread_ids": thread_ids_from_list(descendants_full),
        "mock_server_summary": server_summary,
        "storage_summary": storage_summary,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    return result


def relation_storage_parent_ids_ok(chat_result: dict[str, Any]) -> bool:
    packages = chat_result["storage_summary"].get("relation_packages") or []
    parent_id_count = 0
    for package in packages:
        manifest_parent = package.get("manifest_parent_thread_id")
        index_parent = package.get("index_parent_thread_id")
        if manifest_parent is not None or index_parent is not None:
            parent_id_count += 1
        if manifest_parent != index_parent:
            return False
    return parent_id_count >= 3


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-spawn-relation-smoke-"
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

    original_direct_full = original_result["normalized_direct_full"]
    chat_direct_full = chat_result["normalized_direct_full"]
    original_descendants_full = original_result["normalized_descendants_full"]
    chat_descendants_full = chat_result["normalized_descendants_full"]
    original_direct_pages = original_result["normalized_direct_pages"]
    chat_direct_pages = chat_result["normalized_direct_pages"]
    original_descendant_pages = original_result["normalized_descendants_pages"]
    chat_descendant_pages = chat_result["normalized_descendants_pages"]

    expected_direct_labels = ["child-b", "child-a"]
    expected_descendant_labels = ["child-b", "grandchild", "child-a"]
    expected_direct_pages = [["child-b"], ["child-a"]]
    expected_descendant_pages = [["child-b", "grandchild"], ["child-a"]]
    expected_parent_edges = [
        ["child-b", "parent"],
        ["grandchild", "child-a"],
        ["child-a", "parent"],
    ]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-spawn-relation-smoke",
        "binary_checks": binary_checks,
        "original_direct_labels_match_expected": original_direct_full["labels"]
        == expected_direct_labels,
        "chat_backend_direct_labels_match_expected": chat_direct_full["labels"]
        == expected_direct_labels,
        "direct_labels_equal": original_direct_full["labels"] == chat_direct_full["labels"],
        "original_descendant_labels_match_expected": original_descendants_full["labels"]
        == expected_descendant_labels,
        "chat_backend_descendant_labels_match_expected": chat_descendants_full["labels"]
        == expected_descendant_labels,
        "descendant_labels_equal": original_descendants_full["labels"]
        == chat_descendants_full["labels"],
        "direct_page_labels_equal": [page["labels"] for page in original_direct_pages]
        == [page["labels"] for page in chat_direct_pages],
        "direct_page_labels_match_expected": [page["labels"] for page in original_direct_pages]
        == expected_direct_pages
        and [page["labels"] for page in chat_direct_pages] == expected_direct_pages,
        "descendant_page_labels_equal": [
            page["labels"] for page in original_descendant_pages
        ]
        == [page["labels"] for page in chat_descendant_pages],
        "descendant_page_labels_match_expected": [
            page["labels"] for page in original_descendant_pages
        ]
        == expected_descendant_pages
        and [page["labels"] for page in chat_descendant_pages]
        == expected_descendant_pages,
        "relation_cursors_have_thread_id_tiebreaker": all(
            page["next_cursor_has_thread_id_tiebreaker"]
            for page in [
                original_direct_pages[0],
                chat_direct_pages[0],
                original_descendant_pages[0],
                chat_descendant_pages[0],
            ]
        ),
        "final_relation_pages_have_no_next_cursor": all(
            page["next_cursor_present"] is False
            for page in [
                original_direct_pages[1],
                chat_direct_pages[1],
                original_descendant_pages[1],
                chat_descendant_pages[1],
            ]
        ),
        "descendant_parent_edges_equal": relation_edges(original_descendants_full)
        == relation_edges(chat_descendants_full),
        "descendant_parent_edges_match_expected": relation_edges(original_descendants_full)
        == expected_parent_edges
        and relation_edges(chat_descendants_full) == expected_parent_edges,
        "mock_requests_cover_spawn_flow": all(
            original_result["mock_server_summary"].get(key)
            and chat_result["mock_server_summary"].get(key)
            for key in [
                "contains_parent_turn_1",
                "contains_parent_turn_2",
                "contains_child_a",
                "contains_child_b",
                "contains_grandchild",
                "contains_spawn_a_output",
                "contains_spawn_b_output",
                "contains_spawn_grandchild_output",
            ]
        ),
        "chat_storage_parent_ids_preserved": relation_storage_parent_ids_ok(chat_result),
        "original": {
            "normalized_direct_after_turn_1": original_result[
                "normalized_direct_after_turn_1"
            ],
            "normalized_descendants_after_turn_1": original_result[
                "normalized_descendants_after_turn_1"
            ],
            "normalized_direct_full": original_direct_full,
            "normalized_descendants_full": original_descendants_full,
            "normalized_direct_pages": original_direct_pages,
            "normalized_descendants_pages": original_descendant_pages,
            "normalized_all_threads": original_result["normalized_all_threads"],
            "mock_server_summary": original_result["mock_server_summary"],
        },
        "chat_backend": {
            "normalized_direct_after_turn_1": chat_result[
                "normalized_direct_after_turn_1"
            ],
            "normalized_descendants_after_turn_1": chat_result[
                "normalized_descendants_after_turn_1"
            ],
            "normalized_direct_full": chat_direct_full,
            "normalized_descendants_full": chat_descendants_full,
            "normalized_direct_pages": chat_direct_pages,
            "normalized_descendants_pages": chat_descendant_pages,
            "normalized_all_threads": chat_result["normalized_all_threads"],
            "mock_server_summary": chat_result["mock_server_summary"],
            "relation_storage_parent_ids_preserved": relation_storage_parent_ids_ok(
                chat_result
            ),
        },
        "not_yet_proven": [
            "relation-filter archive/delete descendant lifecycle ordering",
            "search pagination cursor parity",
            "cold history parity",
            "crash recovery",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/spawn-relation-response.json", original_result)
    write_json(output_dir / "chat-backend/spawn-relation-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Spawn Relation Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers a positive L02 relation-filter slice:

```text
parent turn 1 -> multi_agent_v1.spawn_agent(child A)
child A -> multi_agent_v1.spawn_agent(grandchild)
parent turn 2 -> multi_agent_v1.spawn_agent(child B)
thread/list parentThreadId=<parent>
thread/list parentThreadId=<parent> limit=1 pagination
thread/list ancestorThreadId=<parent>
thread/list ancestorThreadId=<parent> limit=2 pagination
```

## Result

- direct labels equal: `{summary['direct_labels_equal']}`
- original direct labels match expected: `{summary['original_direct_labels_match_expected']}`
- `.chat` direct labels match expected: `{summary['chat_backend_direct_labels_match_expected']}`
- descendant labels equal: `{summary['descendant_labels_equal']}`
- original descendant labels match expected: `{summary['original_descendant_labels_match_expected']}`
- `.chat` descendant labels match expected: `{summary['chat_backend_descendant_labels_match_expected']}`
- direct page labels equal: `{summary['direct_page_labels_equal']}`
- direct page labels match expected: `{summary['direct_page_labels_match_expected']}`
- descendant page labels equal: `{summary['descendant_page_labels_equal']}`
- descendant page labels match expected: `{summary['descendant_page_labels_match_expected']}`
- relation cursors carry thread-id tie breaker: `{summary['relation_cursors_have_thread_id_tiebreaker']}`
- final relation pages have no next cursor: `{summary['final_relation_pages_have_no_next_cursor']}`
- descendant parent edges equal: `{summary['descendant_parent_edges_equal']}`
- descendant parent edges match expected: `{summary['descendant_parent_edges_match_expected']}`
- mock requests cover real spawn flow: `{summary['mock_requests_cover_spawn_flow']}`
- `.chat` storage parent ids preserved: `{summary['chat_storage_parent_ids_preserved']}`

## Original Normalized Fields

```json
{json.dumps(summary['original'], indent=2, sort_keys=True)}
```

## `.chat` Backend Normalized Fields

```json
{json.dumps(summary['chat_backend'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/spawn-relation-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/spawn-relation-response.json
```

## Not Yet Proven

This smoke does not prove descendant archive/delete lifecycle ordering, search
pagination cursor parity, cold history, crash recovery, complete data fidelity,
or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_direct_labels_match_expected"],
            summary["chat_backend_direct_labels_match_expected"],
            summary["direct_labels_equal"],
            summary["original_descendant_labels_match_expected"],
            summary["chat_backend_descendant_labels_match_expected"],
            summary["descendant_labels_equal"],
            summary["direct_page_labels_equal"],
            summary["direct_page_labels_match_expected"],
            summary["descendant_page_labels_equal"],
            summary["descendant_page_labels_match_expected"],
            summary["relation_cursors_have_thread_id_tiebreaker"],
            summary["final_relation_pages_have_no_next_cursor"],
            summary["descendant_parent_edges_equal"],
            summary["descendant_parent_edges_match_expected"],
            summary["mock_requests_cover_spawn_flow"],
            summary["chat_storage_parent_ids_preserved"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
