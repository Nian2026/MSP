#!/usr/bin/env python3
"""Run focused MultiAgentV2 subagent interrupt persistence parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend.

It covers a narrow data-fidelity slice:

- a parent turn calls MultiAgentV2 `spawn_agent`;
- the spawned child starts a long-running model turn;
- a later parent turn calls MultiAgentV2 `interrupt_agent`;
- original rollout and `.chat` journal retain matching `SubAgentActivity`
  `started` and `interrupted` facts;
- direct child relation-list results match the original backend for the
  interrupted child visibility case;
- `.chat` timeline exposes neutral mappings for the retained facts.

This does not prove wait/followup variants, top-level
`InterAgentCommunication` parity, detached/interrupted review-mode variants,
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
)
from app_server_list_pagination_relation_smoke import (  # noqa: E402
    send_thread_list,
    thread_ids_from_list,
)
from app_server_spawn_relation_smoke import (  # noqa: E402
    receive_thread_turn_completed,
)
from app_server_subagent_activity_smoke import (  # noqa: E402
    AGENT_PATH,
    CHILD_BOOT_PROMPT,
    MULTI_AGENT_V2_NAMESPACE,
    ROOT_SPAWN_FINAL,
    ROOT_SPAWN_PROMPT,
    SPAWN_CALL_ID,
    TASK_NAME,
    SubagentActivityResponsesServer,
    collect_facts_from_payloads,
    ev_assistant_message,
    ev_function_call,
    rollout_item_payload_from_chat_journal_line,
    rollout_item_payload_from_original_line,
    wait_for_child_thread_id,
    write_multi_agent_v2_mock_config,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_start,
)


ROOT_INTERRUPT_PROMPT = "Subagent interrupt validation turn."
ROOT_INTERRUPT_FINAL = "Subagent interrupt turn complete."
INTERRUPT_CALL_ID = "call-subagent-activity-interrupt"
CHILD_LONG_FINAL = "Subagent interrupt child should not normally complete."


class SubagentInterruptResponsesServer(SubagentActivityResponsesServer):
    def __init__(self) -> None:
        super().__init__()
        self.child_request_started = threading.Event()
        self.release_child_response = threading.Event()
        self.child_request_released = threading.Event()

    def response_for_body(self, body_text: str) -> bytes:
        if ROOT_INTERRUPT_PROMPT in body_text:
            if INTERRUPT_CALL_ID in body_text:
                return ev_assistant_message(
                    "resp-root-interrupt-final",
                    "msg-root-interrupt-final",
                    ROOT_INTERRUPT_FINAL,
                )
            return ev_function_call(
                "resp-root-interrupt-call",
                INTERRUPT_CALL_ID,
                "interrupt_agent",
                {"target": TASK_NAME},
            )
        if ROOT_SPAWN_PROMPT in body_text:
            return super().response_for_body(body_text)
        if CHILD_BOOT_PROMPT in body_text:
            self.child_request_started.set()
            self.release_child_response.wait(timeout=60)
            self.child_request_released.set()
            return ev_assistant_message(
                "resp-child-long-final",
                "msg-child-long-final",
                CHILD_LONG_FINAL,
            )
        return super().response_for_body(body_text)

    def summary(self) -> dict[str, Any]:
        base = super().summary()
        bodies = self.response_request_bodies()
        base.update(
            {
                "contains_root_interrupt_prompt": any(
                    ROOT_INTERRUPT_PROMPT in body for body in bodies
                ),
                "contains_interrupt_tool_output": any(
                    INTERRUPT_CALL_ID in body for body in bodies
                ),
                "child_request_started": self.child_request_started.is_set(),
                "child_request_released": self.child_request_released.is_set(),
            }
        )
        return base

    def _make_handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        parent_handler = super()._make_handler()

        class Handler(parent_handler):  # type: ignore[misc, valid-type]
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length)
                try:
                    body_json = json.loads(raw_body.decode() or "{}")
                except json.JSONDecodeError:
                    body_json = {"_decode_error": raw_body.decode(errors="replace")}
                body_text = json.dumps(body_json, ensure_ascii=False)
                server: SubagentInterruptResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    return
                finally:
                    self.close_connection = True

        return Handler


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
    return sorted(
        normalized,
        key=lambda item: (item.get("kind") or "", item.get("agent_path") or ""),
    )


def normalize_thread_read_visibility(response: dict[str, Any]) -> dict[str, Any]:
    thread = (response.get("result") or {}).get("thread") or {}
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": sorted(
            str(turn.get("status")) for turn in turns if turn.get("status") is not None
        ),
        "contains_root_spawn_prompt": ROOT_SPAWN_PROMPT in serialized,
        "contains_root_interrupt_prompt": ROOT_INTERRUPT_PROMPT in serialized,
        "contains_child_boot_prompt": CHILD_BOOT_PROMPT in serialized,
        "contains_root_spawn_final": ROOT_SPAWN_FINAL in serialized,
        "contains_root_interrupt_final": ROOT_INTERRUPT_FINAL in serialized,
        "contains_child_long_final": CHILD_LONG_FINAL in serialized,
        "subagent_items": normalize_subagent_items(response),
    }


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

    with SubagentInterruptResponsesServer() as mock_server:
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
            if not mock_server.child_request_started.wait(timeout=30):
                raise TimeoutError("timed out waiting for child model request")

            interrupt_turn_response = send_turn_start_with_text(
                client,
                30,
                parent_thread_id,
                ROOT_INTERRUPT_PROMPT,
            )
            parent_interrupt_completed = receive_thread_turn_completed(
                client, parent_thread_id
            )

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
            mock_server.release_child_response.set()
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
        "interrupt_turn_response": interrupt_turn_response,
        "parent_spawn_completed": parent_spawn_completed,
        "parent_interrupt_completed": parent_interrupt_completed,
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
            "app-server-subagent-interrupt-smoke-"
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
            "event_id": INTERRUPT_CALL_ID,
            "kind": "interrupted",
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
    expected_inter_agent_metadata = [{"trigger_turn": True}]
    expected_child_boot_agent_message = {
        "author": "/root",
        "recipient": AGENT_PATH,
        "encrypted_content": CHILD_BOOT_PROMPT,
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
        "scope": "app-server-subagent-interrupt-smoke",
        "binary_checks": binary_checks,
        "mock_requests_cover_v2_interrupt_flow": all(
            original_result["mock_server_summary"].get(key)
            and chat_result["mock_server_summary"].get(key)
            for key in [
                "contains_root_spawn_prompt",
                "contains_child_boot_prompt",
                "contains_spawn_tool_output",
                "contains_root_interrupt_prompt",
                "contains_interrupt_tool_output",
                "child_request_started",
            ]
        ),
        "parent_read_normalized_equal": (
            original_result["normalized_parent_read"]
            == chat_result["normalized_parent_read"]
        ),
        "child_read_normalized_equal": (
            original_result["normalized_child_read"] == chat_result["normalized_child_read"]
        ),
        "adjacent_direct_child_relation_equal": (
            original_result["normalized_direct_child_ids_present"]
            == chat_result["normalized_direct_child_ids_present"]
        ),
        "adjacent_direct_child_relation_counts": {
            "original": len(original_result["normalized_direct_child_ids_present"]),
            "chat_backend": len(chat_result["normalized_direct_child_ids_present"]),
        },
        "original_subagent_activities_match_expected": (
            original_storage["subagent_activities"] == expected_subagent_activities
        ),
        "chat_backend_subagent_activities_match_expected": (
            chat_storage["subagent_activities"] == expected_subagent_activities
        ),
        "subagent_activities_equal": (
            original_storage["subagent_activities"] == chat_storage["subagent_activities"]
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
        "top_level_inter_agent_communication_absent_in_this_flow": (
            not original_storage["inter_agent_communications"]
            and not chat_storage["inter_agent_communications"]
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
        "aggregate_line_counts_equal": (
            original_storage["total_line_count"] == chat_storage["total_journal_line_count"]
        ),
        "chat_subagent_timeline_mapped_to_status_changed": (
            chat_storage["subagent_activity_timeline_mappings"]
            == ["status_changed", "status_changed"]
        ),
        "chat_inter_agent_metadata_timeline_mapped_to_runtime_event": (
            chat_storage["inter_agent_metadata_timeline_mappings"] == ["runtime_event"]
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
            "top-level InterAgentCommunication parity",
            "wait_agent and followup_task variants",
            "detached/interrupted review-mode variants",
            "complete inter-agent replay parity",
            "semantic promotion beyond status_changed/runtime_event mappings",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/subagent-interrupt-response.json", original_result)
    write_json(output_dir / "chat-backend/subagent-interrupt-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Subagent Interrupt Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Scope

This smoke covers a focused MultiAgentV2 interrupted subagent data-fidelity
slice:

```text
parent turn -> agents.spawn_agent(worker)
worker starts a long-running model turn
parent turn -> agents.interrupt_agent(worker)
thread/read parent and child
rollout/journal/timeline storage inspection
```

## Result

- mock requests cover v2 interrupt flow: `{summary['mock_requests_cover_v2_interrupt_flow']}`
- parent read normalized equal: `{summary['parent_read_normalized_equal']}`
- child read normalized equal: `{summary['child_read_normalized_equal']}`
- original subagent activities match expected: `{summary['original_subagent_activities_match_expected']}`
- `.chat` subagent activities match expected: `{summary['chat_backend_subagent_activities_match_expected']}`
- subagent activities equal: `{summary['subagent_activities_equal']}`
- original inter-agent metadata match expected: `{summary['original_inter_agent_metadata_match_expected']}`
- `.chat` inter-agent metadata match expected: `{summary['chat_backend_inter_agent_metadata_match_expected']}`
- inter-agent metadata equal: `{summary['inter_agent_metadata_equal']}`
- top-level inter-agent communication absent in this flow: `{summary['top_level_inter_agent_communication_absent_in_this_flow']}`
- agent messages equal: `{summary['agent_messages_equal']}`
- original child boot agent message present: `{summary['original_child_boot_agent_message_present']}`
- `.chat` child boot agent message present: `{summary['chat_backend_child_boot_agent_message_present']}`
- aggregate original rollout vs `.chat` journal line counts equal: `{summary['aggregate_line_counts_equal']}`
- `.chat` subagent timeline maps to status_changed: `{summary['chat_subagent_timeline_mapped_to_status_changed']}`
- `.chat` inter-agent metadata timeline maps to runtime_event: `{summary['chat_inter_agent_metadata_timeline_mapped_to_runtime_event']}`
- direct child relation equal: `{summary['adjacent_direct_child_relation_equal']}`
- direct child relation counts: `{json.dumps(summary['adjacent_direct_child_relation_counts'], sort_keys=True)}`

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
{output_dir.relative_to(VALIDATION_DIR)}/original/subagent-interrupt-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/subagent-interrupt-response.json
```

## Not Yet Proven

This smoke does not prove top-level InterAgentCommunication parity,
wait/followup variants, detached/interrupted review-mode variants, complete
inter-agent replay parity, semantic promotion beyond current neutral timeline
mappings, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["mock_requests_cover_v2_interrupt_flow"],
            summary["parent_read_normalized_equal"],
            summary["child_read_normalized_equal"],
            summary["original_subagent_activities_match_expected"],
            summary["chat_backend_subagent_activities_match_expected"],
            summary["subagent_activities_equal"],
            summary["original_inter_agent_metadata_match_expected"],
            summary["chat_backend_inter_agent_metadata_match_expected"],
            summary["inter_agent_metadata_equal"],
            summary["top_level_inter_agent_communication_absent_in_this_flow"],
            summary["agent_messages_equal"],
            summary["original_child_boot_agent_message_present"],
            summary["chat_backend_child_boot_agent_message_present"],
            summary["aggregate_line_counts_equal"],
            summary["chat_subagent_timeline_mapped_to_status_changed"],
            summary["chat_inter_agent_metadata_timeline_mapped_to_runtime_event"],
            summary["adjacent_direct_child_relation_equal"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
