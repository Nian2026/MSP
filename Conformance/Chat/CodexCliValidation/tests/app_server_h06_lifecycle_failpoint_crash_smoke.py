#!/usr/bin/env python3
"""Run H06 lifecycle failpoint crash-recovery app-server smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio
path. The original backend runs normal lifecycle operations as the
user-visible oracle. The adapted `.chat` backend runs with validation failpoints
that abort the process during archive and delete operations, then a
fresh app-server process must expose the same normalized read/list/search
state as the original oracle.

This is narrow H06 evidence, not final lifecycle crash parity.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import time
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
    summarize_chat_packages,
    summarize_original_storage,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from app_server_list_search_archive_smoke import (  # noqa: E402
    normalize_archive_notification,
    normalize_empty_response,
    normalize_thread_list_response,
    normalize_thread_search_response,
    send_thread_archive,
    send_thread_delete,
    send_thread_list,
    send_thread_search,
    send_thread_unarchive,
)
from app_server_unsubscribe_lifecycle_smoke import (  # noqa: E402
    normalize_thread_response,
    send_initialize,
    send_thread_read,
    send_thread_start,
    send_turn_start,
)


FAILPOINT_ENV = "CODEX_CHAT_BACKEND_VALIDATION_FAILPOINT"
ARCHIVE_FAILPOINT = "after-lifecycle-manifest-before-index"
DELETE_FAILPOINT = "after-delete-plain-package-before-cold-package"

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/archive_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/unarchive_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/delete_thread.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_list_search_archive_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_lifecycle_crash_repair_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_partial_delete_recovery_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h04_projection_failpoint_crash_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_h05_pending_write_failpoint_crash_smoke.py",
]


def start_client(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    failpoint: str | None = None,
) -> JsonRpcClient:
    previous = os.environ.get(FAILPOINT_ENV)
    if failpoint is not None:
        os.environ[FAILPOINT_ENV] = failpoint
    else:
        os.environ.pop(FAILPOINT_ENV, None)
    try:
        return JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
    finally:
        if previous is None:
            os.environ.pop(FAILPOINT_ENV, None)
        else:
            os.environ[FAILPOINT_ENV] = previous


def close_or_collect(client: JsonRpcClient) -> str:
    if client.process.poll() is None:
        return client.close()
    assert client.process.stderr is not None
    return client.process.stderr.read()


def wait_for_process_exit(client: JsonRpcClient, timeout_seconds: float = 30) -> int | None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        code = client.process.poll()
        if code is not None:
            return code
        time.sleep(0.1)
    return None


def normalize_error_response(response: dict[str, Any]) -> dict[str, Any]:
    error = response.get("error") or {}
    message = error.get("message") or ""
    if "thread not loaded" in message:
        message_class = "thread_not_loaded"
    elif "no rollout found for thread id" in message:
        message_class = "no_rollout_found"
    elif "thread not found" in message:
        message_class = "thread_not_found"
    elif "is archived" in message:
        message_class = "thread_archived"
    else:
        message_class = message
    return {
        "has_error": "error" in response,
        "code": error.get("code"),
        "message_class": message_class,
    }


def read_json_file(path: pathlib.Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text())


def observe_chat_lifecycle(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    if thread_id is None:
        return {"thread_id": None}
    package = chat_root / f"{thread_id}.chat"
    cold_package = chat_root / f"{thread_id}.chat.cold"
    manifest = read_json_file(package / "manifest.json")
    index = read_json_file(package / "indexes/thread-metadata.json")
    manifest_archived_at = (manifest or {}).get("archived_at")
    return {
        "thread_id": thread_id,
        "package": str(package),
        "package_exists": package.exists(),
        "cold_package": str(cold_package),
        "cold_package_exists": cold_package.exists(),
        "manifest_exists": manifest is not None,
        "manifest_archived": manifest_archived_at is not None,
        "manifest_archived_at": manifest_archived_at,
        "index_exists": index is not None,
        "index_archived_at": (index or {}).get("archived_at"),
        "index_thread_id": (index or {}).get("thread_id"),
    }


def complete_turn(
    client: JsonRpcClient,
    workspace: pathlib.Path,
    request_base: int,
) -> tuple[str, dict[str, Any]]:
    initialize_response = send_initialize(client, request_base)
    thread_id, thread_start_response = send_thread_start(
        client, request_base + 1, workspace
    )
    turn_start_response = send_turn_start(client, request_base + 2, thread_id)
    turn_started = client.receive_until_method("turn/started", timeout_seconds=30)
    turn_completed = client.receive_until_method("turn/completed", timeout_seconds=60)
    return thread_id, {
        "initialize_response": initialize_response,
        "thread_start_response": thread_start_response,
        "turn_start_response": turn_start_response,
        "turn_started": turn_started,
        "turn_completed": turn_completed,
    }


def fresh_lifecycle_observation(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    thread_id: str,
    *,
    include_retry_delete: bool,
) -> dict[str, Any]:
    client = start_client(codex_bin, workspace, codex_home, config_overrides)
    stderr = ""
    try:
        initialize_response = send_initialize(client, 100)
        active_list = send_thread_list(client, 101, archived=False)
        archived_list = send_thread_list(client, 102, archived=True)
        active_search = send_thread_search(client, 103, archived=False)
        archived_search = send_thread_search(client, 104, archived=True)
        read_response = send_thread_read(client, 105, thread_id)
        retry_delete_response = (
            send_thread_delete(client, 106, thread_id) if include_retry_delete else None
        )
    finally:
        stderr = close_or_collect(client)
    return {
        "initialize_response": initialize_response,
        "active_list_response": active_list,
        "archived_list_response": archived_list,
        "active_search_response": active_search,
        "archived_search_response": archived_search,
        "read_response": read_response,
        "retry_delete_response": retry_delete_response,
        "normalized_active_list": normalize_thread_list_response(active_list, thread_id),
        "normalized_archived_list": normalize_thread_list_response(archived_list, thread_id),
        "normalized_active_search": normalize_thread_search_response(active_search, thread_id),
        "normalized_archived_search": normalize_thread_search_response(
            archived_search, thread_id
        ),
        "normalized_read_error": normalize_error_response(read_response),
        "normalized_read_thread": normalize_thread_response(read_response, thread_id),
        "normalized_retry_delete_error": (
            normalize_error_response(retry_delete_response)
            if retry_delete_response is not None
            else None
        ),
        "stderr_tail": stderr[-6000:],
        "process_exit_code": client.process.returncode,
    }


def run_original_archive_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = start_client(codex_bin, workspace, codex_home, [])
        stderr = ""
        try:
            thread_id, setup = complete_turn(client, workspace, 1)
            archive_response = send_thread_archive(client, 10, thread_id)
            archive_notification = client.receive_until_method(
                "thread/archived", timeout_seconds=30
            )
        finally:
            stderr = close_or_collect(client)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            [],
            thread_id,
            include_retry_delete=False,
        )
        return {
            "thread_id": thread_id,
            "setup": setup,
            "archive_response": archive_response,
            "archive_notification": archive_notification,
            "normalized_archive_response": normalize_empty_response(archive_response),
            "normalized_archive_notification": normalize_archive_notification(
                archive_notification, thread_id
            ),
            "fresh": fresh,
            "storage": summarize_original_storage(codex_home),
            "mock_server_summary": mock_server.summary(),
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }


def run_chat_archive_crash(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=ARCHIVE_FAILPOINT,
        )
        stderr = ""
        archive_response: dict[str, Any] | None = None
        archive_error: str | None = None
        try:
            thread_id, setup = complete_turn(client, workspace, 1)
            try:
                archive_response = send_thread_archive(client, 10, thread_id)
            except Exception as exc:  # process aborts before response
                archive_error = repr(exc)
            crash_exit_code = wait_for_process_exit(client, timeout_seconds=30)
        finally:
            stderr = close_or_collect(client)
        pre_repair = observe_chat_lifecycle(chat_root, thread_id)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
            include_retry_delete=False,
        )
        post_repair = observe_chat_lifecycle(chat_root, thread_id)
        return {
            "thread_id": thread_id,
            "setup": setup,
            "archive_response": archive_response,
            "archive_error": archive_error,
            "crash_exit_code": crash_exit_code,
            "crash_was_signal_abort": isinstance(crash_exit_code, int)
            and crash_exit_code < 0,
            "pre_repair": pre_repair,
            "fresh": fresh,
            "post_repair": post_repair,
            "storage": summarize_chat_packages(chat_root),
            "mock_server_summary": mock_server.summary(),
            "stderr_tail": stderr[-6000:],
        }


def run_original_unarchive_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = start_client(codex_bin, workspace, codex_home, [])
        stderr = ""
        try:
            thread_id, setup = complete_turn(client, workspace, 1)
            archive_response = send_thread_archive(client, 10, thread_id)
            archive_notification = client.receive_until_method(
                "thread/archived", timeout_seconds=30
            )
            unarchive_response = send_thread_unarchive(client, 11, thread_id)
            unarchive_notification = client.receive_until_method(
                "thread/unarchived", timeout_seconds=30
            )
        finally:
            stderr = close_or_collect(client)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            [],
            thread_id,
            include_retry_delete=False,
        )
        return {
            "thread_id": thread_id,
            "setup": setup,
            "archive_response": archive_response,
            "archive_notification": archive_notification,
            "unarchive_response": unarchive_response,
            "unarchive_notification": unarchive_notification,
            "normalized_archive_response": normalize_empty_response(archive_response),
            "normalized_archive_notification": normalize_archive_notification(
                archive_notification, thread_id
            ),
            "normalized_unarchive_response": normalize_thread_response(
                unarchive_response, thread_id
            ),
            "normalized_unarchive_notification": normalize_archive_notification(
                unarchive_notification, thread_id
            ),
            "fresh": fresh,
            "storage": summarize_original_storage(codex_home),
            "mock_server_summary": mock_server.summary(),
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }


def run_chat_unarchive_crash(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        setup_client = start_client(codex_bin, workspace, codex_home, config_overrides)
        setup_stderr = ""
        try:
            thread_id, setup = complete_turn(setup_client, workspace, 1)
            archive_response = send_thread_archive(setup_client, 10, thread_id)
            archive_notification = setup_client.receive_until_method(
                "thread/archived", timeout_seconds=30
            )
        finally:
            setup_stderr = close_or_collect(setup_client)

        archived_before_unarchive = observe_chat_lifecycle(chat_root, thread_id)
        crash_client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=ARCHIVE_FAILPOINT,
        )
        crash_stderr = ""
        unarchive_response: dict[str, Any] | None = None
        unarchive_error: str | None = None
        try:
            initialize_response = send_initialize(crash_client, 100)
            try:
                unarchive_response = send_thread_unarchive(crash_client, 101, thread_id)
            except Exception as exc:  # process aborts before response
                unarchive_error = repr(exc)
            crash_exit_code = wait_for_process_exit(crash_client, timeout_seconds=30)
        finally:
            crash_stderr = close_or_collect(crash_client)

        pre_repair = observe_chat_lifecycle(chat_root, thread_id)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
            include_retry_delete=False,
        )
        post_repair = observe_chat_lifecycle(chat_root, thread_id)
        return {
            "thread_id": thread_id,
            "setup": setup,
            "archive_response": archive_response,
            "archive_notification": archive_notification,
            "initialize_response": initialize_response,
            "unarchive_response": unarchive_response,
            "unarchive_error": unarchive_error,
            "crash_exit_code": crash_exit_code,
            "crash_was_signal_abort": isinstance(crash_exit_code, int)
            and crash_exit_code < 0,
            "archived_before_unarchive": archived_before_unarchive,
            "pre_repair": pre_repair,
            "fresh": fresh,
            "post_repair": post_repair,
            "storage": summarize_chat_packages(chat_root),
            "mock_server_summary": mock_server.summary(),
            "setup_stderr_tail": setup_stderr[-6000:],
            "crash_stderr_tail": crash_stderr[-6000:],
        }


def run_original_delete_oracle(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = start_client(codex_bin, workspace, codex_home, [])
        stderr = ""
        try:
            thread_id, setup = complete_turn(client, workspace, 1)
            delete_response = send_thread_delete(client, 10, thread_id)
            delete_notification = client.receive_until_method(
                "thread/deleted", timeout_seconds=30
            )
        finally:
            stderr = close_or_collect(client)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            [],
            thread_id,
            include_retry_delete=True,
        )
        return {
            "thread_id": thread_id,
            "setup": setup,
            "delete_response": delete_response,
            "delete_notification": delete_notification,
            "normalized_delete_response": normalize_empty_response(delete_response),
            "normalized_delete_notification": normalize_archive_notification(
                delete_notification, thread_id
            ),
            "fresh": fresh,
            "storage": summarize_original_storage(codex_home),
            "mock_server_summary": mock_server.summary(),
            "stderr_tail": stderr[-6000:],
            "process_exit_code": client.process.returncode,
        }


def run_chat_delete_crash(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    config_overrides: list[str],
) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        client = start_client(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            failpoint=DELETE_FAILPOINT,
        )
        stderr = ""
        delete_response: dict[str, Any] | None = None
        delete_error: str | None = None
        try:
            thread_id, setup = complete_turn(client, workspace, 1)
            try:
                delete_response = send_thread_delete(client, 10, thread_id)
            except Exception as exc:  # process aborts before response
                delete_error = repr(exc)
            crash_exit_code = wait_for_process_exit(client, timeout_seconds=30)
        finally:
            stderr = close_or_collect(client)
        pre_repair = observe_chat_lifecycle(chat_root, thread_id)
        fresh = fresh_lifecycle_observation(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            thread_id,
            include_retry_delete=True,
        )
        post_repair = observe_chat_lifecycle(chat_root, thread_id)
        return {
            "thread_id": thread_id,
            "setup": setup,
            "delete_response": delete_response,
            "delete_error": delete_error,
            "crash_exit_code": crash_exit_code,
            "crash_was_signal_abort": isinstance(crash_exit_code, int)
            and crash_exit_code < 0,
            "pre_repair": pre_repair,
            "fresh": fresh,
            "post_repair": post_repair,
            "storage": summarize_chat_packages(chat_root),
            "mock_server_summary": mock_server.summary(),
            "stderr_tail": stderr[-6000:],
        }


def compare_fresh_fields(original: dict[str, Any], chat: dict[str, Any], keys: list[str]) -> dict[str, bool]:
    return {key: original["fresh"][key] == chat["fresh"][key] for key in keys}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / ("app-server-h06-lifecycle-failpoint-crash-smoke-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")),
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
    original_archive = run_original_archive_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        run_root / "original-archive" / "workspace",
        run_root / "original-archive" / "codex-home",
    )
    original_unarchive = run_original_unarchive_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        run_root / "original-unarchive" / "workspace",
        run_root / "original-unarchive" / "codex-home",
    )
    original_delete = run_original_delete_oracle(
        ORIGINAL_CODEX_RS / "target/debug/codex",
        run_root / "original-delete" / "workspace",
        run_root / "original-delete" / "codex-home",
    )

    archive_chat_root = run_root / "chat-archive" / "chat-store"
    unarchive_chat_root = run_root / "chat-unarchive" / "chat-store"
    delete_chat_root = run_root / "chat-delete" / "chat-store"
    archive_chat_root.mkdir(parents=True, exist_ok=True)
    unarchive_chat_root.mkdir(parents=True, exist_ok=True)
    delete_chat_root.mkdir(parents=True, exist_ok=True)
    chat_archive = run_chat_archive_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        run_root / "chat-archive" / "workspace",
        run_root / "chat-archive" / "codex-home",
        archive_chat_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{archive_chat_root}" }}',
        ],
    )
    chat_unarchive = run_chat_unarchive_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        run_root / "chat-unarchive" / "workspace",
        run_root / "chat-unarchive" / "codex-home",
        unarchive_chat_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{unarchive_chat_root}" }}',
        ],
    )
    chat_delete = run_chat_delete_crash(
        CHAT_BACKEND_CODEX_RS / "target/debug/codex",
        run_root / "chat-delete" / "workspace",
        run_root / "chat-delete" / "codex-home",
        delete_chat_root,
        [
            f'experimental_thread_store={{ type = "chat", root = "{delete_chat_root}" }}',
        ],
    )

    archive_comparisons = compare_fresh_fields(
        original_archive,
        chat_archive,
        [
            "normalized_active_list",
            "normalized_archived_list",
            "normalized_active_search",
            "normalized_archived_search",
            "normalized_read_error",
        ],
    )
    unarchive_comparisons = compare_fresh_fields(
        original_unarchive,
        chat_unarchive,
        [
            "normalized_active_list",
            "normalized_archived_list",
            "normalized_active_search",
            "normalized_archived_search",
            "normalized_read_error",
            "normalized_read_thread",
        ],
    )
    delete_comparisons = compare_fresh_fields(
        original_delete,
        chat_delete,
        [
            "normalized_active_list",
            "normalized_archived_list",
            "normalized_active_search",
            "normalized_archived_search",
            "normalized_read_error",
            "normalized_retry_delete_error",
        ],
    )

    archive_pre_repair_stale = (
        chat_archive["pre_repair"]["manifest_archived"] is True
        and chat_archive["pre_repair"]["index_archived_at"] is None
    )
    archive_index_repaired = (
        chat_archive["post_repair"]["manifest_archived"] is True
        and chat_archive["post_repair"]["index_archived_at"] is not None
    )
    unarchive_started_archived = (
        chat_unarchive["archived_before_unarchive"]["manifest_archived"] is True
        and chat_unarchive["archived_before_unarchive"]["index_archived_at"] is not None
    )
    unarchive_pre_repair_stale = (
        chat_unarchive["pre_repair"]["manifest_archived"] is False
        and chat_unarchive["pre_repair"]["index_archived_at"] is not None
    )
    unarchive_index_repaired = (
        chat_unarchive["post_repair"]["manifest_archived"] is False
        and chat_unarchive["post_repair"]["index_archived_at"] is None
    )
    delete_package_removed = (
        chat_delete["pre_repair"]["package_exists"] is False
        and chat_delete["pre_repair"]["cold_package_exists"] is False
    )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-h06-lifecycle-failpoint-crash-smoke",
        "matrix_slice": ["H06", "L05-adjacent", "L07-adjacent", "L08-adjacent"],
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "failpoints": {
            "archive": ARCHIVE_FAILPOINT,
            "unarchive": ARCHIVE_FAILPOINT,
            "delete": DELETE_FAILPOINT,
        },
        "binary_checks": binary_checks,
        "archive": {
            "comparisons": archive_comparisons,
            "all_fresh_normalized_fields_equal": all(archive_comparisons.values()),
            "chat_backend_process_aborted_at_failpoint": chat_archive[
                "crash_was_signal_abort"
            ],
            "chat_backend_pre_repair_manifest_archived_index_active": archive_pre_repair_stale,
            "chat_backend_index_repaired_after_fresh_read": archive_index_repaired,
            "original": {
                key: original_archive["fresh"][key]
                for key in archive_comparisons.keys()
            },
            "chat_backend": {
                key: chat_archive["fresh"][key] for key in archive_comparisons.keys()
            },
        },
        "unarchive": {
            "comparisons": unarchive_comparisons,
            "all_fresh_normalized_fields_equal": all(unarchive_comparisons.values()),
            "chat_backend_process_aborted_at_failpoint": chat_unarchive[
                "crash_was_signal_abort"
            ],
            "chat_backend_started_from_archived_state": unarchive_started_archived,
            "chat_backend_pre_repair_manifest_active_index_archived": unarchive_pre_repair_stale,
            "chat_backend_index_repaired_after_fresh_read": unarchive_index_repaired,
            "original": {
                key: original_unarchive["fresh"][key]
                for key in unarchive_comparisons.keys()
            },
            "chat_backend": {
                key: chat_unarchive["fresh"][key]
                for key in unarchive_comparisons.keys()
            },
        },
        "delete": {
            "comparisons": delete_comparisons,
            "all_fresh_normalized_fields_equal": all(delete_comparisons.values()),
            "chat_backend_process_aborted_at_failpoint": chat_delete[
                "crash_was_signal_abort"
            ],
            "chat_backend_package_removed_before_fresh_repair": delete_package_removed,
            "original": {
                key: original_delete["fresh"][key]
                for key in delete_comparisons.keys()
            },
            "chat_backend": {
                key: chat_delete["fresh"][key] for key in delete_comparisons.keys()
            },
        },
        "not_yet_proven": [
            "every lifecycle filesystem operation boundary",
            "archive/unarchive/delete descendant ordering under process kill",
            "cold .chat.cold lifecycle process-kill transition",
            "background cold-history compression worker lifecycle crash",
            "CLI-level lifecycle crash user-indistinguishability",
            "complete crash recovery parity",
            "complete data fidelity",
            "final user-indistinguishability",
        ],
        "original_archive": original_archive,
        "chat_archive": chat_archive,
        "original_unarchive": original_unarchive,
        "chat_unarchive": chat_unarchive,
        "original_delete": original_delete,
        "chat_delete": chat_delete,
    }
    summary["passed"] = all(
        [
            summary["archive"]["all_fresh_normalized_fields_equal"],
            summary["archive"]["chat_backend_process_aborted_at_failpoint"],
            summary["archive"]["chat_backend_pre_repair_manifest_archived_index_active"],
            summary["archive"]["chat_backend_index_repaired_after_fresh_read"],
            summary["unarchive"]["all_fresh_normalized_fields_equal"],
            summary["unarchive"]["chat_backend_process_aborted_at_failpoint"],
            summary["unarchive"]["chat_backend_started_from_archived_state"],
            summary["unarchive"]["chat_backend_pre_repair_manifest_active_index_archived"],
            summary["unarchive"]["chat_backend_index_repaired_after_fresh_read"],
            summary["delete"]["all_fresh_normalized_fields_equal"],
            summary["delete"]["chat_backend_process_aborted_at_failpoint"],
            summary["delete"]["chat_backend_package_removed_before_fresh_repair"],
        ]
    )
    summary["claim"] = (
        "This proves a narrow H06 lifecycle process-abort slice: archive can "
        "abort after package-level lifecycle manifest is written but before the "
        "derived metadata index catches up, unarchive can abort at the same "
        "manifest-before-index boundary while restoring an archived thread to "
        "active state, and delete can abort after the plain package is removed "
        "before cold-package cleanup. Fresh app-server read/list/search/retry "
        "behavior matches the original backend's normalized oracle for these "
        "boundaries. It is not full lifecycle crash parity."
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original/archive-oracle.json", original_archive)
    write_json(output_dir / "chat-backend/archive-crash.json", chat_archive)
    write_json(output_dir / "original/unarchive-oracle.json", original_unarchive)
    write_json(output_dir / "chat-backend/unarchive-crash.json", chat_unarchive)
    write_json(output_dir / "original/delete-oracle.json", original_delete)
    write_json(output_dir / "chat-backend/delete-crash.json", chat_delete)

    report = f"""# App-Server H06 Lifecycle Failpoint Crash Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex CLI `.chat` backend
