#!/usr/bin/env python3
"""Run lifecycle crash-repair app-server parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend. The
`.chat` run injects two crash-like lifecycle inconsistencies between
`manifest.json` and `indexes/thread-metadata.json`:

- manifest archived, derived index active;
- manifest active, derived index archived.

The manifest represents package-level lifecycle truth; the index is derived and
repairable. The smoke proves user-visible list/search/read behavior follows the
same normalized oracle as the original backend and that `thread/read` repairs
the stale index.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    normalize_thread_list_response,
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    SEARCH_TERM,
    normalize_archive_notification,
    normalize_thread_search_response,
    send_thread_archive,
    send_thread_list,
    send_thread_search,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    normalize_thread_response,
    send_initialize,
    send_thread_read,
    send_thread_start,
    send_turn_start,
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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/archive_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/unarchive_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/delete_thread.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_list_search_archive_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_index_repair_smoke.py",
]


def read_chat_index(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {}
    index_path = chat_root / f"{thread_id}.chat" / "indexes/thread-metadata.json"
    if not index_path.exists():
        return {"exists": False, "path": str(index_path)}
    data = json.loads(index_path.read_text())
    return {
        "exists": True,
        "path": str(index_path),
        "thread_id": data.get("thread_id"),
        "archived_at": data.get("archived_at"),
        "rollout_path": data.get("rollout_path"),
        "preview": data.get("preview"),
    }


def read_chat_manifest(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {}
    manifest_path = chat_root / f"{thread_id}.chat" / "manifest.json"
    if not manifest_path.exists():
        return {"exists": False, "path": str(manifest_path)}
    data = json.loads(manifest_path.read_text())
    lifecycle = data.get("lifecycle") or {}
    return {
        "exists": True,
        "path": str(manifest_path),
        "archived": lifecycle.get("archived"),
        "archived_at": lifecycle.get("archived_at"),
        "updated_at": data.get("updated_at"),
    }


def force_index_active(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {"mutated": False, "reason": "missing thread id"}
    index_path = chat_root / f"{thread_id}.chat" / "indexes/thread-metadata.json"
    before = read_chat_index(chat_root, thread_id)
    data = json.loads(index_path.read_text())
    data["archived_at"] = None
    index_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return {
        "mutated": True,
        "mutation": "index_archived_at_to_null",
        "before": before,
        "after": read_chat_index(chat_root, thread_id),
        "manifest": read_chat_manifest(chat_root, thread_id),
    }


def force_index_archived(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {"mutated": False, "reason": "missing thread id"}
    index_path = chat_root / f"{thread_id}.chat" / "indexes/thread-metadata.json"
    before = read_chat_index(chat_root, thread_id)
    data = json.loads(index_path.read_text())
    data["archived_at"] = "2099-01-01T00:00:00Z"
    index_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return {
        "mutated": True,
        "mutation": "index_archived_at_to_future_timestamp",
        "before": before,
        "after": read_chat_index(chat_root, thread_id),
        "manifest": read_chat_manifest(chat_root, thread_id),
    }


def chat_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("journal_line_count")


def original_rollout_line_count(summary: dict[str, Any]) -> int | None:
    rollouts = summary.get("rollouts") or []
    if len(rollouts) != 1:
        return None
    return rollouts[0].get("line_count")


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    scenario: str,
) -> dict[str, Any]:
    codex_bin = codex_rs / "target/debug/codex"
    workspace = run_root / tree_name / scenario / "workspace"
    codex_home = run_root / tree_name / scenario / "codex-home"
    chat_root = run_root / tree_name / scenario / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        stderr = ""
        try:
            initialize_response = send_initialize(client, 1)
            thread_id, thread_start_response = send_thread_start(client, 2, workspace)
            turn_start_response = send_turn_start(client, 3, thread_id)
            turn_started_notification = client.receive_until_method(
                "turn/started", timeout_seconds=30
            )
            turn_completed_notification = client.receive_until_method(
                "turn/completed", timeout_seconds=60
            )

            archive_response = None
            archive_notification = None
            if scenario == "manifest_archived_index_active":
                archive_response = send_thread_archive(client, 10, thread_id)
                archive_notification = client.receive_until_method(
                    "thread/archived", timeout_seconds=30
                )

            storage_before_mutation = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            mutation = {"mutated": False, "note": "original backend remains oracle"}
            if tree_name == "chat-backend":
                if scenario == "manifest_archived_index_active":
                    mutation = force_index_active(chat_root, thread_id)
                elif scenario == "manifest_active_index_archived":
                    mutation = force_index_archived(chat_root, thread_id)
                else:
                    raise ValueError(f"unknown scenario: {scenario}")

            active_list_response = send_thread_list(client, 20, archived=False)
            archived_list_response = send_thread_list(client, 21, archived=True)
            active_search_response = send_thread_search(client, 22, archived=False)
            archived_search_response = send_thread_search(client, 23, archived=True)
            read_response = send_thread_read(client, 24, thread_id)
            storage_after_repair = (
                summarize_chat_packages(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            repaired_index = (
                read_chat_index(chat_root, thread_id)
                if tree_name == "chat-backend"
                else {}
            )
            repaired_manifest = (
                read_chat_manifest(chat_root, thread_id)
                if tree_name == "chat-backend"
                else {}
            )
        finally:
            stderr = client.close()

    return {
        "tree": tree_name,
        "scenario": scenario,
        "command": client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "thread_id": thread_id,
        "mock_server_summary": mock_server.summary(),
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_started_notification": turn_started_notification,
        "turn_completed_notification": turn_completed_notification,
        "archive_response": archive_response,
        "archive_notification": archive_notification,
        "storage_before_mutation": storage_before_mutation,
        "mutation": mutation,
        "active_list_response": active_list_response,
        "archived_list_response": archived_list_response,
        "active_search_response": active_search_response,
        "archived_search_response": archived_search_response,
        "read_response": read_response,
        "storage_after_repair": storage_after_repair,
        "repaired_index": repaired_index,
        "repaired_manifest": repaired_manifest,
        "normalized_archive_notification": normalize_archive_notification(
            archive_notification, thread_id
        )
        if archive_notification is not None
        else None,
        "normalized_active_list": normalize_thread_list_response(
            active_list_response, thread_id
        ),
        "normalized_archived_list": normalize_thread_list_response(
            archived_list_response, thread_id
        ),
        "normalized_active_search": normalize_thread_search_response(
            active_search_response, thread_id
        ),
        "normalized_archived_search": normalize_thread_search_response(
            archived_search_response, thread_id
        ),
        "normalized_read": normalize_thread_response(read_response, thread_id),
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def scenario_matches(original: dict[str, Any], chat: dict[str, Any]) -> dict[str, bool]:
    keys = [
        "normalized_active_list",
        "normalized_archived_list",
        "normalized_active_search",
        "normalized_archived_search",
        "normalized_read",
    ]
    return {key: original[key] == chat[key] for key in keys}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-lifecycle-crash-repair-smoke-"
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
    chat_store_root = run_root / "chat-backend" / "{scenario}" / "chat-store"
    scenarios = [
        "manifest_archived_index_active",
        "manifest_active_index_archived",
    ]
    scenario_results: dict[str, dict[str, Any]] = {}

    for scenario in scenarios:
        original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [], scenario)
        chat_result = run_tree(
            "chat-backend",
            CHAT_BACKEND_CODEX_RS,
            run_root,
            [
                "experimental_thread_store={ type = \"chat\", root = \""
                + str(chat_store_root).format(scenario=scenario)
                + "\" }",
            ],
            scenario,
        )
        comparisons = scenario_matches(original_result, chat_result)
        original_lines = original_rollout_line_count(
            original_result["storage_after_repair"]
        )
        chat_lines = chat_journal_line_count(chat_result["storage_after_repair"])
        if scenario == "manifest_archived_index_active":
            repaired_lifecycle_ok = (
                chat_result["repaired_manifest"].get("archived") is True
                and chat_result["repaired_index"].get("archived_at") is not None
            )
        else:
            repaired_lifecycle_ok = (
                chat_result["repaired_manifest"].get("archived") is False
                and chat_result["repaired_index"].get("archived_at") is None
            )
        scenario_results[scenario] = {
            "comparisons": comparisons,
            "all_normalized_comparisons_equal": all(comparisons.values()),
            "chat_backend_mutation_applied": chat_result["mutation"].get("mutated")
            is True,
            "repaired_lifecycle_ok": repaired_lifecycle_ok,
            "journal_line_count_matches_original": original_lines is not None
            and original_lines == chat_lines,
            "original_rollout_lines": original_lines,
            "chat_journal_lines": chat_lines,
            "original": {
                "active_list": original_result["normalized_active_list"],
                "archived_list": original_result["normalized_archived_list"],
                "active_search": original_result["normalized_active_search"],
                "archived_search": original_result["normalized_archived_search"],
                "read": original_result["normalized_read"],
            },
            "chat_backend": {
                "active_list": chat_result["normalized_active_list"],
                "archived_list": chat_result["normalized_archived_list"],
                "active_search": chat_result["normalized_active_search"],
                "archived_search": chat_result["normalized_archived_search"],
                "read": chat_result["normalized_read"],
                "mutation": chat_result["mutation"],
                "repaired_index": chat_result["repaired_index"],
                "repaired_manifest": chat_result["repaired_manifest"],
            },
        }
        write_json(
            output_dir / f"original/{scenario}-response.json",
            original_result,
        )
        write_json(
            output_dir / f"chat-backend/{scenario}-response.json",
            chat_result,
        )

    success = all(
        result["all_normalized_comparisons_equal"]
        and result["chat_backend_mutation_applied"]
        and result["repaired_lifecycle_ok"]
        and result["journal_line_count_matches_original"]
        for result in scenario_results.values()
    )
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-lifecycle-crash-repair-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "search_term": SEARCH_TERM,
        "scenarios": scenario_results,
        "all_scenarios_passed": success,
        "proved": [
            "when manifest is archived but metadata index is active, .chat list/search/read match original archived behavior",
            "thread/read repairs the derived index back to manifest archived lifecycle state",
            "when manifest is active but metadata index is archived, .chat list/search/read match original active behavior",
            "thread/read repairs the derived index back to manifest active lifecycle state",
            "journal line count still matches original rollout line count in both crash-like lifecycle mismatch scenarios",
        ],
        "not_yet_proven": [
            "true process kill at every filesystem operation boundary",
            "delete crash after partially removed package directories",
            "cold .chat.cold lifecycle crash transition",
            "background cold-history compression worker",
            "CLI-level lifecycle crash user-indistinguishability",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Lifecycle Crash Repair Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, public spec
drafts, vendor manifest, baseline checks, backend mapping, parity matrix, and
current progress/data-fidelity reports were read. Relevant `.chat` lifecycle
backend source and existing app-server lifecycle/stale-index tests were also
read.

## Scope

This smoke covers two crash-like lifecycle mismatch states:

```text
manifest archived, derived metadata index active
manifest active, derived metadata index archived
```

It proves only a narrow H06/L05/L06/L08-adjacent repair slice. It does not
prove true process kill at every filesystem boundary, partial directory delete
recovery, `.chat.cold/` lifecycle crash transition, CLI-level
indistinguishability, complete data fidelity, or final user-indistinguishability.

## Result

- all scenarios passed: `{summary['all_scenarios_passed']}`

## Scenarios

```json
{json.dumps(scenario_results, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/manifest_archived_index_active-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/manifest_archived_index_active-response.json
{output_dir.relative_to(VALIDATION_DIR)}/original/manifest_active_index_archived-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/manifest_active_index_archived-response.json
```

## Not Yet Proven

This smoke does not prove true process kill at every lifecycle filesystem
operation boundary, partial package-directory delete recovery, cold
representation lifecycle crash transition, background compression,
CLI-level lifecycle parity, complete data fidelity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
