#!/usr/bin/env python3
"""Requirements permission fallback parity smoke for Codex `.chat` backend.

This source-backed validation drives the real app-server path for both the original
Codex backend and the adapted `.chat` backend. The fixture deliberately asks for
the built-in danger-full-access permission profile in user config, then injects
a debug managed `requirements.toml` that allows only a managed read profile.
The test checks that both backends expose and persist the same effective
permission snapshot after requirements force the fallback.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import contextlib
import datetime as dt
import json
import os
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
from app_server_named_permission_profile_smoke import active_permission_profile_from_read
from app_server_named_permission_profile_smoke import active_permission_profile_from_start
from app_server_named_permission_profile_smoke import normalize_dynamic_permission_comparison
from app_server_turn_context_field_parity_smoke import compare_turn_contexts


MANAGED_PROFILE_ID = "managed-standard"
REQUESTED_PROFILE_ID = ":danger-full-access"
MANAGED_CONFIG_ENV = "CODEX_APP_SERVER_MANAGED_CONFIG_PATH"


def ensure_app_server_binary(codex_rs: pathlib.Path) -> dict[str, Any]:
    binary = codex_rs / "target/debug/codex-app-server"
    if not binary.exists():
        raise RuntimeError(
            f"missing {binary}; run `cargo build -p codex-app-server --bin codex-app-server` first"
        )
    return {
        "artifact": str(binary),
        "artifact_exists": True,
        "artifact_size_bytes": binary.stat().st_size,
    }


@contextlib.contextmanager
def managed_config_path(path: pathlib.Path) -> Any:
    old_value = os.environ.get(MANAGED_CONFIG_ENV)
    os.environ[MANAGED_CONFIG_ENV] = str(path)
    try:
        yield
    finally:
        if old_value is None:
            os.environ.pop(MANAGED_CONFIG_ENV, None)
        else:
            os.environ[MANAGED_CONFIG_ENV] = old_value


def write_requirements_fixture(
    codex_home: pathlib.Path,
    managed_dir: pathlib.Path,
    server_url: str,
) -> pathlib.Path:
    config = f"""
model = "mock-model"
model_provider = "mock_provider"
approval_policy = "on-request"
default_permissions = "{REQUESTED_PROFILE_ID}"
suppress_unstable_features_warning = true

[model_providers.mock_provider]
name = "Mock provider for requirements fallback test"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
"""
    (codex_home / "config.toml").write_text(config)

    managed_dir.mkdir(parents=True, exist_ok=True)
    managed_config = managed_dir / "managed_config.toml"
    requirements = managed_dir / "requirements.toml"
    managed_config.write_text("# managed config fixture for app-server smoke\n")
    requirements.write_text(
        f"""
default_permissions = "{MANAGED_PROFILE_ID}"

[allowed_permission_profiles]
{MANAGED_PROFILE_ID} = true

[permissions.{MANAGED_PROFILE_ID}.filesystem]
":workspace_roots" = "read"

[permissions.{MANAGED_PROFILE_ID}.network]
enabled = false

[experimental_network]
enabled = true
allow_upstream_proxy = false
managed_allowed_domains_only = true
allow_local_binding = false

