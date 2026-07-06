#!/usr/bin/env python3
"""Run a real CLI fork-picker pagination parity smoke.

This source-backed validation covers one narrow user-facing Codex CLI picker slice:

    fixture seed
      create an older target CLI-source session
    fixture seed
      create enough newer CLI-source filler sessions to push the target past
      the first picker page
    codex fork
      use End to trigger picker pagination and jump to the oldest loaded row
      select the target and send a fork prompt in the forked TUI

The fork picker intentionally does not include non-interactive `codex exec`
histories, so this smoke seeds ordinary CLI-source persisted sessions before
opening the real picker. The picker, pagination, selection, and fork prompt all
run through the real TUI. This proves only a bounded fork-picker
pagination/select path; it is not final fork parity or final
user-indistinguishability evidence.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import sys
import time
import uuid
from typing import Any


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    ensure_binary,
    utc_now_iso,
    write_json,
    write_mock_config,
)
from cli_exec_resume_smoke import (  # noqa: E402
    SequenceMockResponsesServer,
    response_request_bodies,
)
from cli_fork_picker_smoke import (  # noqa: E402
    compact,
    inspect_chat_packages,
    response_request_count,
    snapshot_thread,
    storage_line_counts,
    summarize_original_sessions,
    thread_ids_for_tree,
    wait_and_collect_tui,
)
from cli_rollback_smoke import type_prompt_and_enter  # noqa: E402


FILLER_COUNT = 25
TARGET_MARKER = "FORK_PAGINATION_TARGET_MARKER"
FILLER_MARKER_PREFIX = "FORK_PAGINATION_FILLER_MARKER_"
TARGET_USER_TEXT = (
    f"{TARGET_MARKER} older target session for fork picker pagination."
)
TARGET_ASSISTANT_TEXT = (
    "Fork pagination target answer from mock model."
)
FORK_USER_TEXT = "CLI fork picker pagination selected target follow-up."
FORK_ASSISTANT_TEXT = "CLI fork picker pagination fork answer from mock model."
NEWEST_FILLER_MARKER = f"{FILLER_MARKER_PREFIX}{FILLER_COUNT:02d}"
OLDEST_FILLER_MARKER = f"{FILLER_MARKER_PREFIX}01"

COMPACT_TARGET_MARKER = compact(TARGET_MARKER)
COMPACT_NEWEST_FILLER_MARKER = compact(NEWEST_FILLER_MARKER)
COMPACT_FORK_USER_TEXT = compact(FORK_USER_TEXT)
COMPACT_FORK_ASSISTANT_TEXT = compact(FORK_ASSISTANT_TEXT)

GATE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
    "Spec/Chat/README.md",
    "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
    "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
    "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
    "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
]

SOURCE_FILES_READ = [
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_preview_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/cli_fork_picker_transcript_scroll_smoke.py",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/thread-store/src/local/test_support.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/tui/src/keymap.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/tui/src/resume_picker.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
]


def filler_marker(index: int) -> str:
    return f"{FILLER_MARKER_PREFIX}{index:02d}"


def filler_user_text(index: int) -> str:
    return (
        f"{filler_marker(index)} newer filler session {index:02d} for fork "
        "picker pagination."
    )


def filler_assistant_text(index: int) -> str:
    return f"Fork pagination filler answer {index:02d} from mock model."


def iso_at(base: dt.datetime, offset_seconds: int) -> str:
    return (base + dt.timedelta(seconds=offset_seconds)).isoformat().replace("+00:00", "Z")


def rollout_filename_ts(timestamp_iso: str) -> str:
    return timestamp_iso.replace(":", "-").replace("Z", "")


def seeded_thread_id(index: int) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"msp-chat-fork-pagination-{index:02d}"))


def seeded_turn_id(thread_id: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{thread_id}-turn-1"))


def seeded_rollout_items(
    thread_id: str,
    timestamp: str,
    workspace: pathlib.Path,
    user_text: str,
    assistant_text: str,
) -> list[dict[str, Any]]:
    turn_id = seeded_turn_id(thread_id)
    session_meta = {
        "type": "session_meta",
        "payload": {
            "session_id": thread_id,
            "id": thread_id,
            "timestamp": timestamp,
            "cwd": str(workspace),
            "originator": "Codex Desktop",
            "cli_version": "0.0.0",
            "source": "cli",
            "thread_source": "user",
            "model_provider": "mock_provider",
            "base_instructions": {"text": "Seeded fork picker pagination fixture."},
            "history_mode": "legacy",
        },
    }
    user_response = {
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": user_text}],
            "internal_chat_message_metadata_passthrough": {"turn_id": turn_id},
        },
    }
    user_event = {
        "type": "event_msg",
        "payload": {
            "type": "user_message",
            "message": user_text,
            "kind": "plain",
            "images": [],
            "local_images": [],
            "text_elements": [],
        },
    }
    agent_event = {
        "type": "event_msg",
        "payload": {
            "type": "agent_message",
            "message": assistant_text,
            "phase": None,
            "memory_citation": None,
        },
    }
    assistant_response = {
        "type": "response_item",
        "payload": {
            "type": "message",
            "id": f"msg-{thread_id}",
            "role": "assistant",
            "content": [{"type": "output_text", "text": assistant_text}],
            "internal_chat_message_metadata_passthrough": {"turn_id": turn_id},
        },
    }
    task_complete = {
        "type": "event_msg",
        "payload": {
            "type": "task_complete",
            "turn_id": turn_id,
            "last_agent_message": assistant_text,
            "completed_at": int(dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()),
            "duration_ms": 1,
            "time_to_first_token_ms": 1,
        },
    }
    return [
        session_meta,
        user_response,
        user_event,
        agent_event,
        assistant_response,
        task_complete,
    ]


def write_original_seed_session(
    codex_home: pathlib.Path,
    workspace: pathlib.Path,
    thread_id: str,
    timestamp: str,
    user_text: str,
    assistant_text: str,
) -> pathlib.Path:
    day = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    session_dir = codex_home / "sessions" / f"{day.year:04d}" / f"{day.month:02d}" / f"{day.day:02d}"
    session_dir.mkdir(parents=True, exist_ok=True)
    path = session_dir / f"rollout-{rollout_filename_ts(timestamp)}-{thread_id}.jsonl"
    lines = []
    for item in seeded_rollout_items(thread_id, timestamp, workspace, user_text, assistant_text):
        lines.append({"timestamp": timestamp, **item})
    path.write_text("\n".join(json.dumps(line, separators=(",", ":")) for line in lines) + "\n")
    return path


def timeline_event_type(item: dict[str, Any]) -> str:
    if item["type"] == "session_meta":
        return "runtime_context_snapshot"
    payload = item.get("payload") or {}
    if item["type"] == "response_item" and payload.get("type") == "message":
        return "message"
    if item["type"] == "event_msg":
        event_type = payload.get("type")
        if event_type in {"user_message", "agent_message"}:
            return "message"
        if event_type == "task_complete":
            return "status_changed"
    return item["type"]


def timeline_actor(item: dict[str, Any]) -> str:
    payload = item.get("payload") or {}
    if item["type"] == "response_item":
        return payload.get("role") or "runtime"
    if item["type"] == "event_msg":
        event_type = payload.get("type")
        if event_type == "user_message":
            return "user"
        if event_type == "agent_message":
            return "assistant"
    return "runtime"


def timeline_body(item: dict[str, Any]) -> dict[str, Any]:
    payload = item.get("payload") or {}
    if item["type"] == "response_item" and payload.get("type") == "message":
        return {
            "source_type": item["type"],
            "role": payload.get("role"),
            "content": payload.get("content"),
            "source_transport": payload,
        }
    if item["type"] == "event_msg":
        return {"source_type": item["type"], "event": payload}
    return {"source_type": item["type"], "source_transport": payload}


def seeded_timeline_events(items: list[dict[str, Any]], timestamp: str) -> list[dict[str, Any]]:
    events = []
    for seq, item in enumerate(items, start=1):
        events.append(
            {
                "id": f"evt-{seq:020d}",
                "type": timeline_event_type(item),
                "seq": seq,
                "commit_seq": seq,
                "created_at": timestamp,
                "actor": timeline_actor(item),
                "durability": "durable_replay",
                "source_ref": {"journal_commit_seq": seq},
                "body": timeline_body(item),
            }
        )
    return events


def projection_fingerprint(events: list[dict[str, Any]]) -> str:
    normalized = "".join(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n" for event in events)
    return "sha256:" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def write_projection(package: pathlib.Path, name: str, kind: str, events: list[dict[str, Any]]) -> None:
    projection_id = f"seed-{kind}-1-{len(events)}"
    metadata = {
        "record_type": "projection_metadata",
        "projection_id": projection_id,
        "projection_kind": kind,
        "projection_format": "ndjson",
        "source_event_range": {
            "from_seq": events[0]["seq"] if events else None,
            "to_seq": events[-1]["seq"] if events else None,
        },
        "source_event_ids": [event["id"] for event in events],
        "source_fingerprint": projection_fingerprint(events),
        "generator": {"name": "cli-fork-picker-pagination-seed", "version": "1"},
        "generated_at": utc_now_iso(),
        "lossy": False,
        "redacted": False,
        "truncated": False,
        "context_policy": None if kind != "model-context" else {"policy": "seeded-full-durable-timeline"},
        "call_output_balance_policy": None if kind != "model-context" else "preserve_unpaired",
        "synthetic_items": [],
        "stale_if": ["timeline.ndjson source_event_range changes", "timeline.ndjson source_fingerprint changes"],
        "loss_matrix": {
            "preserved": ["event id", "seq", "created_at", "actor", "type", "body"],
            "transformed": [],
            "truncated": [],
            "redacted": [],
            "dropped": [],
            "external_only": [],
            "missing": [],
        },
    }
    records = [metadata]
    records.extend(
        {
            "record_type": "projection_event",
            "projection_id": projection_id,
            "projection_kind": kind,
            "source_event_id": event["id"],
            "source_seq": event["seq"],
            "event_type": event["type"],
            "actor": event["actor"],
            "created_at": event["created_at"],
            "body": event["body"],
        }
        for event in events
    )
    path = package / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record, separators=(",", ":")) for record in records) + "\n")


def write_chat_seed_package(
    chat_root: pathlib.Path,
    workspace: pathlib.Path,
    thread_id: str,
    timestamp: str,
    user_text: str,
    assistant_text: str,
) -> pathlib.Path:
    package = chat_root / f"{thread_id}.chat"
    (package / "indexes").mkdir(parents=True, exist_ok=True)
    (package / "artifacts").mkdir(exist_ok=True)
    (package / "blobs").mkdir(exist_ok=True)

    items = seeded_rollout_items(thread_id, timestamp, workspace, user_text, assistant_text)
    events = seeded_timeline_events(items, timestamp)

    journal_lines = []
    for commit_seq, item in enumerate(items, start=1):
        journal_lines.append(
            {
                "commit_seq": commit_seq,
                "created_at": timestamp,
                "entry_type": "source_transport",
                "event_id": f"evt-{commit_seq:020d}",
                "source_transport": {
                    "schema": "rollout_item.v1",
                    "payload": item,
                },
            }
        )
    (package / "journal.ndjson").write_text(
        "\n".join(json.dumps(line, separators=(",", ":")) for line in journal_lines) + "\n"
    )
    (package / "timeline.ndjson").write_text(
        "\n".join(json.dumps(event, separators=(",", ":")) for event in events) + "\n"
    )

    manifest = {
        "format": "msp.chat",
        "version": 1,
        "profiles": [
            "core-timeline",
            "agent-timeline",
            "projection-cache",
            "resumable-context",
            "runtime-journal",
        ],
        "capabilities": [
            "read_core",
            "write_core",
            "preserve_unknown_events",
            "generate_projection",
            "replay_journal",
        ],
        "conversation": {
            "id": thread_id,
            "forked_from_id": None,
            "parent_thread_id": None,
            "source": "cli",
            "history_mode": "legacy",
        },
        "storage": {
            "canonical_timeline": "timeline.ndjson",
            "runtime_journal": "journal.ndjson",
            "projections": {
                "chat-read.machine": "projections/chat-read.ndjson",
                "model-context": "projections/model-context.ndjson",
                "audit": "projections/audit.ndjson",
            },
            "artifacts": "artifacts/",
            "blobs": "blobs/",
            "metadata_index": "indexes/thread-metadata.json",
        },
        "lifecycle": {"archived": False, "archived_at": None},
        "created_at": timestamp,
        "updated_at": timestamp,
    }
    write_json(package / "manifest.json", manifest)

    stored_thread = {
        "thread_id": thread_id,
        "extra_config": None,
        "rollout_path": str(package),
        "forked_from_id": None,
        "parent_thread_id": None,
        "preview": user_text,
        "name": None,
        "model_provider": "mock_provider",
        "model": "mock-model",
        "reasoning_effort": None,
        "created_at": timestamp,
        "updated_at": timestamp,
        "recency_at": timestamp,
        "archived_at": None,
        "cwd": str(workspace),
        "cli_version": "0.0.0",
        "source": "cli",
        "history_mode": "legacy",
        "thread_source": "user",
        "agent_nickname": None,
        "agent_role": None,
        "agent_path": None,
        "git_info": None,
        "approval_mode": "never",
        "permission_profile": {
            "type": "managed",
            "file_system": {
                "type": "restricted",
                "entries": [
                    {
                        "path": {"type": "special", "value": {"kind": "root"}},
                        "access": "read",
                    }
                ],
            },
            "network": "restricted",
        },
        "token_usage": None,
        "first_user_message": user_text,
        "history": None,
    }
    write_json(package / "indexes/thread-metadata.json", stored_thread)
    write_projection(package, "projections/chat-read.ndjson", "chat-read.machine", events)
    write_projection(package, "projections/model-context.ndjson", "model-context", events)
    write_projection(package, "projections/audit.ndjson", "audit", events)
    return package


def seed_source_sessions(
    tree_name: str,
    codex_home: pathlib.Path,
    chat_root: pathlib.Path,
    workspace: pathlib.Path,
) -> dict[str, Any]:
    base = dt.datetime(2026, 7, 2, 12, 0, 0, tzinfo=dt.timezone.utc)
    target_id = seeded_thread_id(0)
    seeded = []
    target_timestamp = iso_at(base, 0)
    if tree_name == "chat-backend":
        target_path = write_chat_seed_package(
            chat_root,
            workspace,
            target_id,
            target_timestamp,
            TARGET_USER_TEXT,
            TARGET_ASSISTANT_TEXT,
        )
    else:
        target_path = write_original_seed_session(
            codex_home,
            workspace,
            target_id,
            target_timestamp,
            TARGET_USER_TEXT,
            TARGET_ASSISTANT_TEXT,
        )
    seeded.append(
        {
            "index": 0,
            "role": "target",
            "thread_id": target_id,
            "path": str(target_path),
            "created_at": target_timestamp,
            "user_text": TARGET_USER_TEXT,
            "assistant_text": TARGET_ASSISTANT_TEXT,
        }
    )
    for index in range(1, FILLER_COUNT + 1):
        thread_id = seeded_thread_id(index)
        timestamp = iso_at(base, index)
        if tree_name == "chat-backend":
            path = write_chat_seed_package(
                chat_root,
                workspace,
                thread_id,
                timestamp,
                filler_user_text(index),
                filler_assistant_text(index),
            )
        else:
            path = write_original_seed_session(
                codex_home,
                workspace,
                thread_id,
                timestamp,
                filler_user_text(index),
                filler_assistant_text(index),
            )
        seeded.append(
            {
                "index": index,
                "role": "filler",
                "thread_id": thread_id,
                "path": str(path),
                "created_at": timestamp,
                "user_text": filler_user_text(index),
                "assistant_text": filler_assistant_text(index),
            }
        )
    return {
        "target_thread_id": target_id,
        "seeded_count": len(seeded),
        "seeded": seeded,
    }


def body_contains(body: dict[str, Any], text: str) -> bool:
    return text in json.dumps(body.get("input"), ensure_ascii=False)


def send_end(master: int) -> None:
    os.write(master, b"\x1b[F")


def compact_contains(text: str, compact_text: str, needle: str) -> bool:
    return needle in text or compact(needle) in compact_text


def summarize_tui_result(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "exit_code": result.get("exit_code"),
        "sent_prompt": result.get("sent_prompt"),
        "response_seen": result.get("response_seen"),
        "assistant_visible": result.get("assistant_visible"),
        "raw_output_bytes": result.get("raw_output_bytes"),
        "duration_seconds": result.get("duration_seconds"),
    }


def run_fork_picker_pagination_tui(
    codex_bin: pathlib.Path,
    workspace: pathlib.Path,
    codex_home: pathlib.Path,
    config_overrides: list[str],
    mock_server: SequenceMockResponsesServer,
) -> dict[str, Any]:
    command = [str(codex_bin), "--cd", str(workspace)]
    for override in config_overrides:
        command.extend(["--config", override])
    command.append("fork")

    state_local: dict[str, Any] = {
        "newest_filler_seen_before_pagination": False,
        "target_seen_before_pagination": False,
        "target_seen_after_pagination": False,
        "sent_end_count": 0,
        "last_end_sent_at": None,
        "sent_accept": False,
        "accept_sent_at": None,
        "sent_fork_prompt": False,
        "fork_prompt_sent_at": None,
        "fork_response_seen_at": None,
        "fork_assistant_visible_at": None,
        "pagination_tail": "",
    }

    def on_tick(master, _state, _visible, stripped, compact_tail) -> bool:
        compact_output = compact(stripped)
        picker_visible = "Forkaprevioussession" in compact_output

        target_visible = compact_contains(stripped, compact_output, TARGET_MARKER)
        newest_filler_visible = compact_contains(
            stripped, compact_output, NEWEST_FILLER_MARKER
        )
        if picker_visible and newest_filler_visible and state_local["sent_end_count"] == 0:
            state_local["newest_filler_seen_before_pagination"] = True
            state_local["target_seen_before_pagination"] = target_visible
            send_end(master)
            state_local["sent_end_count"] += 1
            state_local["last_end_sent_at"] = time.time()

        if (
            picker_visible
            and state_local["sent_end_count"] > 0
            and not target_visible
            and state_local["last_end_sent_at"] is not None
            and time.time() - state_local["last_end_sent_at"] > 0.9
            and state_local["sent_end_count"] < 8
        ):
            send_end(master)
            state_local["sent_end_count"] += 1
            state_local["last_end_sent_at"] = time.time()

        if (
            picker_visible
            and target_visible
            and state_local["sent_end_count"] < 2
            and state_local["last_end_sent_at"] is not None
            and time.time() - state_local["last_end_sent_at"] > 0.4
        ):
            send_end(master)
            state_local["sent_end_count"] += 1
            state_local["last_end_sent_at"] = time.time()

        if (
            picker_visible
            and target_visible
            and state_local["sent_end_count"] >= 2
            and not state_local["sent_accept"]
            and state_local["last_end_sent_at"] is not None
            and time.time() - state_local["last_end_sent_at"] > 0.7
        ):
            state_local["target_seen_after_pagination"] = True
            state_local["pagination_tail"] = stripped[-2400:]
            os.write(master, b"\r")
            state_local["sent_accept"] = True
            state_local["accept_sent_at"] = time.time()

        selected_or_started = (
            state_local["sent_accept"]
            and state_local["accept_sent_at"] is not None
            and time.time() - state_local["accept_sent_at"] > 1.0
            and (
                "Forkaprevioussession" not in compact_tail
                or TARGET_ASSISTANT_TEXT in stripped
                or "Pressentertocontinue" in compact_tail
            )
        )
        if selected_or_started and not state_local["sent_fork_prompt"]:
            type_prompt_and_enter(master, FORK_USER_TEXT)
            state_local["sent_fork_prompt"] = True
            state_local["fork_prompt_sent_at"] = time.time()

        requests_seen = response_request_count(mock_server.requests)
        expected_requests = 1
        if (
            state_local["sent_fork_prompt"]
            and requests_seen >= expected_requests
            and state_local["fork_response_seen_at"] is None
        ):
            state_local["fork_response_seen_at"] = time.time()
        if (
            state_local["fork_response_seen_at"] is not None
            and (
                FORK_ASSISTANT_TEXT in stripped
                or COMPACT_FORK_ASSISTANT_TEXT in compact_output
            )
            and state_local["fork_assistant_visible_at"] is None
        ):
            state_local["fork_assistant_visible_at"] = time.time()
        if (
            state_local["fork_response_seen_at"] is not None
            and time.time() - state_local["fork_response_seen_at"] > 2.0
        ):
            return True
        return False

    result = wait_and_collect_tui(
        command,
        workspace,
        codex_home,
        loop_timeout_seconds=120,
        on_tick=on_tick,
    )
    result.update(
        {
            "newest_filler_seen_before_pagination": state_local[
                "newest_filler_seen_before_pagination"
            ],
            "target_seen_before_pagination": state_local[
                "target_seen_before_pagination"
            ],
            "target_seen_after_pagination": state_local[
                "target_seen_after_pagination"
            ],
            "sent_end_count": state_local["sent_end_count"],
            "sent_accept": state_local["sent_accept"],
            "sent_fork_prompt": state_local["sent_fork_prompt"],
            "fork_response_seen": state_local["fork_response_seen_at"] is not None,
            "fork_assistant_visible": state_local["fork_assistant_visible_at"]
            is not None,
            "pagination_tail": state_local["pagination_tail"],
        }
    )
    return result


def mock_request_summary(requests: list[dict[str, Any]]) -> dict[str, Any]:
    bodies = response_request_bodies(requests)
    fork_body = bodies[0] if bodies else {}
    return {
        "request_count": len(requests),
        "response_request_count": len(bodies),
        "fork_body_contains_target_marker": body_contains(fork_body, TARGET_MARKER),
        "fork_body_contains_target_assistant": body_contains(
            fork_body, TARGET_ASSISTANT_TEXT
        ),
        "fork_body_contains_fork_user": body_contains(fork_body, FORK_USER_TEXT),
        "fork_body_contains_newest_filler_marker": body_contains(
            fork_body, NEWEST_FILLER_MARKER
        ),
        "fork_body_contains_oldest_filler_marker": body_contains(
            fork_body, OLDEST_FILLER_MARKER
        ),
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

    seed_summary = seed_source_sessions(tree_name, codex_home, chat_root, workspace)
    target_thread_id = seed_summary["target_thread_id"]
    seeded_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))

    with SequenceMockResponsesServer([FORK_ASSISTANT_TEXT]) as mock_server:
        write_mock_config(codex_home, mock_server.url)

        target_snapshot_before_fork = snapshot_thread(
            tree_name,
            codex_home,
            chat_root,
            target_thread_id,
        )
        pre_fork_line_counts = storage_line_counts(tree_name, codex_home, chat_root)

        fork_picker_tui = run_fork_picker_pagination_tui(
            codex_bin,
            workspace,
            codex_home,
            config_overrides,
            mock_server,
        )

        post_fork_ids = set(thread_ids_for_tree(tree_name, codex_home, chat_root))
        fork_new_ids = sorted(post_fork_ids - seeded_ids)
        target_snapshot_after_fork = snapshot_thread(
            tree_name,
            codex_home,
            chat_root,
            target_thread_id,
        )
        post_fork_line_counts = storage_line_counts(tree_name, codex_home, chat_root)
        mock_summary = mock_request_summary(mock_server.requests)

    post_fork_storage = (
        inspect_chat_packages(chat_root, target_thread_id)
        if tree_name == "chat-backend"
        else summarize_original_sessions(codex_home, target_thread_id)
    )

    return {
        "tree": tree_name,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "seed_summary": seed_summary,
        "fork_picker_tui": fork_picker_tui,
        "target_thread_id": target_thread_id,
        "fork_thread_ids": fork_new_ids,
        "target_snapshot_before_fork": target_snapshot_before_fork,
        "target_snapshot_after_fork": target_snapshot_after_fork,
        "target_source_durable_history_unchanged": (
            target_snapshot_before_fork == target_snapshot_after_fork
        ),
        "pre_fork_line_counts": pre_fork_line_counts,
        "post_fork_line_counts": post_fork_line_counts,
        "mock_server_summary": mock_summary,
        "post_fork_storage": post_fork_storage,
    }


def normalized_tree_summary(result: dict[str, Any]) -> dict[str, Any]:
    seed_summary = result["seed_summary"]
    return {
        "seeded_count": seed_summary["seeded_count"],
        "target_seeded": bool(seed_summary["target_thread_id"]),
        "filler_count": seed_summary["seeded_count"] - 1,
        "all_fillers_seeded": all(
            item.get("thread_id") for item in seed_summary["seeded"] if item["role"] == "filler"
        ),
        "fork_picker_newest_filler_seen_before_pagination": result[
            "fork_picker_tui"
        ]["newest_filler_seen_before_pagination"],
        "fork_picker_target_seen_before_pagination": result["fork_picker_tui"][
            "target_seen_before_pagination"
        ],
        "fork_picker_target_seen_after_pagination": result["fork_picker_tui"][
            "target_seen_after_pagination"
        ],
        "fork_picker_sent_end_count": result["fork_picker_tui"]["sent_end_count"],
        "fork_picker_sent_accept": result["fork_picker_tui"]["sent_accept"],
        "fork_picker_sent_fork_prompt": result["fork_picker_tui"][
            "sent_fork_prompt"
        ],
        "fork_picker_response_seen": result["fork_picker_tui"][
            "fork_response_seen"
        ],
        "fork_picker_assistant_visible": result["fork_picker_tui"][
            "fork_assistant_visible"
        ],
        "target_thread_created": result["target_thread_id"] is not None,
        "fork_thread_count": len(result["fork_thread_ids"]),
        "target_source_durable_history_unchanged": result[
            "target_source_durable_history_unchanged"
        ],
        "mock": result["mock_server_summary"],
        "post_fork_line_counts": result["post_fork_line_counts"],
    }


def write_markdown_report(output_dir: pathlib.Path, summary: dict[str, Any]) -> None:
    lines = [
        "# CLI Fork Picker Pagination Smoke",
        "",
        "This is source-backed evidence for one narrow Codex CLI `.chat` backend parity slice.",
        "It is not complete fork picker parity or final user-indistinguishability evidence.",
        "",
        "## Result",
        "",
        f"- Passed: `{summary['passed']}`",
        f"- Target absent before pagination: `{summary['target_absent_before_pagination']}`",
        f"- Target visible after pagination: `{summary['target_visible_after_pagination']}`",
        f"- Picker selected target history: `{summary['picker_selected_target_history']}`",
        f"- Picker excluded filler history: `{summary['picker_excluded_filler_history']}`",
        f"- Normalized summaries equal: `{summary['normalized_summaries_equal']}`",
        f"- Durable line counts equal: `{summary['durable_line_counts_equal']}`",
        "",
        "## Scope",
        "",
        "The smoke seeds one older target ordinary CLI-source session",
        f"and {FILLER_COUNT} newer CLI-source filler sessions, opens `codex fork`,",
        "uses End to trigger lazy pagination and jump to the target row, selects",
        "that row, then sends a fork prompt in the forked TUI.",
        "",
        "## Not Proven",
        "",
    ]
    lines.extend(f"- {item}" for item in summary["not_yet_proven"])
    (output_dir / "report.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "cli-fork-picker-pagination-smoke-"
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
    original_result = run_tree("original", ORIGINAL_CODEX_RS, run_root, [])
    chat_result = run_tree(
        "chat-backend",
        CHAT_BACKEND_CODEX_RS,
        run_root,
        [f'experimental_thread_store={{ type = "chat", root = "{chat_store_root}" }}'],
    )

    original_normalized = normalized_tree_summary(original_result)
    chat_normalized = normalized_tree_summary(chat_result)

    target_absent_before_pagination = (
        not original_normalized["fork_picker_target_seen_before_pagination"]
        and not chat_normalized["fork_picker_target_seen_before_pagination"]
    )
    target_visible_after_pagination = (
        original_normalized["fork_picker_target_seen_after_pagination"]
        and chat_normalized["fork_picker_target_seen_after_pagination"]
    )
    picker_selected_target_history = all(
        [
            original_normalized["mock"]["fork_body_contains_target_marker"],
            original_normalized["mock"]["fork_body_contains_target_assistant"],
            original_normalized["mock"]["fork_body_contains_fork_user"],
            chat_normalized["mock"]["fork_body_contains_target_marker"],
            chat_normalized["mock"]["fork_body_contains_target_assistant"],
            chat_normalized["mock"]["fork_body_contains_fork_user"],
        ]
    )
    picker_excluded_filler_history = not any(
        [
            original_normalized["mock"]["fork_body_contains_newest_filler_marker"],
            original_normalized["mock"]["fork_body_contains_oldest_filler_marker"],
            chat_normalized["mock"]["fork_body_contains_newest_filler_marker"],
            chat_normalized["mock"]["fork_body_contains_oldest_filler_marker"],
        ]
    )
    durable_line_counts_equal = (
        original_normalized["post_fork_line_counts"]
        == chat_normalized["post_fork_line_counts"]
        and len(original_normalized["post_fork_line_counts"]) == FILLER_COUNT + 2
    )
    normalized_summaries_equal = original_normalized == chat_normalized

    chat_post_storage = chat_result["post_fork_storage"]
    summary = {
        "generated_at": utc_now_iso(),
        "scope": "cli-fork-picker-pagination-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "binary_checks": binary_checks,
        "filler_count": FILLER_COUNT,
        "original": original_result,
        "chat_backend": chat_result,
        "original_normalized": original_normalized,
        "chat_backend_normalized": chat_normalized,
        "normalized_summaries_equal": normalized_summaries_equal,
        "target_absent_before_pagination": target_absent_before_pagination,
        "target_visible_after_pagination": target_visible_after_pagination,
        "picker_selected_target_history": picker_selected_target_history,
        "picker_excluded_filler_history": picker_excluded_filler_history,
        "durable_line_counts_equal": durable_line_counts_equal,
        "chat_package_count": chat_post_storage.get("package_count"),
        "chat_package_count_is_expected": chat_post_storage.get("package_count")
        == FILLER_COUNT + 2,
        "chat_packages_have_standard_projections": chat_post_storage.get(
            "all_packages_have_standard_projections"
        ),
        "original_fork_rollout_records_source_relation": original_result[
            "post_fork_storage"
        ]["fork_rollout_records_source_relation"],
        "chat_fork_package_records_source_relation": chat_post_storage[
            "fork_package_mentions_source_thread"
        ],
        "passed": False,
        "claim": (
            "This proves a narrow user-facing CLI fork picker pagination slice: "
            "an older target ordinary interactive session can be pushed beyond "
            "the first picker page by newer filler sessions, reached through "
            "lazy pagination in `codex fork`, selected, and forked with original "
            "and .chat backends preserving target history, excluding filler "
            "history, retaining source relation metadata, and keeping durable "
            "line counts aligned."
        ),
        "not_yet_proven": [
            "full visual fork picker parity across viewport sizes",
            "fork picker pagination beyond this oldest-row End-key path",
            "arbitrary fork picker overlay scroll positions beyond Home/End",
            "fork-by-turn-id through every CLI surface",
            "pathless fork through every CLI surface",
            "`--last` source-relation and copied-history semantics for every source kind",
            "complete copied-history persistence for every fork variant",
            "broader relation/list behavior",
            "complete fork parity",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }

    summary["passed"] = all(
        [
            normalized_summaries_equal,
            target_absent_before_pagination,
            target_visible_after_pagination,
            picker_selected_target_history,
            picker_excluded_filler_history,
            durable_line_counts_equal,
            summary["chat_package_count_is_expected"],
            summary["chat_packages_have_standard_projections"],
            summary["original_fork_rollout_records_source_relation"],
            summary["chat_fork_package_records_source_relation"],
        ]
    )

    write_json(output_dir / "summary.json", summary)
    write_json(output_dir / "original-result.json", original_result)
    write_json(output_dir / "chat-backend-result.json", chat_result)
    write_markdown_report(output_dir, summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
