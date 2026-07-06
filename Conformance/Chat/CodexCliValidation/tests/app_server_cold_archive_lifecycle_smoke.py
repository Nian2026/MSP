#!/usr/bin/env python3
"""Run cold-package archive/unarchive app-server parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend. The
`.chat` run moves a durable package to `<thread-id>.chat.cold/`, then archives
and unarchives it through the app-server API to prove the cold representation
does not create a user-visible lifecycle difference.
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

from app_server_cold_package_smoke import (  # noqa: E402
    ASSISTANT_TEXT,
    FIRST_USER_TEXT,
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    MockResponsesServer,
    cold_only_not_materialized,
    deleted_all_representations,
    materialized_plain_only,
    move_plain_to_cold,
    normalize_delete_notification,
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    original_line_count,
    send_initialize,
    send_thread_delete,
    send_thread_read,
    send_thread_start,
    send_turn_start,
    summarize_chat_representations,
    summarize_mock_requests,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    ensure_binary,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    normalize_archive_notification,
    normalize_delete_error,
    normalize_empty_response,
    send_thread_archive,
    send_thread_unarchive,
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
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/app-server/src/request_processors/thread_processor.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_list_search_archive_smoke.py",
]


def send_thread_list(
    client: JsonRpcClient,
    request_id: int,
    archived: bool,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": {
                "limit": 10,
                "modelProviders": [],
                "archived": archived,
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def send_thread_search(
    client: JsonRpcClient,
    request_id: int,
    archived: bool,
) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/search",
            "params": {
                "limit": 10,
                "archived": archived,
                "searchTerm": "cold package validation",
            },
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def package_lifecycle_state(
    summary: dict[str, Any],
    expected_archived: bool,
) -> bool:
    packages = (summary.get("plain_packages") or []) + (summary.get("cold_packages") or [])
    if len(packages) != 1:
        return False
    lifecycle = packages[0].get("manifest_lifecycle") or {}
    archived_at = packages[0].get("manifest_archived_at")
    if "archived" in lifecycle:
        return lifecycle.get("archived") is expected_archived
    return (archived_at is not None) is expected_archived


def summarize_chat_representations_with_lifecycle(
    chat_root: pathlib.Path,
) -> dict[str, Any]:
    summary = summarize_chat_representations(chat_root)
    packages = (summary.get("plain_packages") or []) + (summary.get("cold_packages") or [])
    for package in packages:
        manifest_path = pathlib.Path(package["package"]) / "manifest.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        package["manifest_lifecycle"] = manifest.get("lifecycle")
        package["manifest_archived_at"] = manifest.get("archived_at")
    return summary


def chat_active_journal_line_count(summary: dict[str, Any]) -> int | None:
    packages = summary.get("plain_packages") or summary.get("cold_packages") or []
    if len(packages) != 1:
        return None
    return packages[0].get("journal_line_count")


def receive_thread_deleted_optional(
    client: JsonRpcClient,
    thread_id: str | None,
) -> dict[str, Any] | None:
    for message in client.received:
        if message.get("method") != "thread/deleted":
            continue
        params = message.get("params") or {}
        if thread_id is None or params.get("threadId") == thread_id:
            return message
    try:
        return client.receive_until_method("thread/deleted", timeout_seconds=5)
    except TimeoutError:
        return None


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

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)

        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client, 2, workspace
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-cold-archive-1",
                FIRST_USER_TEXT,
            )
            first_read_response = send_thread_read(first_client, 4, thread_id)
        finally:
            first_stderr = first_client.close()

        storage_after_first_turn = (
            summarize_chat_representations_with_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        cold_move = (
            move_plain_to_cold(chat_root, thread_id)
            if tree_name == "chat-backend"
            else {"moved": False, "note": "original backend remains oracle"}
        )
        storage_after_cold_move = (
            summarize_chat_representations_with_lifecycle(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            archive_response = send_thread_archive(second_client, 102, thread_id)
            archive_notification = second_client.receive_until_method(
                "thread/archived", timeout_seconds=30
            )
            active_list_after_archive_response = send_thread_list(
                second_client, 103, archived=False
            )
            archived_list_after_archive_response = send_thread_list(
                second_client, 104, archived=True
            )
            active_search_after_archive_response = send_thread_search(
                second_client, 105, archived=False
            )
            archived_search_after_archive_response = send_thread_search(
                second_client, 106, archived=True
            )
            storage_after_archive = (
                summarize_chat_representations_with_lifecycle(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            unarchive_response = send_thread_unarchive(second_client, 107, thread_id)
            unarchive_notification = second_client.receive_until_method(
                "thread/unarchived", timeout_seconds=30
            )
            active_list_after_unarchive_response = send_thread_list(
                second_client, 108, archived=False
            )
            archived_list_after_unarchive_response = send_thread_list(
                second_client, 109, archived=True
            )
            read_after_unarchive_response = send_thread_read(second_client, 110, thread_id)
            storage_after_unarchive = (
                summarize_chat_representations_with_lifecycle(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            delete_response = send_thread_delete(second_client, 111, thread_id)
            delete_notification = receive_thread_deleted_optional(second_client, thread_id)
            read_after_delete_response = send_thread_read(second_client, 112, thread_id)
            active_list_after_delete_response = send_thread_list(
                second_client, 113, archived=False
            )
            archived_list_after_delete_response = send_thread_list(
                second_client, 114, archived=True
            )
            storage_after_delete = (
                summarize_chat_representations_with_lifecycle(chat_root)
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
            "archive_response": archive_response,
            "archive_notification": archive_notification,
            "active_list_after_archive_response": active_list_after_archive_response,
            "archived_list_after_archive_response": archived_list_after_archive_response,
            "active_search_after_archive_response": active_search_after_archive_response,
            "archived_search_after_archive_response": archived_search_after_archive_response,
            "unarchive_response": unarchive_response,
            "unarchive_notification": unarchive_notification,
            "active_list_after_unarchive_response": active_list_after_unarchive_response,
            "archived_list_after_unarchive_response": archived_list_after_unarchive_response,
            "read_after_unarchive_response": read_after_unarchive_response,
            "delete_response": delete_response,
            "delete_notification": delete_notification,
            "read_after_delete_response": read_after_delete_response,
            "active_list_after_delete_response": active_list_after_delete_response,
            "archived_list_after_delete_response": archived_list_after_delete_response,
            "stderr_tail": second_stderr[-6000:],
            "process_exit_code": second_client.process.returncode,
        },
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "storage_after_first_turn": storage_after_first_turn,
        "cold_move": cold_move,
        "storage_after_cold_move": storage_after_cold_move,
        "storage_after_archive": storage_after_archive,
        "storage_after_unarchive": storage_after_unarchive,
        "storage_after_delete": storage_after_delete,
        "normalized_archive_response": normalize_empty_response(archive_response),
        "normalized_archive_notification": normalize_archive_notification(
            archive_notification, thread_id
        ),
        "normalized_active_list_after_archive": normalize_thread_list_response(
            active_list_after_archive_response, thread_id
        ),
        "normalized_archived_list_after_archive": normalize_thread_list_response(
            archived_list_after_archive_response, thread_id
        ),
        "normalized_active_search_after_archive": normalize_thread_search_response(
            active_search_after_archive_response, thread_id
        ),
        "normalized_archived_search_after_archive": normalize_thread_search_response(
            archived_search_after_archive_response, thread_id
        ),
        "normalized_unarchive_response": normalize_thread_response(
            unarchive_response, thread_id
        ),
        "normalized_unarchive_notification": normalize_archive_notification(
            unarchive_notification, thread_id
        ),
        "normalized_active_list_after_unarchive": normalize_thread_list_response(
            active_list_after_unarchive_response, thread_id
        ),
        "normalized_archived_list_after_unarchive": normalize_thread_list_response(
            archived_list_after_unarchive_response, thread_id
        ),
        "normalized_read_after_unarchive": normalize_thread_response(
            read_after_unarchive_response, thread_id
        ),
        "normalized_delete_response": normalize_empty_response(delete_response),
        "normalized_delete_notification": normalize_delete_notification(
            delete_notification, thread_id
        ),
        "normalized_read_after_delete_error": normalize_delete_error(
            read_after_delete_response
        ),
        "normalized_active_list_after_delete": normalize_thread_list_response(
            active_list_after_delete_response, thread_id
        ),
        "normalized_archived_list_after_delete": normalize_thread_list_response(
            archived_list_after_delete_response, thread_id
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-cold-archive-lifecycle-smoke-"
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}',
        ],
    )

    comparison_keys = [
        "normalized_archive_response",
        "normalized_archive_notification",
        "normalized_active_list_after_archive",
        "normalized_archived_list_after_archive",
        "normalized_active_search_after_archive",
        "normalized_archived_search_after_archive",
        "normalized_unarchive_response",
        "normalized_unarchive_notification",
        "normalized_active_list_after_unarchive",
        "normalized_archived_list_after_unarchive",
        "normalized_read_after_unarchive",
        "normalized_delete_response",
        "normalized_delete_notification",
        "normalized_read_after_delete_error",
        "normalized_active_list_after_delete",
        "normalized_archived_list_after_delete",
    ]
    comparisons = {
        key: original_result[key] == chat_result[key] for key in comparison_keys
    }

    original_first_lines = original_line_count(original_result["storage_after_first_turn"])
    chat_after_archive_lines = chat_active_journal_line_count(
        chat_result["storage_after_archive"]
    )
    original_post_delete_rollouts = (
        original_result["storage_after_delete"].get("rollout_files") or []
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-archive-lifecycle-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "comparisons": comparisons,
        "all_normalized_comparisons_equal": all(comparisons.values()),
        "chat_backend_cold_move_succeeded": chat_result["cold_move"].get("moved")
        is True,
        "cold_only_after_move": cold_only_not_materialized(
            chat_result["storage_after_cold_move"]
        ),
        "archive_materialized_to_plain": materialized_plain_only(
            chat_result["storage_after_archive"]
        ),
        "unarchive_kept_plain_materialized": materialized_plain_only(
            chat_result["storage_after_unarchive"]
        ),
        "delete_removed_representations": deleted_all_representations(
            chat_result["storage_after_delete"]
        ),
        "chat_package_post_archive_archived": package_lifecycle_state(
            chat_result["storage_after_archive"], expected_archived=True
        ),
        "chat_package_post_unarchive_active": package_lifecycle_state(
            chat_result["storage_after_unarchive"], expected_archived=False
        ),
        "journal_line_count_matches_original_after_archive": original_first_lines
        is not None
        and original_first_lines == chat_after_archive_lines,
        "original_rollout_line_count_before_delete": original_first_lines,
        "chat_journal_line_count_after_archive": chat_after_archive_lines,
        "original_rollout_removed_after_delete": len(original_post_delete_rollouts)
        == 0,
        "original": {
            key: original_result[key] for key in comparison_keys
        },
        "chat_backend": {
            key: chat_result[key] for key in comparison_keys
        },
        "chat_backend_storage": {
            "after_cold_move": chat_result["storage_after_cold_move"],
            "after_archive": chat_result["storage_after_archive"],
            "after_unarchive": chat_result["storage_after_unarchive"],
            "after_delete": chat_result["storage_after_delete"],
        },
        "proved": [
            "thread/archive on a cold-only .chat package returns the same normalized app-server behavior as original archive",
            "thread/archive materializes .chat.cold/ to .chat/ before lifecycle mutation",
            "archived list/search include the archived thread while active list/search hide it",
            "thread/unarchive returns the same normalized app-server behavior as original unarchive",
            "unarchive keeps the package in plain .chat/ representation and clears lifecycle archived state",
            "thread/read after unarchive preserves the durable user/assistant transcript",
            "thread/delete removes the materialized package and future read/list behavior matches original",
            "journal line count after cold archive matches original rollout line count for the durable source turn",
        ],
        "not_yet_proven": [
            "actual compressed single-file .chat container format",
            "background cold-history compression worker",
            "crash during cold archive/unarchive/delete transition",
            "CLI-level cold-history user-indistinguishability",
            "broader cold lifecycle paths beyond this cold-only archive/unarchive/delete slice",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }

    write_json(output_dir / "original/cold-archive-lifecycle-response.json", original_result)
    write_json(
        output_dir / "chat-backend/cold-archive-lifecycle-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Cold Archive Lifecycle Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, public spec
drafts, vendor manifest, baseline checks, backend mapping, parity matrix, and
current progress/data-fidelity reports were read. Relevant cold package and
app-server lifecycle source/test files were also read.

## Scope

This smoke covers one durable completed turn followed by:

```text
move <thread-id>.chat/ to <thread-id>.chat.cold/
thread/archive while cold-only
thread/list active/archived
thread/search active/archived
thread/unarchive
thread/list active/archived
thread/read
thread/delete
thread/read/list after delete
```

It proves only a narrow cold lifecycle slice crossing H01-H03 with L05/L06/L07.
It does not prove crash during lifecycle transitions, background compression, a
compressed container format, CLI-level indistinguishability, complete data
fidelity, or final user-indistinguishability.

## Result

- normalized original vs `.chat` comparisons all equal: `{summary['all_normalized_comparisons_equal']}`
- cold move succeeded: `{summary['chat_backend_cold_move_succeeded']}`
- cold-only after move: `{summary['cold_only_after_move']}`
- archive materialized to plain `.chat/`: `{summary['archive_materialized_to_plain']}`
- unarchive kept plain `.chat/`: `{summary['unarchive_kept_plain_materialized']}`
- post-archive lifecycle archived: `{summary['chat_package_post_archive_archived']}`
- post-unarchive lifecycle active: `{summary['chat_package_post_unarchive_active']}`
- delete removed representations: `{summary['delete_removed_representations']}`
- journal lines matched original rollout after archive: `{summary['journal_line_count_matches_original_after_archive']}`
- original rollout removed after delete: `{summary['original_rollout_removed_after_delete']}`

## Comparisons

```json
{json.dumps(comparisons, indent=2, sort_keys=True)}
```

## `.chat` Storage States

```json
{json.dumps(summary['chat_backend_storage'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cold-archive-lifecycle-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-archive-lifecycle-response.json
```

## Not Yet Proven

This smoke does not prove crash during cold lifecycle transitions, the final
compressed/single-file `.chat` container, background compression, CLI-level
cold-history parity, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_comparisons_equal"],
            summary["chat_backend_cold_move_succeeded"],
            summary["cold_only_after_move"],
            summary["archive_materialized_to_plain"],
            summary["unarchive_kept_plain_materialized"],
            summary["delete_removed_representations"],
            summary["chat_package_post_archive_archived"],
            summary["chat_package_post_unarchive_active"],
            summary["journal_line_count_matches_original_after_archive"],
            summary["original_rollout_removed_after_delete"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
