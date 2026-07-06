#!/usr/bin/env python3
"""Run partial-delete recovery app-server parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for both the original Codex backend and the adapted `.chat` backend. The `.chat`
run injects crash-like partial delete residues where only some package files
remain.

The smoke proves derived-only residues do not make a deleted thread visible
through read/list/search, journal-only residues can repair the package back to a
readable timeline, and a retried `thread/delete` clears the remaining package
directory.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
import shutil
import sys
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_package_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
    FIRST_USER_TEXT,
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    chat_active_journal_line_count,
    deleted_all_representations,
    ensure_binary,
    normalize_delete_notification,
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    original_line_count,
    plain_package_path,
    receive_thread_deleted_optional,
    send_initialize,
    send_thread_delete,
    send_thread_list,
    send_thread_read,
    send_thread_search,
    send_thread_start,
    send_turn_start,
    summarize_chat_representations,
    summarize_mock_requests,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    normalize_delete_error,
    normalize_empty_response,
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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/delete_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/list_threads.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/search_threads.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/app-server/src/request_processors/thread_delete.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_lifecycle_crash_repair_smoke.py",
]


RESIDUAL_KINDS = ("index-only", "manifest-only", "journal-only")


def codex_binary_for_tree(tree_name: str, codex_rs: pathlib.Path) -> pathlib.Path:
    env_name = "CHAT_BACKEND_CODEX_BIN" if tree_name == "chat-backend" else "ORIGINAL_CODEX_BIN"
    override = os.environ.get(env_name)
    if override:
        return pathlib.Path(override)
    return codex_rs / "target/debug/codex"


def ensure_tree_binary(
    tree_name: str,
    codex_rs: pathlib.Path,
    build_if_missing: bool,
) -> dict[str, Any]:
    env_name = "CHAT_BACKEND_CODEX_BIN" if tree_name == "chat-backend" else "ORIGINAL_CODEX_BIN"
    override = os.environ.get(env_name)
    if not override:
        return ensure_binary(codex_rs, build_if_missing)

    binary = pathlib.Path(override)
    if not binary.exists():
        raise RuntimeError(f"{env_name} points to missing binary: {binary}")
    return {
        "built": False,
        "artifact": str(binary),
        "artifact_exists": True,
        "artifact_size_bytes": binary.stat().st_size,
        "source": env_name,
    }


def make_partial_delete_residual(
    chat_root: pathlib.Path,
    thread_id: str | None,
    residual_kind: str,
) -> dict[str, Any]:
    package = plain_package_path(chat_root, thread_id)
    manifest_path = package / "manifest.json"
    journal_path = package / "journal.ndjson"
    index_path = package / "indexes/thread-metadata.json"
    before = summarize_chat_representations(chat_root)
    if thread_id is None:
        return {
            "mutated": False,
            "reason": "missing thread id",
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }
    if residual_kind not in RESIDUAL_KINDS:
        raise ValueError(f"unknown residual kind: {residual_kind}")
    if residual_kind == "index-only" and not index_path.exists():
        return {
            "mutated": False,
            "reason": "metadata index missing",
            "index_path": str(index_path),
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }
    if residual_kind == "manifest-only" and not manifest_path.exists():
        return {
            "mutated": False,
            "reason": "manifest missing",
            "manifest_path": str(manifest_path),
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }
    if residual_kind == "journal-only" and not journal_path.exists():
        return {
            "mutated": False,
            "reason": "journal missing",
            "journal_path": str(journal_path),
            "before": before,
            "after": summarize_chat_representations(chat_root),
        }

    index_data = json.loads(index_path.read_text()) if index_path.exists() else None
    manifest_data = manifest_path.read_text() if manifest_path.exists() else None
    journal_data = journal_path.read_text() if journal_path.exists() else None
    shutil.rmtree(package)
    package.mkdir(parents=True, exist_ok=True)
    if residual_kind == "index-only":
        (package / "indexes").mkdir(parents=True, exist_ok=True)
        index_path.write_text(json.dumps(index_data, indent=2, sort_keys=True) + "\n")
    elif residual_kind == "manifest-only":
        manifest_path.write_text(manifest_data or "")
    elif residual_kind == "journal-only":
        journal_path.write_text(journal_data or "")
    after = summarize_chat_representations(chat_root)
    return {
        "mutated": True,
        "mutation": f"left_{residual_kind}_partial_delete_residual",
        "residual_kind": residual_kind,
        "package": str(package),
        "manifest_path": str(manifest_path),
        "journal_path": str(journal_path),
        "index_path": str(index_path),
        "index_thread_id": (index_data or {}).get("thread_id"),
        "index_rollout_path": (index_data or {}).get("rollout_path"),
        "before": before,
        "after": after,
    }


def residual_has_shape(
    summary: dict[str, Any],
    *,
    manifest: bool,
    timeline: bool,
    journal: bool,
    index: bool,
) -> bool:
    packages = summary.get("plain_packages") or []
    if len(packages) != 1 or summary.get("cold_count") != 0:
        return False
    package = packages[0]
    return (
        package.get("manifest_exists") is manifest
        and package.get("timeline_exists") is timeline
        and package.get("journal_exists") is journal
        and package.get("index_exists") is index
    )


def run_tree(
    tree_name: str,
    codex_rs: pathlib.Path,
    run_root: pathlib.Path,
    config_overrides: list[str],
    residual_kind: str | None,
) -> dict[str, Any]:
    codex_bin = codex_binary_for_tree(tree_name, codex_rs)
    workspace = run_root / tree_name / "workspace"
    codex_home = run_root / tree_name / "codex-home"
    chat_root = run_root / tree_name / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(first_client, 2, workspace)
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-partial-delete-1",
                FIRST_USER_TEXT,
            )
            first_read_response = send_thread_read(first_client, 4, thread_id)
        finally:
            first_stderr = first_client.close()

        storage_after_first_turn = (
            summarize_chat_representations(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        residual_mutation = {"mutated": False, "note": "original backend remains oracle"}
        if residual_kind is not None:
            residual_mutation = make_partial_delete_residual(
                chat_root, thread_id, residual_kind
            )

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        pre_retry_read_response = None
        pre_retry_list_response = None
        pre_retry_search_response = None
        storage_after_pre_retry = None
        try:
            second_initialize_response = send_initialize(second_client, 101)
            if residual_kind is not None:
                pre_retry_read_response = send_thread_read(second_client, 102, thread_id)
                pre_retry_list_response = send_thread_list(second_client, 103)
                pre_retry_search_response = send_thread_search(second_client, 104)
                storage_after_pre_retry = summarize_chat_representations(chat_root)

            delete_response = send_thread_delete(second_client, 110, thread_id)
            delete_notification = receive_thread_deleted_optional(second_client, thread_id)
            read_after_delete_response = send_thread_read(second_client, 111, thread_id)
            list_after_delete_response = send_thread_list(second_client, 112)
            search_after_delete_response = send_thread_search(second_client, 113)
            storage_after_delete = (
                summarize_chat_representations(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
        finally:
            second_stderr = second_client.close()

    return {
        "tree": tree_name,
        "command": first_client.command,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "thread_id": thread_id,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "first_process": {
            "initialize_response": first_initialize_response,
            "thread_start_response": thread_start_response,
            "turn_start_response": first_turn_start_response,
            "thread_read_response": first_read_response,
            "stderr_tail": first_stderr[-6000:],
            "process_exit_code": first_client.process.returncode,
        },
        "second_process": {
            "initialize_response": second_initialize_response,
            "pre_retry_read_response": pre_retry_read_response,
            "pre_retry_list_response": pre_retry_list_response,
            "pre_retry_search_response": pre_retry_search_response,
            "delete_response": delete_response,
            "delete_notification": delete_notification,
            "read_after_delete_response": read_after_delete_response,
            "list_after_delete_response": list_after_delete_response,
            "search_after_delete_response": search_after_delete_response,
            "stderr_tail": second_stderr[-6000:],
            "process_exit_code": second_client.process.returncode,
        },
        "storage_after_first_turn": storage_after_first_turn,
        "residual_mutation": residual_mutation,
        "storage_after_pre_retry": storage_after_pre_retry,
        "storage_after_delete": storage_after_delete,
        "normalized_first_read": normalize_thread_response(first_read_response, thread_id),
        "normalized_pre_retry_read": normalize_thread_response(
            pre_retry_read_response or {}, thread_id
        ),
        "normalized_pre_retry_read_error": normalize_delete_error(pre_retry_read_response or {}),
        "normalized_pre_retry_list": normalize_thread_list_response(
            pre_retry_list_response or {}, thread_id
        ),
        "normalized_pre_retry_search": normalize_thread_search_response(
            pre_retry_search_response or {}, thread_id
        ),
        "normalized_delete_response": normalize_empty_response(delete_response),
        "normalized_delete_notification": normalize_delete_notification(
            delete_notification, thread_id
        ),
        "normalized_read_after_delete_error": normalize_delete_error(
            read_after_delete_response
        ),
        "normalized_list_after_delete": normalize_thread_list_response(
            list_after_delete_response, thread_id
        ),
        "normalized_search_after_delete": normalize_thread_search_response(
            search_after_delete_response, thread_id
        ),
    }


def analyze_scenario(
    residual_kind: str,
    original_result: dict[str, Any],
    chat_result: dict[str, Any],
) -> dict[str, Any]:
    comparison_keys = [
        "normalized_delete_response",
        "normalized_delete_notification",
        "normalized_read_after_delete_error",
        "normalized_list_after_delete",
        "normalized_search_after_delete",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }
    original_lines = original_line_count(original_result["storage_after_first_turn"])
    chat_lines = chat_active_journal_line_count(chat_result["storage_after_first_turn"])
    residual_summary = chat_result["residual_mutation"].get("after") or {}
    storage_after_pre_retry = chat_result.get("storage_after_pre_retry") or {}

    residual_shape_by_kind = {
        "index-only": residual_has_shape(
            residual_summary, manifest=False, timeline=False, journal=False, index=True
        ),
        "manifest-only": residual_has_shape(
            residual_summary, manifest=True, timeline=False, journal=False, index=False
        ),
        "journal-only": residual_has_shape(
            residual_summary, manifest=False, timeline=False, journal=True, index=False
        ),
    }
    hidden_before_retry = (
        chat_result["normalized_pre_retry_read_error"]
        == original_result["normalized_read_after_delete_error"]
        and chat_result["normalized_pre_retry_list"]["contains_started_thread"] is False
        and chat_result["normalized_pre_retry_search"]["contains_started_thread"] is False
    )
    recovered_before_retry = (
        chat_result["normalized_pre_retry_read"]["has_error"] is False
        and chat_result["normalized_pre_retry_read"]["thread_id_matches"] is True
        and chat_result["normalized_pre_retry_list"]["contains_started_thread"] is True
        and chat_result["normalized_pre_retry_search"]["contains_started_thread"] is True
        and residual_has_shape(
            storage_after_pre_retry,
            manifest=True,
            timeline=True,
            journal=True,
            index=True,
        )
    )
    expected_pre_retry_behavior = (
        recovered_before_retry
        if residual_kind == "journal-only"
        else hidden_before_retry
    )
    success = (
        all(comparisons.values())
        and chat_result["residual_mutation"].get("mutated") is True
        and residual_shape_by_kind[residual_kind]
        and expected_pre_retry_behavior
        and deleted_all_representations(chat_result["storage_after_delete"])
        and original_lines is not None
        and original_lines == chat_lines
    )
    return {
        "residual_kind": residual_kind,
        "comparisons": comparisons,
        "all_normalized_comparisons_equal": all(comparisons.values()),
        "residual_mutation_applied": chat_result["residual_mutation"].get("mutated")
        is True,
        "residual_shape_matches": residual_shape_by_kind[residual_kind],
        "pre_retry_hidden": hidden_before_retry,
        "pre_retry_recovered": recovered_before_retry,
        "expected_pre_retry_behavior": expected_pre_retry_behavior,
        "delete_retry_removed_residual": deleted_all_representations(
            chat_result["storage_after_delete"]
        ),
        "journal_line_count_matches_original_before_delete": original_lines is not None
        and original_lines == chat_lines,
        "original_rollout_line_count_before_delete": original_lines,
        "chat_journal_line_count_before_delete": chat_lines,
        "original": {key: original_result[key] for key in comparison_keys},
        "chat_backend": {key: chat_result[key] for key in comparison_keys}
        | {
            "pre_retry_read": chat_result["normalized_pre_retry_read"],
            "pre_retry_read_error": chat_result["normalized_pre_retry_read_error"],
            "pre_retry_list": chat_result["normalized_pre_retry_list"],
            "pre_retry_search": chat_result["normalized_pre_retry_search"],
            "residual_mutation": chat_result["residual_mutation"],
            "storage_after_pre_retry": storage_after_pre_retry,
            "storage_after_delete": chat_result["storage_after_delete"],
        },
        "all_checks_passed": success,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-partial-delete-recovery-smoke-"
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
        "original": ensure_tree_binary(
            "original", ORIGINAL_CODEX_RS, args.build_if_missing
        ),
        "chat-backend": ensure_tree_binary(
            "chat-backend", CHAT_BACKEND_CODEX_RS, args.build_if_missing
        ),
    }

    run_root = output_dir / "run"
    scenario_results = []
    for residual_kind in RESIDUAL_KINDS:
        scenario_root = run_root / residual_kind
        chat_store_root = scenario_root / "chat-backend" / "chat-store"
        original_result = run_tree(
            "original",
            ORIGINAL_CODEX_RS,
            scenario_root,
            [],
            residual_kind=None,
        )
        chat_result = run_tree(
            "chat-backend",
            CHAT_BACKEND_CODEX_RS,
            scenario_root,
            [
                f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
            ],
            residual_kind=residual_kind,
        )
        scenario = analyze_scenario(residual_kind, original_result, chat_result)
        scenario_results.append(scenario)
        write_json(
            output_dir / f"original/{residual_kind}-partial-delete-response.json",
            original_result,
        )
        write_json(
            output_dir / f"chat-backend/{residual_kind}-partial-delete-response.json",
            chat_result,
        )

    success = all(scenario["all_checks_passed"] for scenario in scenario_results)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-partial-delete-recovery-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "scenario_results": scenario_results,
        "all_normalized_comparisons_equal": all(
            scenario["all_normalized_comparisons_equal"]
            for scenario in scenario_results
        ),
        "chat_backend_residual_mutation_applied": all(
            scenario["residual_mutation_applied"] for scenario in scenario_results
        ),
        "chat_backend_residual_shapes_match": all(
            scenario["residual_shape_matches"] for scenario in scenario_results
        ),
        "chat_backend_derived_residuals_hidden": all(
            scenario["pre_retry_hidden"]
            for scenario in scenario_results
            if scenario["residual_kind"] != "journal-only"
        ),
        "chat_backend_journal_residual_repaired": next(
            scenario["pre_retry_recovered"]
            for scenario in scenario_results
            if scenario["residual_kind"] == "journal-only"
        ),
        "chat_backend_delete_retry_removed_residuals": all(
            scenario["delete_retry_removed_residual"] for scenario in scenario_results
        ),
        "journal_line_counts_match_original_before_delete": all(
            scenario["journal_line_count_matches_original_before_delete"]
            for scenario in scenario_results
        ),
        "proved": [
            "crash-like .chat packages with only derived metadata index or only manifest are not treated as canonical history",
            "pre-retry thread/read, thread/list, and thread/search do not expose derived-only residuals as live threads",
            "a crash-like .chat package with only journal.ndjson is repaired back to manifest, timeline, and metadata index before normal delete",
            "thread/delete retry removes every covered residual .chat package directory",
            "post-delete normalized thread/delete, thread/read, thread/list, and thread/search behavior matches the original backend for all covered residual shapes",
            "journal line counts before simulated partial delete match original rollout line counts",
        ],
        "not_yet_proven": [
            "true process kill at every delete filesystem operation boundary",
            "partial delete recovery for corrupt retained manifest or corrupt retained journal",
            "partial delete recovery for .chat.cold/ representation transitions",
            "CLI-level delete user-indistinguishability",
            "complete crash recovery",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
        "all_checks_passed": success,
    }
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Partial Delete Recovery Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, public spec
drafts, vendor manifest, baseline checks, backend mapping, parity matrix, and
current reports were read. Relevant original delete/list/search source and the
adapted `.chat` backend source were also read.

## Scope

This smoke covers a narrow H06/L07 partial-delete recovery slice:

```text
<thread-id>.chat/
  indexes/thread-metadata.json

<thread-id>.chat/
  manifest.json

<thread-id>.chat/
  journal.ndjson
```

The index-only and manifest-only packages are not recoverable canonical history
and must stay hidden from read/list/search until delete retry removes them. The
journal-only package is recoverable source transport for the Codex backend and
must be repaired into a normal `.chat` package with manifest, timeline, journal,
and metadata index before deletion.

## Result

- all checks passed: `{summary['all_checks_passed']}`
- all normalized post-delete comparisons equal: `{summary['all_normalized_comparisons_equal']}`
- residual mutations applied: `{summary['chat_backend_residual_mutation_applied']}`
- residual shapes matched expectations: `{summary['chat_backend_residual_shapes_match']}`
- derived-only residuals hidden from read/list/search: `{summary['chat_backend_derived_residuals_hidden']}`
- journal-only residual repaired before delete: `{summary['chat_backend_journal_residual_repaired']}`
- delete retry removed residuals: `{summary['chat_backend_delete_retry_removed_residuals']}`
- journal lines matched original before delete: `{summary['journal_line_counts_match_original_before_delete']}`

## Comparisons

```json
{json.dumps({scenario['residual_kind']: scenario['comparisons'] for scenario in scenario_results}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/*-partial-delete-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/*-partial-delete-response.json
```

## Not Yet Proven

This smoke does not prove true process kill at every delete filesystem boundary,
corrupt retained manifest/journal repair, `.chat.cold/`
representation crash transitions, CLI-level delete parity, complete crash
recovery, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
