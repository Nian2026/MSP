#!/usr/bin/env python3
"""Environment snapshot parity smoke for Codex `.chat` backend.

This source-backed validation drives the real app-server path for both the original
Codex backend and the adapted `.chat` backend. It runs two turns: one with the
thread's initial local environment and one that changes the per-turn local
environment cwd plus runtime workspace roots. The test compares the persisted
`TurnContextItem` snapshots field by field and checks that `.chat` timeline
runtime-context events link back to the retained journal source transport.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
from typing import Any

from app_server_durable_turn_smoke import ASSISTANT_TEXT
from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import MockResponsesServer
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import USER_TEXT
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import JsonRpcClient
from app_server_durable_turn_smoke import ensure_binary
from app_server_durable_turn_smoke import normalize_thread_list_response
from app_server_durable_turn_smoke import normalize_thread_read_response
from app_server_durable_turn_smoke import normalize_thread_start_response
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import summarize_path_observation
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json
from app_server_durable_turn_smoke import write_mock_config
from app_server_turn_context_field_parity_smoke import compare_turn_contexts


SECOND_USER_TEXT = "Persist this second environment snapshot turn."
LOCAL_ENVIRONMENT_ID = "local"


def environment_snapshot_markers(comparison: dict[str, Any]) -> dict[str, Any]:
    original_contexts = comparison.get("original_turn_contexts") or []
    chat_contexts = comparison.get("chat_journal_turn_contexts") or []
    original_payloads = [
        item.get("normalized_payload") for item in original_contexts
    ]
    chat_payloads = [item.get("normalized_payload") for item in chat_contexts]
    second_original = original_payloads[1] if len(original_payloads) > 1 else {}
    second_chat = chat_payloads[1] if len(chat_payloads) > 1 else {}

    expected_second_cwd = "<workspace>/env-target"
    expected_second_workspace_roots = [
        "<workspace>/env-target",
        "<workspace>/shared",
    ]

    return {
        "original_turn_context_count": len(original_payloads),
        "chat_turn_context_count": len(chat_payloads),
        "second_original_cwd": second_original.get("cwd"),
        "second_chat_cwd": second_chat.get("cwd"),
        "second_cwd_equal": second_original.get("cwd") == second_chat.get("cwd"),
        "second_cwd_matches_environment": second_original.get("cwd")
        == expected_second_cwd
        and second_chat.get("cwd") == expected_second_cwd,
        "second_original_workspace_roots": second_original.get("workspace_roots"),
        "second_chat_workspace_roots": second_chat.get("workspace_roots"),
        "second_workspace_roots_equal": second_original.get("workspace_roots")
        == second_chat.get("workspace_roots"),
        "second_workspace_roots_match_override": second_original.get("workspace_roots")
        == expected_second_workspace_roots
        and second_chat.get("workspace_roots") == expected_second_workspace_roots,
        "all_current_dates_present": all(
            bool(payload.get("current_date")) for payload in original_payloads + chat_payloads
        ),
        "all_timezones_present": all(
            bool(payload.get("timezone")) for payload in original_payloads + chat_payloads
        ),
        "timeline_snapshot_count_matches_journal_contexts": comparison.get(
            "chat_timeline_turn_context_count"
        )
        == len(chat_payloads),
    }


def run_environment_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    env_target = workspace / "env-target"
    shared_root = workspace / "shared"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    env_target.mkdir(parents=True, exist_ok=True)
    shared_root.mkdir(parents=True, exist_ok=True)

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
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
                        "runtimeWorkspaceRoots": [str(workspace)],
                        "environments": [
                            {
                                "environmentId": LOCAL_ENVIRONMENT_ID,
                                "cwd": str(workspace),
                            }
                        ],
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
                        "clientUserMessageId": "client-user-message-environment-initial",
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
            first_turn_start_response = client.receive_until_response(3, timeout_seconds=30)
            first_turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            first_turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "turn/start",
                    "params": {
                        "threadId": started_thread_id,
                        "clientUserMessageId": "client-user-message-environment-override",
                        "input": [
                            {
                                "type": "text",
                                "text": SECOND_USER_TEXT,
                                "textElements": [],
                            }
                        ],
                        "environments": [
                            {
                                "environmentId": LOCAL_ENVIRONMENT_ID,
                                "cwd": str(env_target),
                            }
                        ],
                        "runtimeWorkspaceRoots": [
                            str(env_target),
                            str(shared_root),
                        ],
                    },
                }
            )
            second_turn_start_response = client.receive_until_response(4, timeout_seconds=30)
            second_turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            second_turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

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
                    "params": {
                        "limit": 10,
                        "modelProviders": [],
                        "archived": False,
                    },
                }
            )
            thread_list_response = client.receive_until_response(6, timeout_seconds=30)
        finally:
            stderr = client.close()

    result: dict[str, Any] = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "env_target": str(env_target),
        "shared_root": str(shared_root),
        "codex_home": str(codex_home),
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "first_turn_start_response": first_turn_start_response,
        "first_turn_started_notification": first_turn_started_notification,
        "first_turn_completed_notification": first_turn_completed_notification,
        "second_turn_start_response": second_turn_start_response,
        "second_turn_started_notification": second_turn_started_notification,
        "second_turn_completed_notification": second_turn_completed_notification,
        "thread_read_response": thread_read_response,
        "thread_list_response": thread_list_response,
        "normalized_thread_start": normalize_thread_start_response(thread_start_response),
        "normalized_thread_read": normalize_thread_read_response(thread_read_response),
        "normalized_thread_list": normalize_thread_list_response(
            thread_list_response,
            started_thread_id,
        ),
        "thread_read_path_observation": summarize_path_observation(
            thread_read_response,
            started_thread_id,
        ),
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }

    if tree_name == "chat-backend":
        result["chat_package_summary"] = summarize_chat_packages(chat_root)
    else:
        result["original_storage_summary"] = summarize_original_storage(codex_home)

    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-environment-snapshot-smoke-"
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
    original_result = run_environment_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_result = run_environment_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    comparison = compare_turn_contexts(original_result, chat_result)
    markers = environment_snapshot_markers(comparison)
    original_lines = original_result["original_storage_summary"]["rollouts"][0]["line_count"]
    chat_lines = chat_result["chat_package_summary"]["packages"][0]["journal_line_count"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-environment-snapshot-smoke",
        "gate_files_read": [
            "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
            "Spec/Chat/README.md",
            "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
            "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
            "Conformance/Chat/CodexCliValidation/CODEX_BACKEND_MAPPING.md",
            "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
            "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
        ],
        "source_files_read": [
            "codex-rs/protocol/src/protocol.rs",
            "codex-rs/core/src/session/turn_context.rs",
            "codex-rs/core/src/environment_selection.rs",
            "codex-rs/app-server-protocol/src/protocol/v2/thread.rs",
            "codex-rs/app-server-protocol/src/protocol/v2/turn.rs",
            "codex-rs/app-server/src/request_processors.rs",
            "codex-rs/app-server/src/request_processors/thread_processor.rs",
            "codex-rs/app-server/src/request_processors/turn_processor.rs",
        ],
        "binary_checks": binary_checks,
        "normalized_thread_start_equal": original_result["normalized_thread_start"]
        == chat_result["normalized_thread_start"],
        "normalized_thread_read_equal": original_result["normalized_thread_read"]
        == chat_result["normalized_thread_read"],
        "normalized_thread_list_equal": original_result["normalized_thread_list"]
        == chat_result["normalized_thread_list"],
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_lines,
        "line_counts_equal": original_lines == chat_lines,
        "original_mock_response_count": original_result["mock_server_summary"][
            "response_request_count"
        ],
        "chat_mock_response_count": chat_result["mock_server_summary"][
            "response_request_count"
        ],
        "mock_response_counts_equal": original_result["mock_server_summary"][
            "response_request_count"
        ]
        == chat_result["mock_server_summary"]["response_request_count"],
        **comparison,
        "environment_snapshot_markers": markers,
        "environment_snapshot_markers_present": all(
            [
                markers["original_turn_context_count"] == 2,
                markers["chat_turn_context_count"] == 2,
                markers["second_cwd_equal"],
                markers["second_cwd_matches_environment"],
                markers["second_workspace_roots_equal"],
                markers["second_workspace_roots_match_override"],
                markers["all_current_dates_present"],
                markers["all_timezones_present"],
                markers["timeline_snapshot_count_matches_journal_contexts"],
            ]
        ),
        "not_yet_proven": [
            "remote environment selection parity",
            "environment startup/failed-environment snapshot variants",
            "requirements.toml forced environment or network constraints",
            "managed cloud environment constraints",
            "complete environment snapshot parity across every configuration variant",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/environment-snapshot-response.json", original_result)
    write_json(output_dir / "chat-backend/environment-snapshot-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Environment Snapshot Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex `.chat` backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path for the original
backend and the `.chat` backend, then compares persisted `TurnContextItem`
payloads across two turns.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and current data-fidelity JSON were read. The relevant Codex app-server
environment, protocol, and turn-context source files listed in `summary.json`
were also read.

## Scope

This smoke covers a focused environment snapshot slice. The first turn uses the
thread's initial local environment and runtime workspace root. The second turn
uses a `turn/start.environments` override for the local environment cwd plus a
`runtimeWorkspaceRoots` override. It compares original rollout
`turn_context.payload` with the `.chat` journal `source_transport` payload and
checks that `.chat` timeline `runtime_context_snapshot` events link back to
their journal `turn_context` entries.

## Result

- normalized `thread/start` equal: `{summary['normalized_thread_start_equal']}`
- normalized `thread/read` equal: `{summary['normalized_thread_read_equal']}`
- normalized `thread/list` equal: `{summary['normalized_thread_list_equal']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- mock Responses request counts equal: `{summary['mock_response_counts_equal']}`
- turn context counts equal: `{summary['counts_equal']}`
- turn context field presence equal: `{summary['field_presence_equal']}`
- normalized turn context payloads equal: `{summary['normalized_payloads_equal']}`
- timeline snapshot links valid: `{summary['timeline_links_all_valid']}`
- environment snapshot markers present: `{summary['environment_snapshot_markers_present']}`

## Environment Snapshot Markers

```json
{json.dumps(markers, indent=2, sort_keys=True)}
```

## Turn Context Comparison

```json
{json.dumps({'original': summary['original_turn_contexts'], 'chat-backend': summary['chat_journal_turn_contexts']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/environment-snapshot-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/environment-snapshot-response.json
```

## Not Yet Proven

This smoke does not prove remote environment selection, environment startup or
failed-environment variants, requirements.toml forced environment/network
constraints, managed cloud constraints, complete environment snapshot parity
across every configuration variant, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    ok = (
        summary["normalized_thread_start_equal"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["line_counts_equal"]
        and summary["mock_response_counts_equal"]
        and summary["counts_equal"]
        and summary["field_presence_equal"]
        and summary["normalized_payloads_equal"]
        and summary["timeline_links_all_valid"]
        and summary["environment_snapshot_markers_present"]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
