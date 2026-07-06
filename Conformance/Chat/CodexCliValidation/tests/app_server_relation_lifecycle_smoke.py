#!/usr/bin/env python3
"""Run relation-filter lifecycle parity smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path for both the original Codex backend and the adapted `.chat` backend.

It covers a narrow L02/L05/L06/L07 intersection:

- create a real parent/child/grandchild relation graph through
  `multi_agent_v1.spawn_agent`;
- archive the intermediate child and verify descendant listing follows the
  original lifecycle behavior by hiding that archived subtree from the active
  relation view and showing that subtree in the archived relation view;
- unarchive the intermediate child and verify only that child returns to the
  active relation view while the already archived grandchild stays archived;
- delete the intermediate child and verify the original subtree-removal
  behavior, child/descendant relation listings, package removal, and
  deleted-read error classes match.

This does not prove cold-history relation behavior, CLI/TUI lifecycle surfaces,
process-kill lifecycle recovery, complete data fidelity, or final
user-indistinguishability.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
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
from app_server_spawn_relation_smoke import (  # noqa: E402
    CHILD_A_PROMPT,
    CHILD_B_PROMPT,
    GRANDCHILD_PROMPT,
    PARENT_TURN_1_PROMPT,
    PARENT_TURN_2_PROMPT,
    SpawnRelationResponsesServer,
    label_for_thread,
    normalize_relation_response,
    relation_edges,
    summarize_chat_relation_storage,
    wait_for_next_unix_second,
    wait_for_relation_counts,
    wait_for_relation_labels,
    write_spawn_mock_config,
)
from app_server_spawn_relation_smoke import (  # noqa: E402
    receive_thread_turn_completed,
    send_turn_start_with_text,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    send_initialize,
    send_thread_read,
    send_thread_start,
)


def send_relation_list(
    client: JsonRpcClient,
    request_id: int,
    *,
    archived: bool,
    parent_thread_id: str | None = None,
    ancestor_thread_id: str | None = None,
    limit: int = 10,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "limit": limit,
        "modelProviders": [],
        "archived": archived,
    }
    if parent_thread_id is not None:
        params["parentThreadId"] = parent_thread_id
    if ancestor_thread_id is not None:
        params["ancestorThreadId"] = ancestor_thread_id
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "thread/list",
            "params": params,
        }
    )
    return client.receive_until_response(request_id, timeout_seconds=30)


def wait_for_relation_state(
    client: JsonRpcClient,
    request_id_base: int,
    parent_thread_id: str | None,
    *,
    archived: bool,
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
        last_direct = send_relation_list(
            client,
            request_id_base + attempt * 2,
            archived=archived,
            parent_thread_id=parent_thread_id,
        )
        last_descendants = send_relation_list(
            client,
            request_id_base + attempt * 2 + 1,
            archived=archived,
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
        "timed out waiting for relation lifecycle state; "
        f"archived={archived}; last_direct={last_direct}; "
        f"last_descendants={last_descendants}"
    )


def label_to_thread_id(
    response: dict[str, Any],
    parent_thread_id: str | None,
) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for thread in (response.get("result") or {}).get("data") or []:
        label = label_for_thread(thread, parent_thread_id)
        thread_id = thread.get("id")
        if isinstance(thread_id, str):
            mapping[label] = thread_id
    return mapping


def summarize_chat_relation_lifecycle_storage(chat_root: pathlib.Path) -> dict[str, Any]:
    base = summarize_chat_relation_storage(chat_root)
    lifecycle_packages = []
    for package in sorted(chat_root.glob("*.chat")):
        manifest_path = package / "manifest.json"
        index_path = package / "indexes/thread-metadata.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        index = json.loads(index_path.read_text()) if index_path.exists() else {}
        lifecycle_packages.append(
            {
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
            }
        )
    base["lifecycle_packages"] = lifecycle_packages
    return base


def package_state_by_label(
    storage_summary: dict[str, Any],
    label_to_id: dict[str, str],
) -> dict[str, dict[str, Any] | None]:
    packages = storage_summary.get("lifecycle_packages") or []
    by_thread_id = {
        package.get("thread_id"): package
        for package in packages
        if package.get("thread_id") is not None
    }
    return {label: by_thread_id.get(thread_id) for label, thread_id in label_to_id.items()}


def normalize_relation_pair(
    direct: dict[str, Any],
    descendants: dict[str, Any],
    parent_thread_id: str | None,
) -> dict[str, Any]:
    normalized_direct = normalize_relation_response(direct, parent_thread_id)
    normalized_descendants = normalize_relation_response(descendants, parent_thread_id)
    return {
        "direct": normalized_direct,
        "descendants": normalized_descendants,
        "descendant_edges": relation_edges(normalized_descendants),
    }


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
            wait_for_relation_counts(
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
            id_by_label = {
                **label_to_thread_id(direct_full, parent_thread_id),
                **label_to_thread_id(descendants_full, parent_thread_id),
                "parent": parent_thread_id,
            }
            child_a_thread_id = id_by_label["child-a"]

            pre_lifecycle_storage = (
                summarize_chat_relation_lifecycle_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            archive_child_a_response = send_thread_archive(client, 300, child_a_thread_id)
            archive_child_a_notification = client.receive_until_method(
                "thread/archived",
                timeout_seconds=30,
            )
            active_direct_after_archive, active_descendants_after_archive = (
                wait_for_relation_state(
                    client,
                    320,
                    parent_thread_id,
                    archived=False,
                    expected_direct_labels=["child-b"],
                    expected_descendant_labels=["child-b"],
                )
            )
            archived_direct_after_archive, archived_descendants_after_archive = (
                wait_for_relation_state(
                    client,
                    360,
                    parent_thread_id,
                    archived=True,
                    expected_direct_labels=["child-a"],
                    expected_descendant_labels=["grandchild", "child-a"],
                )
            )
            post_archive_storage = (
                summarize_chat_relation_lifecycle_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            unarchive_child_a_response = send_thread_unarchive(client, 400, child_a_thread_id)
            unarchive_child_a_notification = client.receive_until_method(
                "thread/unarchived",
                timeout_seconds=30,
            )
            active_direct_after_unarchive, active_descendants_after_unarchive = (
                wait_for_relation_state(
                    client,
                    420,
                    parent_thread_id,
                    archived=False,
                    expected_direct_labels=["child-b", "child-a"],
                    expected_descendant_labels=["child-b", "child-a"],
                )
            )
            archived_direct_after_unarchive, archived_descendants_after_unarchive = (
                wait_for_relation_state(
                    client,
                    460,
                    parent_thread_id,
                    archived=True,
                    expected_direct_labels=[],
                    expected_descendant_labels=["grandchild"],
                )
            )
            post_unarchive_storage = (
                summarize_chat_relation_lifecycle_storage(chat_root)
                if tree_name == "chat-backend"
                else summarize_original_storage(codex_home)
            )

            delete_child_a_response = send_thread_delete(client, 500, child_a_thread_id)
            delete_child_a_notification = client.receive_until_method(
                "thread/deleted",
                timeout_seconds=30,
            )
            active_direct_after_delete, active_descendants_after_delete = (
                wait_for_relation_state(
                    client,
                    520,
                    parent_thread_id,
                    archived=False,
                    expected_direct_labels=["child-b"],
                    expected_descendant_labels=["child-b"],
                )
            )
            archived_direct_after_delete, archived_descendants_after_delete = (
                wait_for_relation_state(
                    client,
                    560,
                    parent_thread_id,
                    archived=True,
                    expected_direct_labels=[],
                    expected_descendant_labels=[],
                )
            )
            read_child_a_after_delete = send_thread_read(client, 600, child_a_thread_id)
            post_delete_storage = (
                summarize_chat_relation_lifecycle_storage(chat_root)
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
        "id_by_label": id_by_label,
        "turn_1_response": turn_1_response,
        "turn_2_response": turn_2_response,
        "parent_turn_1_completed": parent_turn_1_completed,
        "parent_turn_2_completed": parent_turn_2_completed,
        "direct_full": direct_full,
        "descendants_full": descendants_full,
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
        "normalized_full": normalize_relation_pair(
            direct_full,
            descendants_full,
            parent_thread_id,
        ),
        "normalized_after_archive_active": normalize_relation_pair(
            active_direct_after_archive,
            active_descendants_after_archive,
            parent_thread_id,
        ),
        "normalized_after_archive_archived": normalize_relation_pair(
            archived_direct_after_archive,
            archived_descendants_after_archive,
            parent_thread_id,
        ),
        "normalized_after_unarchive_active": normalize_relation_pair(
            active_direct_after_unarchive,
            active_descendants_after_unarchive,
            parent_thread_id,
        ),
        "normalized_after_unarchive_archived": normalize_relation_pair(
            archived_direct_after_unarchive,
            archived_descendants_after_unarchive,
            parent_thread_id,
        ),
        "normalized_after_delete_active": normalize_relation_pair(
            active_direct_after_delete,
            active_descendants_after_delete,
            parent_thread_id,
        ),
        "normalized_after_delete_archived": normalize_relation_pair(
            archived_direct_after_delete,
            archived_descendants_after_delete,
            parent_thread_id,
        ),
        "normalized_archive_response": normalize_empty_response(archive_child_a_response),
        "normalized_archive_notification": normalize_archive_notification(
            archive_child_a_notification,
            child_a_thread_id,
        ),
        "normalized_unarchive_response": normalize_empty_response(unarchive_child_a_response),
        "normalized_unarchive_notification": normalize_archive_notification(
            unarchive_child_a_notification,
            child_a_thread_id,
        ),
        "normalized_delete_response": normalize_empty_response(delete_child_a_response),
        "normalized_delete_notification": normalize_archive_notification(
            delete_child_a_notification,
            child_a_thread_id,
        ),
        "normalized_read_child_a_after_delete_error": normalize_delete_error(
            read_child_a_after_delete
        ),
        "mock_server_summary": server_summary,
        "pre_lifecycle_storage": pre_lifecycle_storage,
        "post_archive_storage": post_archive_storage,
        "post_unarchive_storage": post_unarchive_storage,
        "post_delete_storage": post_delete_storage,
        "jsonrpc_sent": client.sent,
        "jsonrpc_received": client.received,
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }
    if tree_name == "chat-backend":
        result["chat_package_state_by_label"] = {
            "pre_lifecycle": package_state_by_label(pre_lifecycle_storage, id_by_label),
            "post_archive": package_state_by_label(post_archive_storage, id_by_label),
            "post_unarchive": package_state_by_label(post_unarchive_storage, id_by_label),
            "post_delete": package_state_by_label(post_delete_storage, id_by_label),
        }
    return result


def labels_from_pair(pair: dict[str, Any]) -> dict[str, list[str]]:
    return {
        "direct": pair["direct"]["labels"],
        "descendants": pair["descendants"]["labels"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-relation-lifecycle-smoke-"
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

    relation_keys = [
        "normalized_full",
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
    chat_child_a_archived = (
        (chat_package_states.get("post_archive") or {}).get("child-a") or {}
    ).get("archived")
    chat_child_a_unarchived = (
        (chat_package_states.get("post_unarchive") or {}).get("child-a") or {}
    ).get("archived")
    chat_child_a_deleted = (
        (chat_package_states.get("post_delete") or {}).get("child-a") is None
    )
    chat_grandchild_deleted = (
        (chat_package_states.get("post_delete") or {}).get("grandchild") is None
    )
    chat_child_b_survives_delete = (
        (chat_package_states.get("post_delete") or {}).get("child-b") is not None
    )
    original_post_delete_rollout_count = len(
        original_result["post_delete_storage"].get("rollout_files") or []
    )
    chat_post_delete_package_count = chat_result["post_delete_storage"].get("package_count")

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-relation-lifecycle-smoke",
        "binary_checks": binary_checks,
        "comparison_results": comparison_results,
        "all_normalized_relation_lifecycle_fields_equal": all(
            comparison_results.values()
        ),
        "original_labels_match_expected": original_labels_match_expected,
        "chat_backend_labels_match_expected": chat_labels_match_expected,
        "all_original_labels_match_expected": all(original_labels_match_expected.values()),
        "all_chat_backend_labels_match_expected": all(chat_labels_match_expected.values()),
        "archive_notifications_seen": (
            original_result["normalized_archive_notification"]["seen"]
            and chat_result["normalized_archive_notification"]["seen"]
        ),
        "unarchive_notifications_seen": (
            original_result["normalized_unarchive_notification"]["seen"]
            and chat_result["normalized_unarchive_notification"]["seen"]
        ),
        "delete_notifications_seen": (
            original_result["normalized_delete_notification"]["seen"]
            and chat_result["normalized_delete_notification"]["seen"]
        ),
        "read_deleted_child_a_error_equal": comparison_results[
            "normalized_read_child_a_after_delete_error"
        ],
        "read_deleted_child_a_error_class": original_result[
            "normalized_read_child_a_after_delete_error"
        ]["message_class"],
        "chat_child_a_archived_after_archive": chat_child_a_archived is True,
        "chat_child_a_active_after_unarchive": chat_child_a_unarchived is False,
        "chat_child_a_package_removed_after_delete": chat_child_a_deleted,
        "chat_child_b_package_survives_delete": chat_child_b_survives_delete,
        "chat_grandchild_package_removed_after_delete": chat_grandchild_deleted,
        "original_post_delete_rollout_count": original_post_delete_rollout_count,
        "chat_post_delete_package_count": chat_post_delete_package_count,
        "original": {
            key: original_result[key] for key in relation_keys + lifecycle_keys
        },
        "chat_backend": {key: chat_result[key] for key in relation_keys + lifecycle_keys},
        "chat_package_state_by_label": chat_package_states,
        "mock_server_summaries": {
            "original": original_result["mock_server_summary"],
            "chat_backend": chat_result["mock_server_summary"],
        },
        "not_yet_proven": [
            "relation behavior across cold history",
            "CLI/TUI lifecycle surfaces",
            "process-kill lifecycle recovery",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/relation-lifecycle-response.json", original_result)
    write_json(output_dir / "chat-backend/relation-lifecycle-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Relation Lifecycle Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` gate note, spec files,
vendor manifest, baseline checks, parity matrix, existing relation/lifecycle
smokes, and relevant original/adapted thread-store source were read.

## Scope

```text
parent turn 1 -> multi_agent_v1.spawn_agent(child A)
child A -> multi_agent_v1.spawn_agent(grandchild)
parent turn 2 -> multi_agent_v1.spawn_agent(child B)
thread/archive child A
thread/list parentThreadId/ancestorThreadId active and archived
thread/unarchive child A
thread/list parentThreadId/ancestorThreadId active and archived
thread/delete child A
thread/list parentThreadId/ancestorThreadId active and archived
thread/read deleted child A
```

This specifically checks the original state-DB relation lifecycle behavior:
after the intermediate child is archived, the active descendant view hides that
child's subtree; after unarchive, child A returns to the active view while the
already archived grandchild remains in the archived descendant view.

## Result

- all normalized relation/lifecycle fields equal:
  `{summary['all_normalized_relation_lifecycle_fields_equal']}`
- all original labels match expected:
  `{summary['all_original_labels_match_expected']}`
- all `.chat` labels match expected:
  `{summary['all_chat_backend_labels_match_expected']}`
- archive notifications seen: `{summary['archive_notifications_seen']}`
- unarchive notifications seen: `{summary['unarchive_notifications_seen']}`
- delete notifications seen: `{summary['delete_notifications_seen']}`
- read deleted child A error equal: `{summary['read_deleted_child_a_error_equal']}`
- read deleted child A error class: `{summary['read_deleted_child_a_error_class']}`
- `.chat` child A archived after archive:
  `{summary['chat_child_a_archived_after_archive']}`
- `.chat` child A active after unarchive:
  `{summary['chat_child_a_active_after_unarchive']}`
- `.chat` child A package removed after delete:
  `{summary['chat_child_a_package_removed_after_delete']}`
- `.chat` child B package survives delete:
  `{summary['chat_child_b_package_survives_delete']}`
- `.chat` grandchild package removed after delete:
  `{summary['chat_grandchild_package_removed_after_delete']}`
- original post-delete rollout count:
  `{summary['original_post_delete_rollout_count']}`
- `.chat` post-delete package count:
  `{summary['chat_post_delete_package_count']}`

## Comparison Booleans

```json
{json.dumps(comparison_results, indent=2, sort_keys=True)}
```

## Original Normalized Fields

```json
{json.dumps(summary['original'], indent=2, sort_keys=True)}
```

## `.chat` Backend Normalized Fields

```json
{json.dumps(summary['chat_backend'], indent=2, sort_keys=True)}
```

## `.chat` Package State By Label

```json
{json.dumps(summary['chat_package_state_by_label'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/relation-lifecycle-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/relation-lifecycle-response.json
```

## Not Yet Proven

This smoke does not prove relation behavior across cold history, CLI/TUI
lifecycle surfaces, process-kill lifecycle recovery, complete data fidelity, or
final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["all_normalized_relation_lifecycle_fields_equal"],
            summary["all_original_labels_match_expected"],
            summary["all_chat_backend_labels_match_expected"],
            summary["archive_notifications_seen"],
            summary["unarchive_notifications_seen"],
            summary["delete_notifications_seen"],
            summary["read_deleted_child_a_error_equal"],
            summary["read_deleted_child_a_error_class"] == "thread_not_loaded",
            summary["chat_child_a_archived_after_archive"],
            summary["chat_child_a_active_after_unarchive"],
            summary["chat_child_a_package_removed_after_delete"],
            summary["chat_child_b_package_survives_delete"],
            summary["chat_grandchild_package_removed_after_delete"],
            summary["original_post_delete_rollout_count"] == 2,
            summary["chat_post_delete_package_count"] == 2,
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
