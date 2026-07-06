#!/usr/bin/env python3
"""Run app-server legacy compaction fallback parity smoke.

This source-backed validation drives original Codex and the adapted `.chat` backend
through a normal manual compaction, then mutates the generated durable storage
to remove `CompactedItem.replacement_history`. That simulates legacy rollout
data and proves the `.chat` backend preserves Codex's original fallback replay
behavior instead of depending on the newer replacement-history field.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any, Callable


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

from app_server_cold_resume_smoke import send_thread_resume  # noqa: E402
from app_server_compaction_smoke import (  # noqa: E402
    COMPACTION_SUMMARY_SUFFIX,
    FIRST_ASSISTANT_TEXT,
    FIRST_USER_TEXT,
    FOLLOWUP_ASSISTANT_TEXT,
    FOLLOWUP_USER_TEXT,
    CompactionMockResponsesServer,
    normalize_compaction_result,
    normalize_thread_response,
    send_initialize,
    send_thread_compact_start,
    send_thread_read,
    send_thread_start,
    send_turn_start,
    summarize_mock_requests,
    write_compaction_mock_config,
)
from app_server_durable_turn_smoke import (  # noqa: E402
    CHAT_BACKEND_CODEX_RS,
    ORIGINAL_CODEX_RS,
    JsonRpcClient,
    ensure_binary,
    read_json_lines,
    summarize_chat_packages,
    summarize_original_storage,
    summarize_path_observation,
    utc_now_iso,
    write_json,
)


def rewrite_jsonl(path: pathlib.Path, mutate: Callable[[dict[str, Any]], bool]) -> int:
    changed = 0
    output: list[str] = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        if mutate(item):
            changed += 1
        output.append(json.dumps(item, separators=(",", ":"), ensure_ascii=False))
    path.write_text("\n".join(output) + ("\n" if output else ""))
    return changed


def original_rollout_paths(codex_home: pathlib.Path) -> list[pathlib.Path]:
    storage = summarize_original_storage(codex_home)
    return [codex_home / rollout["path"] for rollout in storage.get("rollouts") or []]


def chat_package_paths(chat_root: pathlib.Path) -> list[pathlib.Path]:
    summary = summarize_chat_packages(chat_root)
    return [pathlib.Path(package["package"]) for package in summary.get("packages") or []]


def remove_original_replacement_history(codex_home: pathlib.Path) -> dict[str, Any]:
    changed_by_path: dict[str, int] = {}
    for path in original_rollout_paths(codex_home):
        def mutate(item: dict[str, Any]) -> bool:
            if item.get("type") != "compacted":
                return False
            payload = item.get("payload") or {}
            if "replacement_history" not in payload:
                return False
            del payload["replacement_history"]
            return True

        changed_by_path[str(path)] = rewrite_jsonl(path, mutate)
    return {"changed_by_path": changed_by_path, "changed_count": sum(changed_by_path.values())}


def remove_chat_replacement_history(chat_root: pathlib.Path) -> dict[str, Any]:
    changed_by_path: dict[str, int] = {}
    for package_path in chat_package_paths(chat_root):
        journal_path = package_path / "journal.ndjson"

        def mutate(entry: dict[str, Any]) -> bool:
            payload = (
                ((entry.get("source_transport") or {}).get("payload") or {})
            )
            if payload.get("type") != "compacted":
                return False
            compacted_payload = payload.get("payload") or {}
            if "replacement_history" not in compacted_payload:
                return False
            del compacted_payload["replacement_history"]
            return True

        changed_by_path[str(journal_path)] = rewrite_jsonl(journal_path, mutate)
    return {"changed_by_path": changed_by_path, "changed_count": sum(changed_by_path.values())}


def compacted_presence_sequence_from_rollout(path: pathlib.Path) -> list[bool]:
    return [
        "replacement_history" in (line.get("payload") or {})
        for line in read_json_lines(path)
        if line.get("type") == "compacted"
    ]


def compacted_presence_sequence_from_chat_journal(path: pathlib.Path) -> list[bool]:
    sequence = []
    for line in read_json_lines(path):
        payload = ((line.get("source_transport") or {}).get("payload") or {})
        if payload.get("type") == "compacted":
            sequence.append("replacement_history" in (payload.get("payload") or {}))
    return sequence


def original_legacy_summary(codex_home: pathlib.Path) -> dict[str, Any]:
    paths = original_rollout_paths(codex_home)
    sequences = [compacted_presence_sequence_from_rollout(path) for path in paths]
    flattened = [value for sequence in sequences for value in sequence]
    serialized = "\n".join(path.read_text() for path in paths)
    return {
        "rollout_paths": [str(path) for path in paths],
        "rollout_line_counts": [len(read_json_lines(path)) for path in paths],
        "compacted_count": len(flattened),
        "replacement_history_presence_sequence": flattened,
        "compacted_without_replacement_history_count": flattened.count(False),
        "compacted_with_replacement_history_count": flattened.count(True),
        "contains_compaction_summary": COMPACTION_SUMMARY_SUFFIX in serialized,
        "contains_first_user_text": FIRST_USER_TEXT in serialized,
    }


def chat_legacy_summary(chat_root: pathlib.Path) -> dict[str, Any]:
    packages = chat_package_paths(chat_root)
    journal_paths = [package / "journal.ndjson" for package in packages]
    timeline_paths = [package / "timeline.ndjson" for package in packages]
    sequences = [
        compacted_presence_sequence_from_chat_journal(path)
        for path in journal_paths
    ]
    flattened = [value for sequence in sequences for value in sequence]
    journal_serialized = "\n".join(
        path.read_text() for path in journal_paths if path.exists()
    )
    timeline_lines = [
        line
        for path in timeline_paths
        for line in read_json_lines(path)
    ]
    return {
        "package_paths": [str(path) for path in packages],
        "journal_line_counts": [len(read_json_lines(path)) for path in journal_paths],
        "timeline_line_counts": [len(read_json_lines(path)) for path in timeline_paths],
        "timeline_compaction_event_count": sum(
            1 for line in timeline_lines if line.get("type") == "durable_compaction_checkpoint"
        ),
        "journal_compacted_count": len(flattened),
        "replacement_history_presence_sequence": flattened,
        "compacted_without_replacement_history_count": flattened.count(False),
        "compacted_with_replacement_history_count": flattened.count(True),
        "contains_compaction_summary": COMPACTION_SUMMARY_SUFFIX in journal_serialized,
        "contains_first_user_text": FIRST_USER_TEXT in journal_serialized,
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

    with CompactionMockResponsesServer() as mock_server:
        write_compaction_mock_config(codex_home, mock_server.url)
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client, 2, workspace
            )
            first_turn_start_response = send_turn_start(
                first_client,
                3,
                thread_id,
                "client-user-message-legacy-compaction-first",
                FIRST_USER_TEXT,
            )
            before_compaction_read_response = send_thread_read(first_client, 4, thread_id)
            compaction_result = send_thread_compact_start(first_client, 5, thread_id)
            after_compaction_read_response = send_thread_read(first_client, 6, thread_id)
        finally:
            first_stderr = first_client.close()

        before_mutation_storage = (
            chat_legacy_summary(chat_root)
            if tree_name == "chat-backend"
            else original_legacy_summary(codex_home)
        )
        mutation_summary = (
            remove_chat_replacement_history(chat_root)
            if tree_name == "chat-backend"
            else remove_original_replacement_history(codex_home)
        )
        after_mutation_storage = (
            chat_legacy_summary(chat_root)
            if tree_name == "chat-backend"
            else original_legacy_summary(codex_home)
        )

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 7)
            thread_resume_response = send_thread_resume(second_client, 8, thread_id)
            post_resume_read_response = send_thread_read(second_client, 9, thread_id)
            followup_turn_start_response = send_turn_start(
                second_client,
                10,
                thread_id,
                "client-user-message-legacy-compaction-followup",
                FOLLOWUP_USER_TEXT,
            )
            final_thread_read_response = send_thread_read(second_client, 11, thread_id)
        finally:
            second_stderr = second_client.close()

        final_storage = (
            chat_legacy_summary(chat_root)
            if tree_name == "chat-backend"
            else original_legacy_summary(codex_home)
        )

        result = {
            "tree": tree_name,
            "workspace": str(workspace),
            "codex_home": str(codex_home),
            "thread_id": thread_id,
            "first_process": {
                "command": first_client.command,
                "initialize_response": initialize_response,
                "thread_start_response": thread_start_response,
                "first_turn_start_response": first_turn_start_response,
                "before_compaction_thread_read_response": before_compaction_read_response,
                "compaction_result": compaction_result,
                "after_compaction_thread_read_response": after_compaction_read_response,
                "jsonrpc_sent": first_client.sent,
                "jsonrpc_received": first_client.received,
                "stderr_tail": first_stderr[-6000:],
                "process_exit_code": first_client.process.returncode,
            },
            "second_process": {
                "command": second_client.command,
                "initialize_response": second_initialize_response,
                "thread_resume_response": thread_resume_response,
                "post_resume_thread_read_response": post_resume_read_response,
                "followup_turn_start_response": followup_turn_start_response,
                "final_thread_read_response": final_thread_read_response,
                "jsonrpc_sent": second_client.sent,
                "jsonrpc_received": second_client.received,
                "stderr_tail": second_stderr[-6000:],
                "process_exit_code": second_client.process.returncode,
            },
            "mutation_summary": mutation_summary,
            "before_mutation_storage": before_mutation_storage,
            "after_mutation_storage": after_mutation_storage,
            "final_storage": final_storage,
            "mock_server_summary": summarize_mock_requests(mock_server.requests),
            "normalized_before_compaction_read": normalize_thread_response(
                before_compaction_read_response
            ),
            "normalized_compaction": normalize_compaction_result(compaction_result),
            "normalized_after_compaction_read": normalize_thread_response(
                after_compaction_read_response
            ),
            "normalized_resume": normalize_thread_response(thread_resume_response),
            "normalized_post_resume_read": normalize_thread_response(
                post_resume_read_response
            ),
            "normalized_final_read": normalize_thread_response(final_thread_read_response),
            "thread_read_path_observations": {
                "before_compaction": summarize_path_observation(
                    before_compaction_read_response, thread_id
                ),
                "after_compaction": summarize_path_observation(
                    after_compaction_read_response, thread_id
                ),
                "post_resume": summarize_path_observation(
                    post_resume_read_response, thread_id
                ),
                "final": summarize_path_observation(
                    final_thread_read_response, thread_id
                ),
            },
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
            "app-server-legacy-compaction-fallback-smoke-"
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

    original_mock = original_result["mock_server_summary"]
    chat_mock = chat_result["mock_server_summary"]
    original_after_mutation = original_result["after_mutation_storage"]
    chat_after_mutation = chat_result["after_mutation_storage"]
    original_final = original_result["final_storage"]
    chat_final = chat_result["final_storage"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-legacy-compaction-fallback-smoke",
        "matrix_slice": ["K05"],
        "binary_checks": binary_checks,
        "original_first_turn_exit_ok": "result"
        in original_result["first_process"]["first_turn_start_response"]["response"],
        "chat_backend_first_turn_exit_ok": "result"
        in chat_result["first_process"]["first_turn_start_response"]["response"],
        "original_compaction_response_ok": "result"
        in original_result["first_process"]["compaction_result"]["response"],
        "chat_backend_compaction_response_ok": "result"
        in chat_result["first_process"]["compaction_result"]["response"],
        "original_resume_exit_ok": "result"
        in original_result["second_process"]["thread_resume_response"],
        "chat_backend_resume_exit_ok": "result"
        in chat_result["second_process"]["thread_resume_response"],
        "original_followup_turn_exit_ok": "result"
        in original_result["second_process"]["followup_turn_start_response"]["response"],
        "chat_backend_followup_turn_exit_ok": "result"
        in chat_result["second_process"]["followup_turn_start_response"]["response"],
        "original_mutation_removed_replacement_history": original_result[
            "mutation_summary"
        ]["changed_count"]
        >= 1,
        "chat_backend_mutation_removed_replacement_history": chat_result[
            "mutation_summary"
        ]["changed_count"]
        >= 1,
        "original_after_mutation_has_legacy_compaction": original_after_mutation[
            "compacted_without_replacement_history_count"
        ]
        >= 1,
        "chat_backend_after_mutation_has_legacy_compaction": chat_after_mutation[
            "compacted_without_replacement_history_count"
        ]
        >= 1,
        "original_after_mutation_has_no_replacement_history": original_after_mutation[
            "compacted_with_replacement_history_count"
        ]
        == 0,
        "chat_backend_after_mutation_has_no_replacement_history": chat_after_mutation[
            "compacted_with_replacement_history_count"
        ]
        == 0,
        "legacy_presence_sequence_after_mutation_equal": original_after_mutation[
            "replacement_history_presence_sequence"
        ]
        == chat_after_mutation["replacement_history_presence_sequence"],
        "legacy_presence_sequence_final_equal": original_final[
            "replacement_history_presence_sequence"
        ]
        == chat_final["replacement_history_presence_sequence"],
        "chat_backend_timeline_retains_neutral_compaction_checkpoint": chat_final[
            "timeline_compaction_event_count"
        ]
        >= chat_final["journal_compacted_count"]
        >= 1,
        "normalized_compaction_equal": (
            original_result["normalized_compaction"]
            == chat_result["normalized_compaction"]
        ),
        "normalized_resume_equal": (
            original_result["normalized_resume"] == chat_result["normalized_resume"]
        ),
        "normalized_post_resume_read_equal": (
            original_result["normalized_post_resume_read"]
            == chat_result["normalized_post_resume_read"]
        ),
        "normalized_final_read_equal": (
            original_result["normalized_final_read"]
            == chat_result["normalized_final_read"]
        ),
        "mock_response_request_counts_equal": (
            original_mock["response_request_count"]
            == chat_mock["response_request_count"]
        ),
        "mock_context_markers_equal": original_mock == chat_mock,
        "legacy_followup_context_ok": all(
            [
                original_mock == chat_mock,
                original_mock["response_request_count"] >= 3,
                original_mock["any_middle_response_contains_prompt"],
                original_mock["any_middle_response_contains_first_user_text"],
                original_mock["followup_response_contains_first_user_text"],
                original_mock["followup_response_contains_followup_user_text"],
            ]
        ),
        "original_after_mutation_storage": original_after_mutation,
        "chat_backend_after_mutation_storage": chat_after_mutation,
        "original_final_storage": original_final,
        "chat_backend_final_storage": chat_final,
        "original_mock_server_summary": original_mock,
        "chat_backend_mock_server_summary": chat_mock,
        "original_normalized_final_read": original_result["normalized_final_read"],
        "chat_backend_normalized_final_read": chat_result["normalized_final_read"],
        "thread_read_path_observations": {
            "original": original_result["thread_read_path_observations"],
            "chat-backend": chat_result["thread_read_path_observations"],
        },
        "not_yet_proven": [
            "automatic compaction K01",
            "world state full/patch K04 beyond already covered narrow slices",
            "rollback after compaction beyond existing narrow CLI slice",
            "complete compaction context-window lineage parity",
            "complete data fidelity",
            "user-indistinguishability under normal Codex usage",
        ],
    }

    write_json(output_dir / "original/legacy-compaction-response.json", original_result)
    write_json(output_dir / "chat-backend/legacy-compaction-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Legacy Compaction Fallback Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path and a local mock
Responses API.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, data-fidelity report, current
parity report, original Codex compaction replay source, and adapted `.chat`
backend journal replay source were read.

## Scope

This smoke covers K05 legacy compaction fallback:

- complete one durable turn;
- call `thread/compact/start`;
- stop the first app-server process;
- remove `replacement_history` from the generated original rollout compacted
  record and from the generated `.chat` journal compacted source-transport
  record;
- start a fresh app-server process;
- `thread/resume`;
- start a follow-up turn and verify the request context and thread reads match
  original Codex fallback behavior.

The mutation is applied only to generated validation output under this result
directory. It does not edit vendored original source.

## Result

- original first turn succeeded: `{summary['original_first_turn_exit_ok']}`
- `.chat` first turn succeeded: `{summary['chat_backend_first_turn_exit_ok']}`
- original manual compaction succeeded: `{summary['original_compaction_response_ok']}`
- `.chat` manual compaction succeeded: `{summary['chat_backend_compaction_response_ok']}`
- original mutation removed replacement history: `{summary['original_mutation_removed_replacement_history']}`
- `.chat` mutation removed replacement history: `{summary['chat_backend_mutation_removed_replacement_history']}`
- original after-mutation compacted records were legacy shaped: `{summary['original_after_mutation_has_legacy_compaction']}`
- `.chat` after-mutation compacted records were legacy shaped: `{summary['chat_backend_after_mutation_has_legacy_compaction']}`
- after-mutation replacement-history presence sequences matched: `{summary['legacy_presence_sequence_after_mutation_equal']}`
- final replacement-history presence sequences matched: `{summary['legacy_presence_sequence_final_equal']}`
- original cold resume succeeded: `{summary['original_resume_exit_ok']}`
- `.chat` cold resume succeeded: `{summary['chat_backend_resume_exit_ok']}`
- normalized resume matched: `{summary['normalized_resume_equal']}`
- normalized post-resume read matched: `{summary['normalized_post_resume_read_equal']}`
- normalized final read matched: `{summary['normalized_final_read_equal']}`
- mock request context markers matched original: `{summary['mock_context_markers_equal']}`
- legacy follow-up context matched original and preserved usable context:
  `{summary['legacy_followup_context_ok']}`
- `.chat` timeline retained neutral compaction checkpoint events: `{summary['chat_backend_timeline_retains_neutral_compaction_checkpoint']}`

## After-Mutation Storage

```json
{json.dumps({'original': original_after_mutation, 'chat-backend': chat_after_mutation}, indent=2, sort_keys=True)}
```

## Final Storage

```json
{json.dumps({'original': original_final, 'chat-backend': chat_final}, indent=2, sort_keys=True)}
```

## Mock Request Summary

```json
{json.dumps({'original': original_mock, 'chat-backend': chat_mock}, indent=2, sort_keys=True)}
```

## Final Thread Read

```json
{json.dumps({'original': summary['original_normalized_final_read'], 'chat-backend': summary['chat_backend_normalized_final_read']}, indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/legacy-compaction-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/legacy-compaction-response.json
```

## Not Yet Proven

This smoke does not prove automatic compaction, broader world-state variants,
rollback-after-compaction beyond existing narrow evidence, complete context
window lineage parity, crash recovery, complete data fidelity, or final
user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    success = all(
        [
            summary["original_first_turn_exit_ok"],
            summary["chat_backend_first_turn_exit_ok"],
            summary["original_compaction_response_ok"],
            summary["chat_backend_compaction_response_ok"],
            summary["original_resume_exit_ok"],
            summary["chat_backend_resume_exit_ok"],
            summary["original_followup_turn_exit_ok"],
            summary["chat_backend_followup_turn_exit_ok"],
            summary["original_mutation_removed_replacement_history"],
            summary["chat_backend_mutation_removed_replacement_history"],
            summary["original_after_mutation_has_legacy_compaction"],
            summary["chat_backend_after_mutation_has_legacy_compaction"],
            summary["original_after_mutation_has_no_replacement_history"],
            summary["chat_backend_after_mutation_has_no_replacement_history"],
            summary["legacy_presence_sequence_after_mutation_equal"],
            summary["legacy_presence_sequence_final_equal"],
            summary["chat_backend_timeline_retains_neutral_compaction_checkpoint"],
            summary["normalized_compaction_equal"],
            summary["normalized_resume_equal"],
            summary["normalized_post_resume_read_equal"],
            summary["normalized_final_read_equal"],
            summary["mock_response_request_counts_equal"],
            summary["legacy_followup_context_ok"],
        ]
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
