#!/usr/bin/env python3
"""Named permission-profile parity smoke for Codex `.chat` backend.

This source-backed validation drives the real app-server path for both the original
Codex backend and the adapted `.chat` backend with a restrictive named
`default_permissions` profile. It checks that the profile-derived permission
snapshot is persisted without loss in `.chat` journal/timeline data.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import re
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
from app_server_durable_turn_smoke import read_json_lines
from app_server_durable_turn_smoke import summarize_chat_packages
from app_server_durable_turn_smoke import summarize_original_storage
from app_server_durable_turn_smoke import summarize_path_observation
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json
from app_server_turn_context_field_parity_smoke import compare_turn_contexts


PROFILE_ID = "strict_profile"
ARG0_DIR_RE = re.compile(r"codex-arg0[A-Za-z0-9]+")


def write_named_permission_config(codex_home: pathlib.Path, server_url: str) -> None:
    config = f"""
model = "mock-model"
model_provider = "mock_provider"
approval_policy = "on-request"
default_permissions = "{PROFILE_ID}"
suppress_unstable_features_warning = true

[model_providers.mock_provider]
name = "Mock provider for named permission profile test"
base_url = "{server_url}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false

[permissions.{PROFILE_ID}]
description = "Restrictive profile used by .chat validation"

[permissions.{PROFILE_ID}.workspace_roots]
"." = true
"docs" = true

[permissions.{PROFILE_ID}.filesystem]
glob_scan_max_depth = 2
":minimal" = "read"

[permissions.{PROFILE_ID}.filesystem.":workspace_roots"]
"docs/**" = "read"
"**/*.secret" = "deny"

[permissions.{PROFILE_ID}.network]
enabled = false