adaptation. It is not part of the public `.chat` standard.

## Scope

This smoke covers three lifecycle process-abort boundaries:

```text
archive: after package lifecycle manifest write, before metadata index write
unarchive: after package lifecycle manifest write, before metadata index write
delete: after plain .chat package removal, before cold-package cleanup
```

The original backend runs normal archive/unarchive/delete operations as the user-visible
oracle. The `.chat` backend is aborted with validation failpoints, then
a fresh app-server process reads/lists/searches/retries against the same store.

## Result

- passed: `{summary['passed']}`
- archive process aborted at failpoint: `{summary['archive']['chat_backend_process_aborted_at_failpoint']}`
- archive pre-repair state was manifest archived + index active: `{summary['archive']['chat_backend_pre_repair_manifest_archived_index_active']}`
- archive index repaired after fresh read: `{summary['archive']['chat_backend_index_repaired_after_fresh_read']}`
- archive fresh normalized fields match original: `{summary['archive']['all_fresh_normalized_fields_equal']}`
- unarchive process aborted at failpoint: `{summary['unarchive']['chat_backend_process_aborted_at_failpoint']}`
- unarchive started from archived state: `{summary['unarchive']['chat_backend_started_from_archived_state']}`
- unarchive pre-repair state was manifest active + index archived: `{summary['unarchive']['chat_backend_pre_repair_manifest_active_index_archived']}`
- unarchive index repaired after fresh read: `{summary['unarchive']['chat_backend_index_repaired_after_fresh_read']}`
- unarchive fresh normalized fields match original: `{summary['unarchive']['all_fresh_normalized_fields_equal']}`
- delete process aborted at failpoint: `{summary['delete']['chat_backend_process_aborted_at_failpoint']}`
- delete package removed before fresh read/list/search: `{summary['delete']['chat_backend_package_removed_before_fresh_repair']}`
- delete fresh normalized fields match original: `{summary['delete']['all_fresh_normalized_fields_equal']}`

## Comparison Booleans

```json
{json.dumps({'archive': archive_comparisons, 'unarchive': unarchive_comparisons, 'delete': delete_comparisons}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/archive-oracle.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/archive-crash.json
{output_dir.relative_to(VALIDATION_DIR)}/original/unarchive-oracle.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/unarchive-crash.json
{output_dir.relative_to(VALIDATION_DIR)}/original/delete-oracle.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/delete-crash.json
```

## Not Yet Proven

This smoke does not prove every lifecycle filesystem boundary, descendant
archive/unarchive/delete ordering under process kill, cold `.chat.cold/` lifecycle crash
transition, background cold-history compression lifecycle, CLI-level lifecycle
crash parity, complete data fidelity, complete crash recovery parity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
