#!/usr/bin/env python3
"""Run cold-package relation lifecycle parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend.

It covers the intersection that the ordinary relation lifecycle smoke and the
ordinary cold lifecycle smoke leave open:

- create a parent/child/grandchild relation graph through
  `multi_agent_v1.spawn_agent`;
- move child A and the grandchild to the internal `<thread-id>.chat.cold/`
  representation in the `.chat` backend only;
- cold-start a fresh app-server process and verify relation listing still
  matches the original backend;
- archive, unarchive, and delete the cold intermediate child, verifying that
  descendant relation behavior and package materialization/removal remain
  equivalent.

This does not prove background compression, crash during lifecycle transitions,
CLI/TUI cold relation surfaces, complete data fidelity, or final
user-indistinguishability.
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
    move_plain_to_cold,
)
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
from app_server_list_search_archive_smoke import (  # noqa: E402
    normalize_archive_notification,
    normalize_delete_error,
    normalize_empty_response,
    send_thread_archive,
    send_thread_delete,
    send_thread_unarchive,
)
from app_server_relation_lifecycle_smoke import (  # noqa: E402
    label_to_thread_id,
    labels_from_pair,
    normalize_relation_pair,
    package_state_by_label,
    send_relation_list,
    wait_for_relation_state,
)
from app_server_spawn_relation_smoke import (  # noqa: E402
    PARENT_TURN_1_PROMPT,
    PARENT_TURN_2_PROMPT,
    SpawnRelationResponsesServer,
    receive_thread_turn_completed,
    send_turn_start_with_text,
    wait_for_next_unix_second,
    wait_for_relation_counts,
    wait_for_relation_labels,
    write_spawn_mock_config,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_read,
    send_thread_start,
)
from app_server_cold_package_smoke import normalize_delete_notification  # noqa: E402


GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_relation_lifecycle_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_archive_lifecycle_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_spawn_relation_smoke.py",
]


def package_lifecycle_rows(chat_root: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for representation, pattern in [("plain", "*.chat"), ("cold", "*.chat.cold")]:
        for package in sorted(chat_root.glob(pattern)):
            manifest_path = package / "manifest.json"
            index_path = package / "indexes/thread-metadata.json"
            timeline_path = package / "timeline.ndjson"
            journal_path = package / "journal.ndjson"
            manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
            index = json.loads(index_path.read_text()) if index_path.exists() else {}
            rows.append(
                {
                    "representation": representation,
                    "package": package.name,
                    "thread_id": manifest.get("thread_id"),
                    "archived": manifest.get("archived_at") is not None,
                    "archived_at_present": manifest.get("archived_at") is not None,
                    "manifest_parent_thread_id": (
                        (manifest.get("create_params") or {}).get("parent_thread_id")
                    ),
                    "index_parent_thread_id": index.get("parent_thread_id"),
                    "index_archived_at_present": index.get("archived_at") is not None,
                    "index_exists": index_path.exists(),
                    "timeline_event_types": [
                        event.get("type") for event in read_json_lines(timeline_path)
                    ],
                    "journal_line_count": len(read_json_lines(journal_path)),
                }
            )
    return rows


def summarize_chat_cold_relation_storage(chat_root: pathlib.Path) -> dict[str, Any]:
    rows = package_lifecycle_rows(chat_root)
    return {
        "chat_root": str(chat_root),
        "plain_count": sum(1 for row in rows if row["representation"] == "plain"),
        "cold_count": sum(1 for row in rows if row["representation"] == "cold"),
        "package_count": len(rows),
        "lifecycle_packages": rows,
    }


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


def normalize_relation_pair_from_responses(
    direct: dict[str, Any],
    descendants: dict[str, Any],
    parent_thread_id: str | None,
) -> dict[str, Any]:
    return normalize_relation_pair(direct, descendants, parent_thread_id)


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
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            parent_thread_id, thread_start_response = send_thread_start(
                first_client,
                10,
                workspace,
            )

            turn_1_response = send_turn_start_with_text(
                first_client,
                20,
                parent_thread_id,
                PARENT_TURN_1_PROMPT,
            )
            parent_turn_1_completed = receive_thread_turn_completed(
                first_client,
                parent_thread_id,
            )
            wait_for_relation_counts(
                first_client,
                100,
                parent_thread_id,
                direct_count=1,
                descendant_count=2,
            )

            wait_for_next_unix_second()
            turn_2_response = send_turn_start_with_text(
                first_client,
                30,
                parent_thread_id,
                PARENT_TURN_2_PROMPT,
            )
            parent_turn_2_completed = receive_thread_turn_completed(
                first_client,
                parent_thread_id,
            )
            wait_for_relation_counts(
                first_client,
                200,
                parent_thread_id,
                direct_count=2,
                descendant_count=3,
            )
            direct_full, descendants_full = wait_for_relation_labels(
                first_client,
                240,
                parent_thread_id,
                expected_direct_labels=["child-b", "child-a"],
                expected_descendant_labels=["child-b", "grandchild", "child-a"],
            )
            id_by_label = {
                **label_to_thread_id(direct_full, parent_thread_id),
                **label_to_thread_id(descendants_full, parent_thread_id),
                "parent": parent_thread_id,
            }
        finally:
            first_stderr = first_client.close()

        storage_before_cold_move = (
            summarize_chat_cold_relation_storage(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )
        cold_moves = (
            {
                "child-a": move_plain_to_cold(chat_root, id_by_label["child-a"]),
                "grandchild": move_plain_to_cold(chat_root, id_by_label["grandchild"]),
            }
            if tree_name == "chat-backend"
            else {"note": "original backend remains oracle"}
        )
        storage_after_cold_move = (
            summarize_chat_cold_relation_storage(chat_root)
            if tree_name == "chat-backend"
            else summarize_original_storage(codex_home)
        )

        child_a_thread_id = id_by_label["child-a"]
        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 300)
            direct_after_cold_move, descendants_after_cold_move = wait_for_relation_state(
                second_client,
                320,
                parent_thread_id,
                archived=False,
                expected_direct_labels=["child-b", "child-a"],
                expected_descendant_labels=["child-b", "grandchild", "child-a"],
            )

            archive_child_a_response = send_thread_archive(
                second_client,
                400,
                child_a_thread_id,
            )
            archive_child_a_notification = second_client.receive_until_method(
                "thread/archived",
                timeout_seconds=30,
            )
            active_direct_after_archive, active_descendants_after_archive = (
                wait_for_relation_state(
                    second_client,
                    420,
                    parent_thread_id,
                    archived=False,
                    expected_direct_labels=["child-b"],
                    expected_descendant_labels=["child-b"],
                )
            )
            archived_direct_after_archive, archived_descendants_after_archive = (
                wait_for_relation_state(
                    second_client,
                    460,
                    parent_thread_id,
                    archived=True,
                    expected_direct_labels=["child-a"],
                    expected_descendant_labels=["grandchild", "child-a"],
                )
            )
            storage_after_archive = (
                summarize_chat_cold_relation_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            unarchive_child_a_response = send_thread_unarchive(
                second_client,
                500,
                child_a_thread_id,
            )
            unarchive_child_a_notification = second_client.receive_until_method(
                "thread/unarchived",
                timeout_seconds=30,
            )
            active_direct_after_unarchive, active_descendants_after_unarchive = (
                wait_for_relation_state(
                    second_client,
                    520,
                    parent_thread_id,
                    archived=False,
                    expected_direct_labels=["child-b", "child-a"],
                    expected_descendant_labels=["child-b", "child-a"],
                )
            )
            archived_direct_after_unarchive, archived_descendants_after_unarchive = (
                wait_for_relation_state(
                    second_client,
                    560,
                    parent_thread_id,
                    archived=True,
                    expected_direct_labels=[],
                    expected_descendant_labels=["grandchild"],
                )
            )
            storage_after_unarchive = (
                summarize_chat_cold_relation_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            delete_child_a_response = send_thread_delete(
                second_client,
                600,
                child_a_thread_id,
            )
            delete_child_a_notification = receive_thread_deleted_optional(
                second_client,
                child_a_thread_id,
            )
            active_direct_after_delete, active_descendants_after_delete = (
                wait_for_relation_state(
                    second_client,
                    620,
                    parent_thread_id,
                    archived=False,
                    expected_direct_labels=["child-b"],
                    expected_descendant_labels=["child-b"],
                )
            )
            archived_direct_after_delete, archived_descendants_after_delete = (
                wait_for_relation_state(
                    second_client,
                    660,
                    parent_thread_id,
                    archived=True,
                    expected_direct_labels=[],
                    expected_descendant_labels=[],
                )
            )
            read_child_a_after_delete = send_thread_read(
                second_client,
                700,
                child_a_thread_id,
            )
            storage_after_delete = (
                summarize_chat_cold_relation_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )
            server_summary = mock_server.summary()
        finally:
            second_stderr = second_client.close()

    result = {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "first_initialize_response": first_initialize_response,
        "second_initialize_response": second_initialize_response,
        "thread_start_response": thread_start_response,
        "parent_thread_id": parent_thread_id,
        "id_by_label": id_by_label,
        "turn_1_response": turn_1_response,
        "turn_2_response": turn_2_response,
        "parent_turn_1_completed": parent_turn_1_completed,
        "parent_turn_2_completed": parent_turn_2_completed,
        "direct_full": direct_full,
        "descendants_full": descendants_full,
        "direct_after_cold_move": direct_after_cold_move,
        "descendants_after_cold_move": descendants_after_cold_move,
        "archive_child_a_response": archive_child_a_response,
        "archive_child_a_notification": archive_child_a_notification,
        "active_direct_after_archive": active_direct_after_archive,
        "active_descendants_after_archive": active_descendants_after_archive,
        "archived_direct_after_archive": archived_direct_after_archive,
        "archived_descendants_after_archive": archived_descendants_after_archive,
        "unarchive_child_a_response": unarchive_child_a_response,
        "unarchive_child_a_notification": unarchive_child_a_notification,
        "active_direct_after_unarchive": active_direct_after_unarchive,
        "active_descendants_after_unarchive": active_descendants_after_unarchive,
        "archived_direct_after_unarchive": archived_direct_after_unarchive,
        "archived_descendants_after_unarchive": archived_descendants_after_unarchive,
        "delete_child_a_response": delete_child_a_response,
        "delete_child_a_notification": delete_child_a_notification,
        "active_direct_after_delete": active_direct_after_delete,
        "active_descendants_after_delete": active_descendants_after_delete,
        "archived_direct_after_delete": archived_direct_after_delete,
        "archived_descendants_after_delete": archived_descendants_after_delete,
        "read_child_a_after_delete": read_child_a_after_delete,
        "normalized_full": normalize_relation_pair_from_responses(
            direct_full,
            descendants_full,
            parent_thread_id,
        ),
        "normalized_after_cold_move_active": normalize_relation_pair_from_responses(
            direct_after_cold_move,
            descendants_after_cold_move,
            parent_thread_id,
        ),
        "normalized_after_archive_active": normalize_relation_pair_from_responses(
            active_direct_after_archive,
            active_descendants_after_archive,
            parent_thread_id,
        ),
        "normalized_after_archive_archived": normalize_relation_pair_from_responses(
            archived_direct_after_archive,
            archived_descendants_after_archive,
            parent_thread_id,
        ),
        "normalized_after_unarchive_active": normalize_relation_pair_from_responses(
            active_direct_after_unarchive,
            active_descendants_after_unarchive,
            parent_thread_id,
        ),
        "normalized_after_unarchive_archived": normalize_relation_pair_from_responses(
            archived_direct_after_unarchive,
            archived_descendants_after_unarchive,
            parent_thread_id,
        ),
        "normalized_after_delete_active": normalize_relation_pair_from_responses(
            active_direct_after_delete,
            active_descendants_after_delete,
            parent_thread_id,
        ),
        "normalized_after_delete_archived": normalize_relation_pair_from_responses(
            archived_direct_after_delete,
            archived_descendants_after_delete,
            parent_thread_id,
        ),
        "normalized_archive_response": normalize_empty_response(archive_child_a_response),
        "normalized_archive_notification": normalize_archive_notification(
            archive_child_a_notification,
            child_a_thread_id,
        ),
        "normalized_unarchive_response": normalize_empty_response(
            unarchive_child_a_response
        ),
        "normalized_unarchive_notification": normalize_archive_notification(
            unarchive_child_a_notification,
            child_a_thread_id,
        ),
        "normalized_delete_response": normalize_empty_response(delete_child_a_response),
        "normalized_delete_notification": normalize_delete_notification(
            delete_child_a_notification,
            child_a_thread_id,
        ),
        "normalized_read_child_a_after_delete_error": normalize_delete_error(
            read_child_a_after_delete
        ),
        "mock_server_summary": server_summary,
        "storage_before_cold_move": storage_before_cold_move,
        "cold_moves": cold_moves,
        "storage_after_cold_move": storage_after_cold_move,
        "storage_after_archive": storage_after_archive,
        "storage_after_unarchive": storage_after_unarchive,
        "storage_after_delete": storage_after_delete,
        "stderr_tail": {
            "first": first_stderr[-6000:],
            "second": second_stderr[-6000:],
        },
        "process_exit_codes": {
            "first": first_client.process.returncode,
            "second": second_client.process.returncode,
        },
    }
    if tree_name == "chat-backend":
        result["chat_package_state_by_label"] = {
            "before_cold_move": package_state_by_label(
                storage_before_cold_move,
                id_by_label,
            ),
            "after_cold_move": package_state_by_label(
                storage_after_cold_move,
                id_by_label,
            ),
            "after_archive": package_state_by_label(storage_after_archive, id_by_label),
            "after_unarchive": package_state_by_label(
                storage_after_unarchive,
                id_by_label,
            ),
            "after_delete": package_state_by_label(storage_after_delete, id_by_label),
        }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-cold-relation-lifecycle-smoke-"
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

    relation_keys = [
        "normalized_full",
        "normalized_after_cold_move_active",
        "normalized_after_archive_active",
        "normalized_after_archive_archived",
        "normalized_after_unarchive_active",
        "normalized_after_unarchive_archived",
        "normalized_after_delete_active",
        "normalized_after_delete_archived",
    ]
    lifecycle_keys = [
        "normalized_archive_response",
        "normalized_archive_notification",
        "normalized_unarchive_response",
        "normalized_unarchive_notification",
        "normalized_delete_response",
        "normalized_delete_notification",
        "normalized_read_child_a_after_delete_error",
    ]
    comparison_results = {
        key: original_result[key] == chat_result[key] for key in relation_keys + lifecycle_keys
    }

    expected_labels = {
        "normalized_full": {
            "direct": ["child-b", "child-a"],
            "descendants": ["child-b", "grandchild", "child-a"],
        },
        "normalized_after_cold_move_active": {
            "direct": ["child-b", "child-a"],
            "descendants": ["child-b", "grandchild", "child-a"],
        },
        "normalized_after_archive_active": {
            "direct": ["child-b"],
            "descendants": ["child-b"],
        },
        "normalized_after_archive_archived": {
            "direct": ["child-a"],
            "descendants": ["grandchild", "child-a"],
        },
        "normalized_after_unarchive_active": {
            "direct": ["child-b", "child-a"],
            "descendants": ["child-b", "child-a"],
        },
        "normalized_after_unarchive_archived": {
            "direct": [],
            "descendants": ["grandchild"],
        },
        "normalized_after_delete_active": {
            "direct": ["child-b"],
            "descendants": ["child-b"],
        },
        "normalized_after_delete_archived": {
            "direct": [],
            "descendants": [],
        },
    }
    original_labels_match_expected = {
        key: labels_from_pair(original_result[key]) == expected
        for key, expected in expected_labels.items()
    }
    chat_labels_match_expected = {
        key: labels_from_pair(chat_result[key]) == expected
        for key, expected in expected_labels.items()
    }
    chat_package_states = chat_result.get("chat_package_state_by_label") or {}
    after_cold_move = chat_package_states.get("after_cold_move") or {}
    after_archive = chat_package_states.get("after_archive") or {}
    after_unarchive = chat_package_states.get("after_unarchive") or {}
    after_delete = chat_package_states.get("after_delete") or {}
    child_a_after_cold = after_cold_move.get("child-a") or {}
    grandchild_after_cold = after_cold_move.get("grandchild") or {}
    child_a_after_archive = after_archive.get("child-a") or {}
    grandchild_after_archive = after_archive.get("grandchild") or {}
    child_a_after_unarchive = after_unarchive.get("child-a") or {}
    grandchild_after_unarchive = after_unarchive.get("grandchild") or {}
    child_b_after_delete = after_delete.get("child-b")

    cold_moves = chat_result["cold_moves"]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-cold-relation-lifecycle-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "comparison_results": comparison_results,
        "all_normalized_cold_relation_lifecycle_fields_equal": all(
            comparison_results.values()
        ),
        "original_labels_match_expected": original_labels_match_expected,
        "chat_backend_labels_match_expected": chat_labels_match_expected,
        "all_original_labels_match_expected": all(original_labels_match_expected.values()),
        "all_chat_backend_labels_match_expected": all(chat_labels_match_expected.values()),
        "chat_backend_cold_moves_succeeded": {
            label: move.get("moved") is True for label, move in cold_moves.items()
        },
        "chat_child_a_cold_after_move": child_a_after_cold.get("representation")
        == "cold",
        "chat_grandchild_cold_after_move": grandchild_after_cold.get("representation")
        == "cold",
        "chat_child_a_materialized_and_archived": (
            child_a_after_archive.get("representation") == "plain"
            and child_a_after_archive.get("archived") is True
        ),
        "chat_grandchild_materialized_and_archived": (
            grandchild_after_archive.get("representation") == "plain"
            and grandchild_after_archive.get("archived") is True
        ),
        "chat_child_a_active_after_unarchive": (
            child_a_after_unarchive.get("representation") == "plain"
            and child_a_after_unarchive.get("archived") is False
        ),
        "chat_grandchild_stays_archived_after_unarchive": (
            grandchild_after_unarchive.get("representation") == "plain"
            and grandchild_after_unarchive.get("archived") is True
        ),
        "chat_child_a_removed_after_delete": after_delete.get("child-a") is None,
        "chat_grandchild_removed_after_delete": after_delete.get("grandchild") is None,
        "chat_child_b_survives_delete": child_b_after_delete is not None,
        "chat_post_delete_package_count": chat_result["storage_after_delete"].get(
            "package_count"
        ),
        "original_post_delete_rollout_count": len(
            original_result["storage_after_delete"].get("rollout_files") or []
        ),
        "read_deleted_child_a_error_equal": comparison_results[
            "normalized_read_child_a_after_delete_error"
        ],
        "read_deleted_child_a_error_class": original_result[
            "normalized_read_child_a_after_delete_error"
        ]["message_class"],
        "original": {
            key: original_result[key] for key in relation_keys + lifecycle_keys
        },
        "chat_backend": {key: chat_result[key] for key in relation_keys + lifecycle_keys},
        "chat_backend_storage": {
            "before_cold_move": chat_result["storage_before_cold_move"],
            "after_cold_move": chat_result["storage_after_cold_move"],
            "after_archive": chat_result["storage_after_archive"],
            "after_unarchive": chat_result["storage_after_unarchive"],
            "after_delete": chat_result["storage_after_delete"],
        },
        "chat_package_state_by_label": chat_package_states,
        "mock_server_summaries": {
            "original": original_result["mock_server_summary"],
            "chat_backend": chat_result["mock_server_summary"],
        },
        "proved": [
            "cold-only child and grandchild packages remain discoverable through relation-filter listing after a fresh app-server process starts",
            "archiving a cold intermediate child matches original active/archived descendant lifecycle behavior",
            "archive materializes both the cold intermediate child and cold grandchild before recording lifecycle state",
            "unarchiving the intermediate child matches original behavior by keeping the grandchild archived",
            "deleting the intermediate child removes the child plus grandchild representations while preserving the unrelated child B package",
        ],
        "not_yet_proven": [
            "background cold-history compression worker",
            "crash during cold relation archive/unarchive/delete transitions",
            "CLI/TUI cold relation lifecycle surfaces",
            "arbitrary filesystem I/O failures",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }

    write_json(output_dir / "original/cold-relation-lifecycle-response.json", original_result)
    write_json(
        output_dir / "chat-backend/cold-relation-lifecycle-response.json",
        chat_result,
    )
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Cold Relation Lifecycle Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` gate note, spec files,
vendor manifest, baseline checks, parity matrix, existing relation/cold
lifecycle smokes, and relevant adapted thread-store source were read.

## Scope

```text
parent turn 1 -> multi_agent_v1.spawn_agent(child A)
child A -> multi_agent_v1.spawn_agent(grandchild)
parent turn 2 -> multi_agent_v1.spawn_agent(child B)
move child A .chat/ to .chat.cold/
move grandchild .chat/ to .chat.cold/
fresh app-server thread/list parentThreadId/ancestorThreadId active
thread/archive child A
thread/list parentThreadId/ancestorThreadId active and archived
thread/unarchive child A
thread/list parentThreadId/ancestorThreadId active and archived
thread/delete child A
thread/list parentThreadId/ancestorThreadId active and archived
thread/read deleted child A
```

This specifically checks the open relation-over-cold-history gap. It does not
claim final cold-history parity, CLI/TUI parity, crash-recovery parity,
complete data fidelity, or final user-indistinguishability.

## Result

- all normalized cold relation/lifecycle fields equal:
  `{summary['all_normalized_cold_relation_lifecycle_fields_equal']}`
- all original labels match expected:
  `{summary['all_original_labels_match_expected']}`
- all `.chat` labels match expected:
  `{summary['all_chat_backend_labels_match_expected']}`
- cold moves succeeded:
  `{summary['chat_backend_cold_moves_succeeded']}`
- child A cold after move:
  `{summary['chat_child_a_cold_after_move']}`
- grandchild cold after move:
  `{summary['chat_grandchild_cold_after_move']}`
- child A materialized and archived:
  `{summary['chat_child_a_materialized_and_archived']}`
- grandchild materialized and archived:
  `{summary['chat_grandchild_materialized_and_archived']}`
- child A active after unarchive:
  `{summary['chat_child_a_active_after_unarchive']}`
- grandchild stays archived after unarchive:
  `{summary['chat_grandchild_stays_archived_after_unarchive']}`
- child A removed after delete:
  `{summary['chat_child_a_removed_after_delete']}`
- grandchild removed after delete:
  `{summary['chat_grandchild_removed_after_delete']}`
- child B survives delete:
  `{summary['chat_child_b_survives_delete']}`
- read deleted child A error class:
  `{summary['read_deleted_child_a_error_class']}`

## Comparison Booleans

```json
{json.dumps(comparison_results, indent=2, sort_keys=True)}
```

## `.chat` Package State By Label

```json
{json.dumps(summary['chat_package_state_by_label'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/cold-relation-lifecycle-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/cold-relation-lifecycle-response.json
```

## Not Yet Proven

This smoke does not prove background compression, crash during cold relation
lifecycle transitions, CLI/TUI cold relation surfaces, arbitrary filesystem I/O
failures, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_cold_relation_lifecycle_fields_equal"],
            summary["all_original_labels_match_expected"],
            summary["all_chat_backend_labels_match_expected"],
            all(summary["chat_backend_cold_moves_succeeded"].values()),
            summary["chat_child_a_cold_after_move"],
            summary["chat_grandchild_cold_after_move"],
            summary["chat_child_a_materialized_and_archived"],
            summary["chat_grandchild_materialized_and_archived"],
            summary["chat_child_a_active_after_unarchive"],
            summary["chat_grandchild_stays_archived_after_unarchive"],
            summary["chat_child_a_removed_after_delete"],
            summary["chat_grandchild_removed_after_delete"],
            summary["chat_child_b_survives_delete"],
            summary["original_post_delete_rollout_count"] == 2,
            summary["chat_post_delete_package_count"] == 2,
            summary["read_deleted_child_a_error_equal"],
            summary["read_deleted_child_a_error_class"] == "thread_not_loaded",
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
