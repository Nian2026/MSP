#!/usr/bin/env python3
"""Run app-server managed-network persistent allow parity smoke.

This source-backed validation covers a narrow Codex app-server slice:

    first turn triggers managed-network approval
    client replies with ApplyNetworkPolicyAmendment { Allow }
    rule is persisted to execpolicy and saved-rule context is recorded
    second same-host turn completes without another network approval request

It compares the unmodified original backend with the adapted `.chat` backend.
This is not a final T06 approval or user-indistinguishability claim.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import http.server
import json
import os
import pathlib
import threading
from typing import Any

from app_server_durable_turn_smoke import (
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    VALIDATION_DIR,
    JsonRpcClient,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
)
from app_server_network_approval_smoke import (
    APP_SERVER_BIN,
    NETWORK_COMMAND,
    NETWORK_HOST,
    ensure_app_server_binary,
    normalize_decision_kind,
    normalize_network_request,
    sse,
    status_type,
    write_managed_network_requirements,
    write_network_config,
)


USER_TEXT_1 = "Run the first app-server network persistent allow command."
USER_TEXT_2 = "Run the second app-server network persistent allow command."
FINAL_TEXT_1 = "App-server network persistent allow first answer."
FINAL_TEXT_2 = "App-server network persistent allow second answer."
CALL_ID_1 = "call-app-network-persistent-allow-1"
CALL_ID_2 = "call-app-network-persistent-allow-2"
CLIENT_USER_PREFIX = "client-user-network-persistent-allow"
NETWORK_RULE_SAVED_TEXT = (
    f"Allowed network rule saved in execpolicy (allowlist): {NETWORK_HOST}"
)

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Spec/Chat/CorePackage.md",
    "Spec/Chat/TimelineEvents.md",
    "Spec/Chat/CommandTimeline.md",
    "Spec/Chat/Projections.md",
    "Spec/Chat/ContextAndJournal.md",
    "Spec/Chat/Conformance.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/CODEX_BACKEND_MAPPING.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/app_server_network_approval_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_network_approval_persistent_allow_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/protocol/src/approvals.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/core/src/context/network_rule_saved.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]

SOURCE_FINDINGS = [
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
        "lines": "591-620",
        "finding": "Managed-network approval asks Session::request_command_approval with default decisions, network approval context, and generated policy amendments.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/tools/network_approval.rs",
        "lines": "623-661,732-738",
        "finding": "A NetworkPolicyAmendment Allow decision persists the rule, records saved-rule context, and also allows the host for the current session.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/session/mod.rs",
        "lines": "2025-2075,2094-2102",
        "finding": "Persisting the network amendment writes an execpolicy network rule and records a contextual saved-rule item.",
    },
    {
        "file": "upstream/openai-codex-original/codex-rs/core/src/context/network_rule_saved.rs",
        "lines": "33-41",
        "finding": "The saved-rule context text is 'Allowed network rule saved in execpolicy (allowlist): <host>'.",
    },
]


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


def ev_exec_command_call(response_id: str, call_id: str) -> bytes:
    arguments = json.dumps(
        {
            "cmd": NETWORK_COMMAND,
            "shell": "/bin/sh",
            "timeout_ms": 10000,
            "yield_time_ms": 1000,
            "max_output_tokens": 20000,
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
                    "name": "exec_command",
                    "arguments": arguments,
                },
            },
            ev_completed(response_id),
        ]
    )


def ev_final_message(response_id: str, message_id: str, text: str) -> bytes:
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


class PersistentAllowResponsesServer:
    def __init__(self) -> None:
        self.responses = [
            ev_exec_command_call("resp-app-network-persistent-allow-1", CALL_ID_1),
            ev_final_message(
                "resp-app-network-persistent-allow-2",
                "msg-app-network-persistent-allow-final-1",
                FINAL_TEXT_1,
            ),
            ev_exec_command_call("resp-app-network-persistent-allow-3", CALL_ID_2),
            ev_final_message(
                "resp-app-network-persistent-allow-4",
                "msg-app-network-persistent-allow-final-2",
                FINAL_TEXT_2,
            ),
        ]
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._httpd: http.server.ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "PersistentAllowResponsesServer":
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
        if 1 <= index <= len(self.responses):
            return self.responses[index - 1]
        return ev_final_message(
            f"resp-app-network-persistent-allow-extra-{index}",
            f"msg-app-network-persistent-allow-extra-{index}",
            FINAL_TEXT_2,
        )

    def record_request(self, request: dict[str, Any]) -> None:
        with self._lock:
            self.requests.append(request)

    def summary(self) -> dict[str, Any]:
        response_requests = [
            request for request in self.requests if request["path"].endswith("/responses")
        ]
        bodies = [request["json"] for request in response_requests]
        serialized = [json.dumps(body, ensure_ascii=False) for body in bodies]
        return {
            "request_count": len(self.requests),
            "response_request_count": len(response_requests),
            "paths": [request["path"] for request in self.requests],
            "contains_first_call_output": any(
                CALL_ID_1 in body and "function_call_output" in body
                for body in serialized
            ),
            "contains_second_call_output": any(
                CALL_ID_2 in body and "function_call_output" in body
                for body in serialized
            ),
            "contains_first_final_text": any(FINAL_TEXT_1 in body for body in serialized),
            "contains_second_final_text": any(FINAL_TEXT_2 in body for body in serialized),
            "contains_network_host": any(NETWORK_HOST in body for body in serialized),
            "contains_saved_rule_context": any(
                NETWORK_RULE_SAVED_TEXT in body for body in serialized
            ),
            "saved_rule_context_by_response_index": [
                index
                for index, body in enumerate(serialized, start=1)
                if NETWORK_RULE_SAVED_TEXT in body
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
                server: PersistentAllowResponsesServer = self.server.mock_server  # type: ignore[attr-defined]
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


def choose_allow_amendment(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params") or {}
    for amendment in params.get("proposedNetworkPolicyAmendments") or []:
        if amendment.get("action") == "allow":
            return amendment
    context = params.get("networkApprovalContext") or {}
    return {"host": context.get("host") or NETWORK_HOST, "action": "allow"}


def normalized_live_sequence(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
    sequence = []
    for message in received:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "item/commandExecution/requestApproval":
            context = params.get("networkApprovalContext") or {}
            amendments = params.get("proposedNetworkPolicyAmendments") or []
            available = params.get("availableDecisions") or []
            sequence.append(
                {
                    "event": "approvalRequest",
                    "networkHost": context.get("host"),
                    "networkProtocol": context.get("protocol"),
                    "proposedActions": sorted(
                        amendment.get("action")
                        for amendment in amendments
                        if isinstance(amendment, dict)
                    ),
                    "availableDecisionKinds": sorted(
                        normalize_decision_kind(decision) for decision in available
                    ),
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
            output = item.get("aggregatedOutput") or ""
            sequence.append(
                {
                    "event": "started" if method == "item/started" else "completed",
                    "status": status_type(item.get("status")),
                    "exitCode": item.get("exitCode"),
                    "containsNetworkHost": NETWORK_HOST in json.dumps(item, ensure_ascii=False),
                    "aggregatedOutputPresent": item.get("aggregatedOutput") is not None,
                    "outputMentionsSession": "Process running with session ID" in output,
                }
            )
        elif method == "turn/completed":
            sequence.append({"event": "turnCompleted"})
    return sequence


def approval_requests(received: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        message
        for message in received
        if message.get("method") == "item/commandExecution/requestApproval"
    ]


def normalize_thread_read_visible(response: dict[str, Any]) -> dict[str, Any]:
    thread = ((response.get("result") or {}).get("thread") or {})
    turns = thread.get("turns") or []
    serialized = json.dumps(turns, ensure_ascii=False)
    return {
        "has_error": "error" in response,
        "turn_count": len(turns),
        "turn_statuses": [status_type(turn.get("status")) for turn in turns],
        "contains_first_user_text": USER_TEXT_1 in serialized,
        "contains_second_user_text": USER_TEXT_2 in serialized,
        "contains_first_final_text": FINAL_TEXT_1 in serialized,
        "contains_second_final_text": FINAL_TEXT_2 in serialized,
        "contains_network_host": NETWORK_HOST in serialized,
        "contains_saved_rule_context": NETWORK_RULE_SAVED_TEXT in serialized,
    }


def summarize_execpolicy_network_rules(codex_home: pathlib.Path) -> dict[str, Any]:
    rule_files = sorted(codex_home.rglob("*.rules"))
    rules = []
    for path in rule_files:
        text = path.read_text(errors="replace")
        rules.append(
            {
                "path": str(path),
                "contains_network_host": NETWORK_HOST in text,
                "contains_allow": "allow" in text.lower(),
                "contains_expected_protocol": (
                    'protocol="http"' in text or "https_connect" in text
                ),
                "text_tail": text[-1200:],
            }
        )
    return {
        "rule_file_count": len(rule_files),
        "rules": rules,
        "has_persistent_allow_rule": any(
            rule["contains_network_host"]
            and rule["contains_allow"]
            and rule["contains_expected_protocol"]
            for rule in rules
        ),
    }


def summarize_original_persistent_allow(codex_home: pathlib.Path) -> dict[str, Any]:
    rollout_files = sorted((codex_home / "sessions").glob("**/*.jsonl"))
    rollouts = []
    for path in rollout_files:
        text = path.read_text(errors="replace")
        lines = read_json_lines(path)
        rollouts.append(
            {
                "path": str(path),
                "line_count": len(lines),
                "contains_network_host": NETWORK_HOST in text,
                "contains_saved_rule_context": NETWORK_RULE_SAVED_TEXT in text,
                "exec_function_call_count": text.count('"name":"exec_command"')
                + text.count('"name": "exec_command"'),
                "function_call_output_count": text.count("function_call_output"),
                "contains_first_call": CALL_ID_1 in text,
                "contains_second_call": CALL_ID_2 in text,
            }
        )
    return {
        "rollout_count": len(rollouts),
        "rollouts": rollouts,
        "has_two_network_calls": any(
            rollout["contains_network_host"]
            and rollout["exec_function_call_count"] >= 2
            and rollout["function_call_output_count"] >= 2
            and rollout["contains_first_call"]
            and rollout["contains_second_call"]
            for rollout in rollouts
        ),
        "has_saved_rule_context": any(
            rollout["contains_saved_rule_context"] for rollout in rollouts
        ),
    }


def summarize_chat_persistent_allow(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = []
    for package in sorted(chat_root.glob("*.chat")):
        timeline_path = package / "timeline.ndjson"
        journal_path = package / "journal.ndjson"
        timeline_lines = read_json_lines(timeline_path)
        journal_lines = read_json_lines(journal_path)
        timeline_text = timeline_path.read_text(errors="replace") if timeline_path.exists() else ""
        journal_text = journal_path.read_text(errors="replace") if journal_path.exists() else ""
        saved_rule_journal_event_ids = {
            line.get("event_id")
            for line in journal_lines
            if NETWORK_RULE_SAVED_TEXT in json.dumps(line, ensure_ascii=False)
        }
        saved_rule_timeline_message_refs = [
            line.get("id")
            for line in timeline_lines
            if line.get("type") == "message" and line.get("id") in saved_rule_journal_event_ids
        ]
        packages.append(
            {
                "package": str(package),
                "timeline_line_count": len(timeline_lines),
                "journal_line_count": len(journal_lines),
                "timeline_event_types": [line.get("type") for line in timeline_lines],
                "timeline_command_call_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_call"
                ),
                "timeline_command_output_count": sum(
                    1 for line in timeline_lines if line.get("type") == "command_output"
                ),
                "timeline_contains_network_host": NETWORK_HOST in timeline_text,
                "journal_contains_network_host": NETWORK_HOST in journal_text,
                "timeline_contains_saved_rule_context": NETWORK_RULE_SAVED_TEXT in timeline_text,
                "journal_contains_saved_rule_context": NETWORK_RULE_SAVED_TEXT in journal_text,
                "timeline_saved_rule_message_refs": saved_rule_timeline_message_refs,
                "journal_exec_function_call_count": journal_text.count("exec_command"),
                "journal_function_call_output_count": journal_text.count(
                    "function_call_output"
                ),
                "journal_contains_first_call": CALL_ID_1 in journal_text,
                "journal_contains_second_call": CALL_ID_2 in journal_text,
            }
        )
    return {
        "package_count": len(packages),
        "packages": packages,
        "has_two_command_timeline_pairs": any(
            package["timeline_command_call_count"] >= 2
            and package["timeline_command_output_count"] >= 2
            for package in packages
        ),
        "has_source_transport_for_both_calls": any(
            package["journal_contains_network_host"]
            and package["journal_exec_function_call_count"] >= 2
            and package["journal_function_call_output_count"] >= 2
            and package["journal_contains_first_call"]
            and package["journal_contains_second_call"]
            for package in packages
        ),
        "has_saved_rule_source_transport": any(
            package["journal_contains_saved_rule_context"] for package in packages
        ),
        "has_saved_rule_timeline_context": any(
            package["timeline_contains_saved_rule_context"]
            or bool(package["timeline_saved_rule_message_refs"])
            for package in packages
        ),
    }


def run_scenario(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    managed_dir = run_root / tree_name / "managed"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with PersistentAllowResponsesServer() as mock_server:
        write_network_config(codex_home, mock_server.url)
        managed_config_path = write_managed_network_requirements(managed_dir)
        codex_bin = codex_rs / "target/debug" / APP_SERVER_BIN
        previous_managed_path = os.environ.get("CODEX_APP_SERVER_MANAGED_CONFIG_PATH")
        os.environ["CODEX_APP_SERVER_MANAGED_CONFIG_PATH"] = str(managed_config_path)
        client = JsonRpcClient(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            app_server_subcommand=False,
        )
        stderr = ""
        initialize_response: dict[str, Any] = {}
        thread_start_response: dict[str, Any] = {}
        first_turn_start_response: dict[str, Any] = {}
        first_approval_request: dict[str, Any] = {}
        first_turn_completed: dict[str, Any] = {}
        second_turn_start_response: dict[str, Any] = {}
        second_terminal_message: dict[str, Any] = {}
        second_turn_completed: dict[str, Any] = {}
        thread_read_response: dict[str, Any] = {}
        thread_list_response: dict[str, Any] = {}
        allow_amendment: dict[str, Any] = {}
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
                        "clientUserMessageId": f"{CLIENT_USER_PREFIX}-1-{tree_name}",
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

            while True:
                message = client.receive_until(
                    lambda msg: msg.get("method")
                    in {
                        "item/commandExecution/requestApproval",
                        "turn/completed",
                    },
                    timeout_seconds=90,
                    description="first turn network approval request or completion",
                )
                if message.get("method") == "turn/completed":
                    first_turn_completed = message
                    break
                if (message.get("params") or {}).get("networkApprovalContext") is None:
                    client.send(
                        {
                            "jsonrpc": "2.0",
                            "id": message.get("id"),
                            "result": {"decision": "accept"},
                        }
                    )
                    continue

                first_approval_request = message
                allow_amendment = choose_allow_amendment(message)
                client.send(
                    {
                        "jsonrpc": "2.0",
                        "id": message.get("id"),
                        "result": {
                            "decision": {
                                "applyNetworkPolicyAmendment": {
                                    "network_policy_amendment": allow_amendment,
                                }
                            }
                        },
                    }
                )
                first_turn_completed = client.receive_until_method(
                    "turn/completed", timeout_seconds=90
                )
                break

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "turn/start",
                    "params": {
                        "threadId": started_thread_id,
                        "clientUserMessageId": f"{CLIENT_USER_PREFIX}-2-{tree_name}",
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
            second_terminal_message = client.receive_until(
                lambda msg: msg.get("method")
                in {
                    "item/commandExecution/requestApproval",
                    "turn/completed",
                },
                timeout_seconds=90,
                description="second turn approval request or completion",
            )
            if second_terminal_message.get("method") == "item/commandExecution/requestApproval":
                client.send(
                    {
                        "jsonrpc": "2.0",
                        "id": second_terminal_message.get("id"),
                        "result": {"decision": "accept"},
                    }
                )
                second_turn_completed = client.receive_until_method(
                    "turn/completed", timeout_seconds=90
                )
            else:
                second_turn_completed = second_terminal_message

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

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 6,
                    "method": "thread/list",
                    "params": {},
                }
            )
            thread_list_response = client.receive_until_response(6, timeout_seconds=30)
        finally:
            stderr = client.close()
            if previous_managed_path is None:
                os.environ.pop("CODEX_APP_SERVER_MANAGED_CONFIG_PATH", None)
            else:
                os.environ["CODEX_APP_SERVER_MANAGED_CONFIG_PATH"] = previous_managed_path

    live_sequence = normalized_live_sequence(client.received)
    result: dict[str, Any] = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "managed_config_path": str(managed_config_path),
        "chat_root": str(chat_root),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "first_turn_start_response": first_turn_start_response,
        "first_approval_request": first_approval_request,
        "normalized_first_approval_request": normalize_network_request(
            first_approval_request or {},
            started_thread_id,
        ),
        "allow_amendment_sent": allow_amendment,
        "first_turn_completed": first_turn_completed,
        "second_turn_start_response": second_turn_start_response,
        "second_terminal_message": second_terminal_message,
        "second_turn_completed": second_turn_completed,
        "second_turn_completed_without_network_approval": (
            second_terminal_message.get("method") == "turn/completed"
        ),
        "approval_request_count": len(approval_requests(client.received)),
        "thread_read_response": thread_read_response,
        "thread_list_response": thread_list_response,
        "normalized_live_sequence": live_sequence,
        "normalized_thread_read_visible": normalize_thread_read_visible(thread_read_response),
        "execpolicy_network_rules": summarize_execpolicy_network_rules(codex_home),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-8000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
        result["chat_persistent_allow_summary"] = summarize_chat_persistent_allow(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)
        result["original_persistent_allow_summary"] = summarize_original_persistent_allow(
            codex_home
        )
    return result


def scenario_ok(result: dict[str, Any]) -> bool:
    request = result["normalized_first_approval_request"]
    mock = result["mock_server_summary"]
    visible = result["normalized_thread_read_visible"]
    rules = result["execpolicy_network_rules"]
    if "result" not in result["first_turn_start_response"]:
        return False
    if "result" not in result["second_turn_start_response"]:
        return False
    if "result" not in result["thread_read_response"]:
        return False
    if not request["thread_id_matches"]:
        return False
    if request["network_host"] != NETWORK_HOST:
        return False
    if request["network_protocol"] != "http":
        return False
    if request["proposed_actions"] != ["allow", "deny"]:
        return False
    if "applyNetworkPolicyAmendment" not in request["available_decision_kinds"]:
        return False
    if result["allow_amendment_sent"].get("action") != "allow":
        return False
    if result["allow_amendment_sent"].get("host") != NETWORK_HOST:
        return False
    if result["approval_request_count"] != 1:
        return False
    if not result["second_turn_completed_without_network_approval"]:
        return False
    if not rules["has_persistent_allow_rule"]:
        return False
    if not (
        mock["response_request_count"] == 4
        and mock["contains_first_call_output"]
        and mock["contains_second_call_output"]
        and mock["contains_first_final_text"]
        and mock["contains_saved_rule_context"]
    ):
        return False
    if not (
        visible["contains_first_user_text"]
        and visible["contains_second_user_text"]
        and visible["contains_first_final_text"]
        and visible["contains_second_final_text"]
    ):
        return False
    if result["tree"] == "chat-backend":
        chat_summary = result["chat_persistent_allow_summary"]
        return (
            chat_summary["has_two_command_timeline_pairs"]
            and chat_summary["has_source_transport_for_both_calls"]
            and chat_summary["has_saved_rule_source_transport"]
            and chat_summary["has_saved_rule_timeline_context"]
        )
    original_summary = result["original_persistent_allow_summary"]
    return (
        original_summary["has_two_network_calls"]
        and original_summary["has_saved_rule_context"]
    )


def write_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# App-Server Network Persistent Allow Smoke",
        "",
        f"Generated at: `{utc_now_iso()}`",
        "",
        "## Scope",
        "",
        "This is a narrow app-server managed-network persistent allow smoke.",
        "It drives the real app-server stdio path in both vendored trees,",
        "responds to the first network approval with",
        "`applyNetworkPolicyAmendment(allow)`, then verifies the next same-host",
        "turn completes without another network approval request.",
        "",
        "It does not prove the real TUI `p` shortcut path, persistent block,",
        "non-default deny amendments, arbitrary crash recovery, or final Codex",
        "user-indistinguishability.",
        "",
        "## Result",
        "",
        f"- all scenarios ok: `{summary['all_scenarios_ok']}`",
        f"- normalized first approval request equal: `{summary['normalized_first_approval_request_equal']}`",
        f"- normalized live sequence equal: `{summary['normalized_live_sequence_equal']}`",
        f"- normalized thread/read visible equal: `{summary['normalized_thread_read_visible_equal']}`",
        f"- mock summaries equal: `{summary['mock_summaries_equal']}`",
        f"- original execpolicy persistent allow rule: `{summary['original_execpolicy_has_persistent_allow_rule']}`",
        f"- `.chat` execpolicy persistent allow rule: `{summary['chat_backend_execpolicy_has_persistent_allow_rule']}`",
        f"- original saved-rule context persisted: `{summary['original_has_saved_rule_context_persisted']}`",
        f"- `.chat` saved-rule context in source transport/timeline: `{summary['chat_backend_has_saved_rule_source_transport']}` / `{summary['chat_backend_has_saved_rule_timeline_context']}`",
        f"- second same-host turn avoided another network approval on both backends: `{summary['second_turn_avoided_network_approval_on_both']}`",
        "",
        "## Source Basis",
        "",
    ]
    for finding in SOURCE_FINDINGS:
        lines.append(
            f"- `{finding['file']}:{finding['lines']}`: {finding['finding']}"
        )
    lines.extend(
        [
            "",
            "## Evidence",
            "",
            "- `summary.json`",
            "- `original/network-persistent-allow-response.json`",
            "- `chat-backend/network-persistent-allow-response.json`",
            "",
        ]
    )
    (output_dir / "report.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-network-persistent-allow-smoke-"
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
        "original_cli": ensure_binary(ORIGINAL_CODEX_RS, args.build_if_missing),
        "chat_backend_cli": ensure_binary(CHAT_BACKEND_CODEX_RS, args.build_if_missing),
        "original_app_server": ensure_app_server_binary(
            ORIGINAL_CODEX_RS,
            args.build_if_missing,
        ),
        "chat_backend_app_server": ensure_app_server_binary(
            CHAT_BACKEND_CODEX_RS,
            args.build_if_missing,
        ),
    }

    run_root = output_dir / "run"
    original = run_scenario(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_store_root = run_root / "chat-backend" / "chat-store"
    chat = run_scenario(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    original_rules = original["execpolicy_network_rules"]
    chat_rules = chat["execpolicy_network_rules"]
    original_persistent = original["original_persistent_allow_summary"]
    chat_persistent = chat["chat_persistent_allow_summary"]

    summary: dict[str, Any] = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-network-persistent-allow-smoke",
        "matrix_slice": ["T06-network-persistent-allow", "R01-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "source_findings": SOURCE_FINDINGS,
        "binary_checks": binary_checks,
        "original_ok": scenario_ok(original),
        "chat_backend_ok": scenario_ok(chat),
        "normalized_first_approval_request_equal": (
            original["normalized_first_approval_request"]
            == chat["normalized_first_approval_request"]
        ),
        "normalized_live_sequence_equal": (
            original["normalized_live_sequence"] == chat["normalized_live_sequence"]
        ),
        "normalized_thread_read_visible_equal": (
            original["normalized_thread_read_visible"]
            == chat["normalized_thread_read_visible"]
        ),
        "mock_summaries_equal": (
            original["mock_server_summary"] == chat["mock_server_summary"]
        ),
        "original_execpolicy_has_persistent_allow_rule": original_rules[
            "has_persistent_allow_rule"
        ],
        "chat_backend_execpolicy_has_persistent_allow_rule": chat_rules[
            "has_persistent_allow_rule"
        ],
        "original_has_saved_rule_context_persisted": original_persistent[
            "has_saved_rule_context"
        ],
        "chat_backend_has_saved_rule_source_transport": chat_persistent[
            "has_saved_rule_source_transport"
        ],
        "chat_backend_has_saved_rule_timeline_context": chat_persistent[
            "has_saved_rule_timeline_context"
        ],
        "chat_backend_has_two_network_timeline_pairs": chat_persistent[
            "has_two_command_timeline_pairs"
        ],
        "chat_backend_has_source_transport_for_both_calls": chat_persistent[
            "has_source_transport_for_both_calls"
        ],
        "second_turn_avoided_network_approval_on_both": (
            original["second_turn_completed_without_network_approval"]
            and chat["second_turn_completed_without_network_approval"]
            and original["approval_request_count"] == 1
            and chat["approval_request_count"] == 1
        ),
        "original": {
            "normalized_first_approval_request": original[
                "normalized_first_approval_request"
            ],
            "normalized_live_sequence": original["normalized_live_sequence"],
            "normalized_thread_read_visible": original["normalized_thread_read_visible"],
            "mock_server_summary": original["mock_server_summary"],
            "execpolicy_network_rules": original_rules,
            "original_persistent_allow_summary": original_persistent,
        },
        "chat_backend": {
            "normalized_first_approval_request": chat[
                "normalized_first_approval_request"
            ],
            "normalized_live_sequence": chat["normalized_live_sequence"],
            "normalized_thread_read_visible": chat["normalized_thread_read_visible"],
            "mock_server_summary": chat["mock_server_summary"],
            "execpolicy_network_rules": chat_rules,
            "chat_persistent_allow_summary": chat_persistent,
        },
        "claim": (
            "Narrow app-server persistent network allow amendment parity only; "
            "real TUI `p` shortcut remains a separate open diagnostic."
        ),
    }
    summary["all_scenarios_ok"] = (
        summary["original_ok"]
        and summary["chat_backend_ok"]
        and summary["normalized_first_approval_request_equal"]
        and summary["normalized_live_sequence_equal"]
        and summary["normalized_thread_read_visible_equal"]
        and summary["mock_summaries_equal"]
        and summary["original_execpolicy_has_persistent_allow_rule"]
        and summary["chat_backend_execpolicy_has_persistent_allow_rule"]
        and summary["original_has_saved_rule_context_persisted"]
        and summary["chat_backend_has_saved_rule_source_transport"]
        and summary["chat_backend_has_saved_rule_timeline_context"]
        and summary["chat_backend_has_two_network_timeline_pairs"]
        and summary["chat_backend_has_source_transport_for_both_calls"]
        and summary["second_turn_avoided_network_approval_on_both"]
    )

    write_json(output_dir / "original/network-persistent-allow-response.json", original)
    write_json(output_dir / "chat-backend/network-persistent-allow-response.json", chat)
    write_json(output_dir / "summary.json", summary)
    write_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_scenarios_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