[permissions.{PROFILE_ID}.network.domains]
"allowed.example.com" = "allow"
"blocked.example.com" = "deny"
"""
    (codex_home / "config.toml").write_text(config)


def active_permission_profile_from_start(response: dict[str, Any]) -> dict[str, Any] | None:
    return (response.get("result") or {}).get("activePermissionProfile")


def active_permission_profile_from_read(response: dict[str, Any]) -> dict[str, Any] | None:
    thread = ((response.get("result") or {}).get("thread") or {})
    return thread.get("activePermissionProfile")


def permission_snapshot_markers(comparison: dict[str, Any]) -> dict[str, Any]:
    original_contexts = comparison.get("original_turn_contexts") or []
    chat_contexts = comparison.get("chat_journal_turn_contexts") or []
    original_payload = (
        original_contexts[0].get("normalized_payload") if original_contexts else {}
    )
    chat_payload = chat_contexts[0].get("normalized_payload") if chat_contexts else {}
    permission_profile = original_payload.get("permission_profile") or {}
    filesystem = (permission_profile.get("file_system") or {})
    filesystem_entries = filesystem.get("entries") or []
    serialized_profile = json.dumps(permission_profile, sort_keys=True)

    return {
        "original_workspace_roots": original_payload.get("workspace_roots"),
        "chat_workspace_roots": chat_payload.get("workspace_roots"),
        "workspace_roots_equal": original_payload.get("workspace_roots")
        == chat_payload.get("workspace_roots"),
        "workspace_roots_materialized": original_payload.get("workspace_roots")
        == ["<workspace>", "<workspace>/docs"],
        "permission_profile_type": permission_profile.get("type"),
        "permission_profile_network": permission_profile.get("network"),
        "filesystem_policy_type": filesystem.get("type"),
        "filesystem_entry_count": len(filesystem_entries),
        "contains_minimal_read": '"kind": "minimal"' in serialized_profile,
        "contains_docs_permission": "docs" in serialized_profile,
        "contains_secret_deny": "*.secret" in serialized_profile,
        "contains_network_restricted": permission_profile.get("network") == "restricted",
    }


def normalize_arg0_runtime_dir(value: Any) -> Any:
    if isinstance(value, str):
        return ARG0_DIR_RE.sub("codex-arg0<runtime>", value)
    if isinstance(value, list):
        return [normalize_arg0_runtime_dir(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize_arg0_runtime_dir(nested) for key, nested in value.items()}
    return value


def normalize_dynamic_permission_comparison(comparison: dict[str, Any]) -> dict[str, Any]:
    normalized = normalize_arg0_runtime_dir(json.loads(json.dumps(comparison)))
    original_payloads = [
        item.get("normalized_payload")
        for item in normalized.get("original_turn_contexts") or []
    ]
    chat_payloads = [
        item.get("normalized_payload")
        for item in normalized.get("chat_journal_turn_contexts") or []
    ]
    normalized["normalized_payloads_equal"] = original_payloads == chat_payloads
    return normalized


def run_named_profile_tree(
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
    (workspace / "docs").mkdir(parents=True, exist_ok=True)
    (workspace / "docs" / "visible.txt").write_text("docs are readable\n")
    (workspace / "private.secret").write_text("secret marker\n")

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_named_permission_config(codex_home, mock_server.url)
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
                        "clientUserMessageId": "client-user-message-named-permission-profile",
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
            "app-server-named-permission-profile-smoke-"
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
    original_result = run_named_profile_tree(
        "original",
        ORIGINAL_CODEX_RS,
        run_root,
        config_overrides=[],
    )
    chat_result = run_named_profile_tree(
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
    markers = permission_snapshot_markers(comparison)
    original_lines = original_result["original_storage_summary"]["rollouts"][0]["line_count"]
    chat_lines = chat_result["chat_package_summary"]["packages"][0]["journal_line_count"]
    original_active_start = original_result["active_permission_profile_start"] or {}
    chat_active_start = chat_result["active_permission_profile_start"] or {}
    original_active_read = original_result["active_permission_profile_read"] or {}
    chat_active_read = chat_result["active_permission_profile_read"] or {}

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-named-permission-profile-smoke",
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
            "codex-rs/config/src/config_toml.rs",
            "codex-rs/config/src/permissions_toml.rs",
            "codex-rs/core/src/config/permissions.rs",
            "codex-rs/core/src/config/resolved_permission_profile.rs",
            "codex-rs/core/src/config/mod.rs",
            "codex-rs/core/src/session/turn_context.rs",
            "codex-rs/protocol/src/protocol.rs",
        ],
        "binary_checks": binary_checks,
        "expected_profile_id": PROFILE_ID,
        "original_active_permission_profile_start": original_active_start,
        "chat_active_permission_profile_start": chat_active_start,
        "original_active_permission_profile_read": original_active_read,
        "chat_active_permission_profile_read": chat_active_read,
        "active_permission_profile_start_equal": original_active_start
        == chat_active_start,
        "active_permission_profile_read_equal": original_active_read == chat_active_read,
        "active_permission_profile_start_id_matches": original_active_start.get("id")
        == PROFILE_ID
        and chat_active_start.get("id") == PROFILE_ID,
        "normalized_thread_start_equal": original_result["normalized_thread_start"]
        == chat_result["normalized_thread_start"],
        "normalized_thread_read_equal": original_result["normalized_thread_read"]
        == chat_result["normalized_thread_read"],
        "normalized_thread_list_equal": original_result["normalized_thread_list"]
        == chat_result["normalized_thread_list"],
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_lines,
        "line_counts_equal": original_lines == chat_lines,
        **comparison,
        "permission_snapshot_markers": markers,
        "named_profile_policy_markers_present": all(
            [
                markers["contains_minimal_read"],
                markers["workspace_roots_equal"],
                markers["workspace_roots_materialized"],
                markers["contains_docs_permission"],
                markers["contains_secret_deny"],
                markers["contains_network_restricted"],
            ]
        ),
        "not_yet_proven": [
            "requirements.toml forced permission fallback variants",
            "managed cloud permission profile constraints",
            "all possible deny-read glob materialization variants",
            "complete environment snapshot parity across every configuration variant",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/named-permission-profile-response.json", original_result)
    write_json(output_dir / "chat-backend/named-permission-profile-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Named Permission Profile Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex `.chat` backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path for the original
backend and the `.chat` backend with a restrictive named `default_permissions`
profile.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and current data-fidelity JSON were read. The relevant Codex permission/profile
and turn-context source files listed in `summary.json` were also read.

## Scope

This smoke covers the named permission-profile path, not only legacy
`sandbox_mode`. The fixture profile declares workspace roots, a restricted
filesystem policy with `:minimal`, `:workspace_roots/docs/**`, a deny-read
`**/*.secret` glob, and restricted network access.

It compares original rollout `turn_context.payload` with the `.chat` journal
`source_transport.payload.payload`, normalizing only dynamic turn ids and
temporary run paths. It also checks that `.chat` timeline
`runtime_context_snapshot` events link back to the journal `turn_context`.

## Result

- active permission profile id expected: `{PROFILE_ID}`
- original and `.chat` active profile at `thread/start` equal: `{summary['active_permission_profile_start_equal']}`
- active profile id matches expected at `thread/start`: `{summary['active_permission_profile_start_id_matches']}`
- original and `.chat` active profile at `thread/read` equal: `{summary['active_permission_profile_read_equal']}`
- normalized `thread/start` equal: `{summary['normalized_thread_start_equal']}`
- normalized `thread/read` equal: `{summary['normalized_thread_read_equal']}`
- normalized `thread/list` equal: `{summary['normalized_thread_list_equal']}`
- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- turn context counts equal: `{summary['counts_equal']}`
- turn context field presence equal: `{summary['field_presence_equal']}`
- normalized turn context payloads equal: `{summary['normalized_payloads_equal']}`
- timeline snapshot links valid: `{summary['timeline_links_all_valid']}`
- named profile policy markers present: `{summary['named_profile_policy_markers_present']}`

## Permission Snapshot Markers

```json
{json.dumps(markers, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/named-permission-profile-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/named-permission-profile-response.json
```

## Not Yet Proven

This smoke does not prove requirements.toml forced permission fallback variants,
managed cloud permission profile constraints, all deny-read glob materialization
variants, complete environment snapshot parity across every configuration
variant, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    ok = (
        summary["active_permission_profile_start_equal"]
        and summary["active_permission_profile_start_id_matches"]
        and summary["active_permission_profile_read_equal"]
        and summary["normalized_thread_start_equal"]
        and summary["normalized_thread_read_equal"]
        and summary["normalized_thread_list_equal"]
        and summary["line_counts_equal"]
        and summary["counts_equal"]
        and summary["field_presence_equal"]
        and summary["normalized_payloads_equal"]
        and summary["timeline_links_all_valid"]
        and summary["named_profile_policy_markers_present"]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
