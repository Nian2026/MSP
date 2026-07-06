#!/usr/bin/env python3
"""Run corrupt `.chat` package repair app-server smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for the adapted `.chat` backend. It injects corrupt retained package files after
a durable turn and verifies the repair boundary through normal app-server APIs.

Covered slices:

- corrupt manifest with recoverable journal/index state repairs on thread/read;
- one corrupt journal line is skipped when valid SessionMeta remains;
- an unrecoverable corrupt journal is hidden from read/list/search and delete
  retry removes the package.

This is not a final parity claim.
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
    CHAT_BACKEND_CODEX_RS,
    FIRST_USER_TEXT,
    JsonRpcClient,
    MockResponsesServer,
    ensure_binary,
    normalize_delete_notification,
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    plain_package_path,
    receive_thread_deleted_optional,
    send_initialize,
    send_thread_delete,
    send_thread_list,
    send_thread_read,
    send_thread_search,
    send_thread_start,
    send_turn_start,
    summarize_mock_requests,
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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/recorder.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/list.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/search.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_partial_delete_recovery_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_stale_index_repair_smoke.py",
]

SCENARIOS = (
    "corrupt-manifest",
    "corrupt-journal-extra-line",
    "corrupt-journal-unrecoverable",
)


def safe_json(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {"exists": False, "parse_ok": False}
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as err:
        return {"exists": True, "parse_ok": False, "error": str(err)}
    return {"exists": True, "parse_ok": True, "value": value}


def safe_ndjson(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {
            "exists": False,
            "line_count": 0,
            "valid_line_count": 0,
            "invalid_line_count": 0,
        }
    valid = 0
    invalid = 0
    non_empty = 0
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        non_empty += 1
        try:
            json.loads(line)
        except json.JSONDecodeError:
            invalid += 1
        else:
            valid += 1
    return {
        "exists": True,
        "line_count": non_empty,
        "valid_line_count": valid,
        "invalid_line_count": invalid,
    }


def observe_package(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    package = plain_package_path(chat_root, thread_id)
    manifest_path = package / "manifest.json"
    timeline_path = package / "timeline.ndjson"
    journal_path = package / "journal.ndjson"
    index_path = package / "indexes/thread-metadata.json"
    manifest = safe_json(manifest_path)
    index = safe_json(index_path)
    return {
        "package": str(package),
        "package_exists": package.exists(),
        "manifest": {
            "path": str(manifest_path),
            "exists": manifest["exists"],
            "parse_ok": manifest["parse_ok"],
            "format": (manifest.get("value") or {}).get("format"),
            "conversation_id": ((manifest.get("value") or {}).get("conversation") or {}).get("id"),
        },
        "timeline": safe_ndjson(timeline_path),
        "journal": safe_ndjson(journal_path),
        "index": {
            "path": str(index_path),
            "exists": index["exists"],
            "parse_ok": index["parse_ok"],
            "thread_id": (index.get("value") or {}).get("thread_id"),
            "preview": (index.get("value") or {}).get("preview"),
        },
    }


def mutate_package(
    chat_root: pathlib.Path,
    thread_id: str | None,
    scenario: str,
) -> dict[str, Any]:
    package = plain_package_path(chat_root, thread_id)
    manifest_path = package / "manifest.json"
    journal_path = package / "journal.ndjson"
    before = observe_package(chat_root, thread_id)
    if scenario == "corrupt-manifest":
        manifest_path.write_text("{not valid json\n")
    elif scenario == "corrupt-journal-extra-line":
        journal = journal_path.read_text()
        corrupted = []
        for index, line in enumerate(journal.splitlines()):
            if index == 1:
                corrupted.append("{not valid json")
            corrupted.append(line)
        journal_path.write_text("\n".join(corrupted) + "\n")
    elif scenario == "corrupt-journal-unrecoverable":
        journal_path.write_text("{not valid json\n")
    else:
        raise ValueError(f"unknown scenario: {scenario}")
    return {
        "mutated": True,
        "scenario": scenario,
        "before": before,
        "after": observe_package(chat_root, thread_id),
    }


def run_scenario(
    scenario: str,
    output_dir: pathlib.Path,
    build_if_missing: bool,
) -> dict[str, Any]:
    binary_check = ensure_binary(CHAT_BACKEND_CODEX_RS, build_if_missing)
    codex_bin = CHAT_BACKEND_CODEX_RS / "target/debug/codex"
    run_root = output_dir / "run" / scenario
    workspace = run_root / "workspace"
    codex_home = run_root / "codex-home"
    chat_root = run_root / "chat-store"
    workspace.mkdir(parents=True, exist_ok=True)
    codex_home.mkdir(parents=True, exist_ok=True)
    chat_root.mkdir(parents=True, exist_ok=True)
    config_overrides = [
        f'experimental_thread_store={{ type = "chat", root = "{chat_root}" }}',
    ]

    with MockResponsesServer(ASSISTANT_TEXT) as mock_server:
        write_mock_config(codex_home, mock_server.url)
        first_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        first_stderr = ""
        try:
            first_initialize_response = send_initialize(first_client, 1)
            thread_id, thread_start_response = send_thread_start(
                first_client, 2, workspace
            )
            first_turn_response = send_turn_start(
                first_client,
                3,
                thread_id,
                f"client-user-message-{scenario}",
                FIRST_USER_TEXT,
            )
            first_read_response = send_thread_read(first_client, 4, thread_id)
        finally:
            first_stderr = first_client.close()

        storage_after_first_turn = observe_package(chat_root, thread_id)
        mutation = mutate_package(chat_root, thread_id, scenario)

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        delete_response = None
        delete_notification = None
        read_after_delete_response = None
        list_after_delete_response = None
        search_after_delete_response = None
        try:
            second_initialize_response = send_initialize(second_client, 101)
            read_after_mutation_response = send_thread_read(second_client, 102, thread_id)
            list_after_mutation_response = send_thread_list(second_client, 103)
            search_after_mutation_response = send_thread_search(second_client, 104)
            storage_after_read = observe_package(chat_root, thread_id)

            if scenario == "corrupt-journal-unrecoverable":
                delete_response = send_thread_delete(second_client, 110, thread_id)
                delete_notification = receive_thread_deleted_optional(
                    second_client, thread_id
                )
                read_after_delete_response = send_thread_read(second_client, 111, thread_id)
                list_after_delete_response = send_thread_list(second_client, 112)
                search_after_delete_response = send_thread_search(second_client, 113)
                storage_after_delete = observe_package(chat_root, thread_id)
            else:
                storage_after_delete = None
        finally:
            second_stderr = second_client.close()

    normalized_read_after_mutation = normalize_thread_response(
        read_after_mutation_response, thread_id
    )
    normalized_list_after_mutation = normalize_thread_list_response(
        list_after_mutation_response, thread_id
    )
    normalized_search_after_mutation = normalize_thread_search_response(
        search_after_mutation_response, thread_id
    )
    expected_recoverable = scenario != "corrupt-journal-unrecoverable"
    read_recovered = (
        normalized_read_after_mutation["has_error"] is False
        and normalized_read_after_mutation["thread_id_matches"] is True
    )
    list_recovered = normalized_list_after_mutation["contains_started_thread"] is True
    search_recovered = normalized_search_after_mutation["contains_started_thread"] is True
    hidden = (
        normalize_delete_error(read_after_mutation_response)["has_error"] is True
        and normalized_list_after_mutation["contains_started_thread"] is False
        and normalized_search_after_mutation["contains_started_thread"] is False
    )
    manifest_repaired = (
        scenario != "corrupt-manifest"
        or storage_after_read["manifest"]["parse_ok"] is True
    )
    extra_journal_line_skipped = (
        scenario != "corrupt-journal-extra-line"
        or (
            storage_after_read["journal"]["invalid_line_count"] == 1
            and read_recovered
            and list_recovered
            and search_recovered
        )
    )
    delete_removed_unrecoverable = (
        scenario != "corrupt-journal-unrecoverable"
        or (
            delete_response is not None
            and normalize_empty_response(delete_response)["has_error"] is False
            and storage_after_delete is not None
            and storage_after_delete["package_exists"] is False
        )
    )
    all_checks_passed = (
        (
            read_recovered
            and list_recovered
            and search_recovered
            and manifest_repaired
            and extra_journal_line_skipped
        )
        if expected_recoverable
        else (hidden and delete_removed_unrecoverable)
    )

    return {
        "scenario": scenario,
        "binary_check": binary_check,
        "workspace": str(workspace),
        "codex_home": str(codex_home),
        "chat_root": str(chat_root),
        "thread_id": thread_id,
        "mock_server_summary": summarize_mock_requests(mock_server.requests),
        "first_process": {
            "initialize_response": first_initialize_response,
            "thread_start_response": thread_start_response,
            "turn_response": first_turn_response,
            "read_response": first_read_response,
            "stderr_tail": first_stderr[-6000:],
            "process_exit_code": first_client.process.returncode,
        },
        "second_process": {
            "initialize_response": second_initialize_response,
            "read_after_mutation_response": read_after_mutation_response,
            "list_after_mutation_response": list_after_mutation_response,
            "search_after_mutation_response": search_after_mutation_response,
            "delete_response": delete_response,
            "delete_notification": delete_notification,
            "read_after_delete_response": read_after_delete_response,
            "list_after_delete_response": list_after_delete_response,
            "search_after_delete_response": search_after_delete_response,
            "stderr_tail": second_stderr[-6000:],
            "process_exit_code": second_client.process.returncode,
        },
        "storage_after_first_turn": storage_after_first_turn,
        "mutation": mutation,
        "storage_after_read": storage_after_read,
        "storage_after_delete": storage_after_delete,
        "normalized_read_after_mutation": normalized_read_after_mutation,
        "normalized_list_after_mutation": normalized_list_after_mutation,
        "normalized_search_after_mutation": normalized_search_after_mutation,
        "normalized_read_after_mutation_error": normalize_delete_error(
            read_after_mutation_response
        ),
        "normalized_delete_response": normalize_empty_response(delete_response or {}),
        "normalized_delete_notification": normalize_delete_notification(
            delete_notification, thread_id
        ),
        "normalized_read_after_delete_error": normalize_delete_error(
            read_after_delete_response or {}
        ),
        "normalized_list_after_delete": normalize_thread_list_response(
            list_after_delete_response or {}, thread_id
        ),
        "normalized_search_after_delete": normalize_thread_search_response(
            search_after_delete_response or {}, thread_id
        ),
        "read_recovered": read_recovered,
        "list_recovered": list_recovered,
        "search_recovered": search_recovered,
        "hidden_when_unrecoverable": hidden,
        "manifest_repaired": manifest_repaired,
        "extra_journal_line_skipped": extra_journal_line_skipped,
        "delete_removed_unrecoverable": delete_removed_unrecoverable,
        "all_checks_passed": all_checks_passed,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-corrupt-package-repair-smoke-"
            + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        ),
    )
    parser.add_argument("--build-if-missing", action="store_true")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise RuntimeError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True)
    (output_dir / "chat-backend").mkdir()

    scenario_results = []
    for scenario in SCENARIOS:
        result = run_scenario(scenario, output_dir, args.build_if_missing)
        scenario_results.append(result)
        write_json(output_dir / f"chat-backend/{scenario}-response.json", result)

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-corrupt-package-repair-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "scenario_results": [
            {
                "scenario": result["scenario"],
                "read_recovered": result["read_recovered"],
                "list_recovered": result["list_recovered"],
                "search_recovered": result["search_recovered"],
                "hidden_when_unrecoverable": result["hidden_when_unrecoverable"],
                "manifest_repaired": result["manifest_repaired"],
                "extra_journal_line_skipped": result["extra_journal_line_skipped"],
                "delete_removed_unrecoverable": result["delete_removed_unrecoverable"],
                "storage_after_read": result["storage_after_read"],
                "storage_after_delete": result["storage_after_delete"],
                "all_checks_passed": result["all_checks_passed"],
            }
            for result in scenario_results
        ],
        "all_checks_passed": all(
            result["all_checks_passed"] for result in scenario_results
        ),
        "proved": [
            "corrupt manifest with recoverable package state is repaired by thread/read",
            "a single corrupt journal line does not block read/list/search when SessionMeta remains recoverable",
            "a journal with no recoverable SessionMeta is hidden from read/list/search",
            "thread/delete retry removes an unrecoverable corrupt-journal .chat package",
        ],
        "not_yet_proven": [
            "true process-kill boundaries during writes or lifecycle operations",
            "corrupt timeline repair",
            ".chat.cold/ corrupt transition recovery",
            "CLI-level corrupt-package parity",
            "complete crash recovery",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Corrupt Package Repair Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path with a local mock
Responses API.

## Scope

This smoke covers corrupt retained package files:

```text
corrupt manifest.json + intact journal/index
one corrupt journal.ndjson line + recoverable SessionMeta
unrecoverable corrupt journal.ndjson with no SessionMeta
```

The first two shapes are recoverable. The last one is not: it must stay hidden
from read/list/search and remain removable by a delete retry. This is a narrow
`.chat` crash-repair slice, not final original-vs-chat parity.

## Result

- all checks passed: `{summary['all_checks_passed']}`

```json
{json.dumps(summary['scenario_results'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/*-response.json
```

## Not Yet Proven

This smoke does not prove true process-kill boundaries, corrupt timeline repair,
`.chat.cold/` transition recovery, CLI-level corrupt-package parity, complete
crash recovery, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