[experimental_network.domains]
"api.example.com" = "allow"
"blocked.example.com" = "deny"
"""
    )
    return managed_config


def requirements_markers(
    comparison: dict[str, Any],
    original_result: dict[str, Any],
    chat_result: dict[str, Any],
) -> dict[str, Any]:
    original_contexts = comparison.get("original_turn_contexts") or []
    chat_contexts = comparison.get("chat_journal_turn_contexts") or []
    original_payload = (
        original_contexts[0].get("normalized_payload") if original_contexts else {}
    )
    chat_payload = chat_contexts[0].get("normalized_payload") if chat_contexts else {}

    original_profile = original_payload.get("permission_profile") or {}
    chat_profile = chat_payload.get("permission_profile") or {}
    original_filesystem = original_profile.get("file_system") or {}
    chat_filesystem = chat_profile.get("file_system") or {}
    original_serialized_profile = json.dumps(original_profile, sort_keys=True)
    chat_serialized_profile = json.dumps(chat_profile, sort_keys=True)
    original_start_profile = original_result.get("active_permission_profile_start") or {}
    chat_start_profile = chat_result.get("active_permission_profile_start") or {}
    original_read_profile = original_result.get("active_permission_profile_read") or {}
    chat_read_profile = chat_result.get("active_permission_profile_read") or {}

    return {
        "requested_profile_id": REQUESTED_PROFILE_ID,
        "managed_profile_id": MANAGED_PROFILE_ID,
        "original_active_start_id": original_start_profile.get("id"),
        "chat_active_start_id": chat_start_profile.get("id"),
        "original_active_read_id": original_read_profile.get("id"),
        "chat_active_read_id": chat_read_profile.get("id"),
        "active_start_ids_equal": original_start_profile.get("id")
        == chat_start_profile.get("id"),
        "active_read_ids_equal": original_read_profile.get("id")
        == chat_read_profile.get("id"),
        "active_read_omits_profile_equally": original_read_profile.get("id") is None
        and chat_read_profile.get("id") is None,
        "active_start_uses_managed_profile": original_start_profile.get("id")
        == MANAGED_PROFILE_ID
        and chat_start_profile.get("id") == MANAGED_PROFILE_ID,
        "original_permission_profile_type": original_profile.get("type"),
        "chat_permission_profile_type": chat_profile.get("type"),
        "permission_profile_types_equal": original_profile.get("type")
        == chat_profile.get("type"),
        "permission_profile_uses_managed_type": original_profile.get("type")
        == "managed"
        and chat_profile.get("type") == "managed",
        "original_permission_network": original_profile.get("network"),
        "chat_permission_network": chat_profile.get("network"),
        "permission_networks_equal": original_profile.get("network")
        == chat_profile.get("network"),
        "permission_network_restricted": original_profile.get("network") == "restricted"
        and chat_profile.get("network") == "restricted",
        "filesystem_types_equal": original_filesystem.get("type")
        == chat_filesystem.get("type"),
        "filesystem_restricted": original_filesystem.get("type") == "restricted"
        and chat_filesystem.get("type") == "restricted",
        "contains_workspace_read": '"access": "read"' in original_serialized_profile
        and '"<workspace>"' in original_serialized_profile
        and '"access": "read"' in chat_serialized_profile
        and '"<workspace>"' in chat_serialized_profile,
        "danger_full_access_not_effective": original_profile.get("type") != "disabled"
        and chat_profile.get("type") != "disabled",
        "original_network_snapshot": original_payload.get("network"),
        "chat_network_snapshot": chat_payload.get("network"),
        "network_snapshots_equal": original_payload.get("network")
        == chat_payload.get("network"),
    }


def run_requirements_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex-app-server"
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    managed_dir = run_root / tree_name / "managed"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    (workspace / "docs").mkdir(parents=True, exist_ok=True)
    (workspace / "docs" / "visible.txt").write_text("managed requirements readable\n")

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        managed_config = write_requirements_fixture(codex_home, managed_dir, mock_server.url)
        with managed_config_path(managed_config):
            client = JsonRpcClient(
                codex_bin,
                workspace,
                codex_home,
                config_overrides,
                app_server_subcommand=False,
            )
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
                        "clientUserMessageId": "client-user-message-requirements-fallback",
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
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
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

            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "thread/list",
                    "params": {
                        "limit": 10,
                        "modelProviders": [],
                        "archived": False,
                    },
                }
            )
            thread_list_response = client.receive_until_response(5, timeout_seconds=30)
        finally:
            stderr = client.close()

    result: dict[str, Any] = {
        "tree": tree_name,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "managed_config": str(managed_config),
        "requirements_toml": str(managed_config.with_name("requirements.toml")),
        "requested_profile_id": REQUESTED_PROFILE_ID,
        "managed_profile_id": MANAGED_PROFILE_ID,
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_started_notification": turn_started_notification,
        "turn_completed_notification": turn_completed_notification,
        "thread_read_response": thread_read_response,
        "thread_list_response": thread_list_response,
        "active_permission_profile_start": active_permission_profile_from_start(
            thread_start_response
        ),
        "active_permission_profile_read": active_permission_profile_from_read(
            thread_read_response
        ),
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
            "app-server-requirements-permission-fallback-smoke-"
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
        "original-app-server": ensure_app_server_binary(ORIGINAL_CODEX_RS),
        "chat-backend-app-server": ensure_app_server_binary(CHAT_BACKEND_CODEX_RS),
    }

    run_root = output_dir / "run"
    chat_store_root = run_root / "chat-backend" / "chat-store"
    original_result = run_requirements_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_result = run_requirements_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        config_overrides=[
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    comparison = normalize_dynamic_permission_comparison(
        compare_turn_contexts(original_result, chat_result)
    )
    markers = requirements_markers(comparison, original_result, chat_result)
    original_lines = original_result["original_storage_summary"]["rollouts"][0]["line_count"]
    chat_lines = chat_result["chat_package_summary"]["packages"][0]["journal_line_count"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-requirements-permission-fallback-smoke",
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
            "codex-rs/app-server/src/main.rs",
            "codex-rs/config/src/state.rs",
            "codex-rs/config/src/config_requirements.rs",
            "codex-rs/config/src/config_toml.rs",
            "codex-rs/core/src/config/config_loader_tests.rs",
            "codex-rs/core/src/config/config_tests.rs",
            "codex-rs/core/src/config/network_proxy_spec.rs",
            "codex-rs/core/src/session/turn_context.rs",
            "codex-rs/app-server-protocol/src/protocol/v2/thread.rs",
            "codex-rs/app-server-protocol/src/protocol/v2/turn.rs",
        ],
        "binary_checks": binary_checks,
        "requested_profile_id": REQUESTED_PROFILE_ID,
        "managed_profile_id": MANAGED_PROFILE_ID,
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
        "requirements_permission_fallback_markers": markers,
        "requirements_permission_fallback_markers_present": all(
            [
                markers["active_start_ids_equal"],
                markers["active_read_ids_equal"],
                markers["active_read_omits_profile_equally"],
                markers["active_start_uses_managed_profile"],
                markers["permission_profile_types_equal"],
                markers["permission_profile_uses_managed_type"],
                markers["permission_networks_equal"],
                markers["permission_network_restricted"],
                markers["filesystem_types_equal"],
                markers["filesystem_restricted"],
                markers["contains_workspace_read"],
                markers["danger_full_access_not_effective"],
                markers["network_snapshots_equal"],
            ]
        ),
        "not_yet_proven": [
            "managed cloud environment constraints",
            "remote environment selection parity",
            "environment startup/failed-environment snapshot variants",
            "complete environment snapshot parity across every configuration variant",
            "exhaustive managed requirements combinations",
            "final user-indistinguishability",
        ],
    }

    write_json(
        output_dir / "original/requirements-permission-fallback-response.json",
        original_result,
    )
    write_json(
        output_dir / "chat-backend/requirements-permission-fallback-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Requirements Permission Fallback Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex `.chat` backend adaptation.
It drives the real `codex-app-server` JSON-RPC stdio path for the original
backend and the `.chat` backend while injecting a debug managed
`requirements.toml` fixture.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
persisted-item inventory, and current data-fidelity JSON were read. The relevant
Codex app-server managed-config, requirements, permission-profile, network, and
turn-context source files listed in `summary.json` were also read.

## Scope

The user config requests `{REQUESTED_PROFILE_ID}`. The sibling
`requirements.toml` loaded through `CODEX_APP_SERVER_MANAGED_CONFIG_PATH`
allows only `{MANAGED_PROFILE_ID}` and sets that managed profile as the default.
The smoke verifies that both original and `.chat` backends expose the same
effective managed profile through `thread/start`, omit active profile ids
equally from `thread/read`, persist the same normalized `TurnContextItem`
payload, and keep `.chat`
`runtime_context_snapshot` events linked to the retained journal source
transport.

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
- requirements fallback markers present: `{summary['requirements_permission_fallback_markers_present']}`

## Requirements Fallback Markers

```json
{json.dumps(markers, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/requirements-permission-fallback-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/requirements-permission-fallback-response.json
```

## Not Yet Proven

This smoke does not prove managed cloud environment constraints, remote
environment selection parity, environment startup/failed-environment variants,
complete environment snapshot parity across every configuration variant,
exhaustive managed requirements combinations, or final user-indistinguishability.
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
        and summary["requirements_permission_fallback_markers_present"]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
