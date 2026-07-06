#!/usr/bin/env python3
"""Run corrupt `.chat` timeline repair app-server smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for the adapted `.chat` backend. It corrupts or removes `timeline.ndjson` after a
durable turn and verifies that normal read recovers the lightweight canonical
timeline from the retained journal when SessionMeta remains recoverable.

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
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/list.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/codex-rs/rollout/src/search.rs",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_corrupt_package_repair_smoke.py",
]

SCENARIOS = (
    "corrupt-timeline-line",
    "missing-timeline",
    "unrecoverable-journal-plus-corrupt-timeline",
)


def send_initialize(client: JsonRpcClient, request_id: int) -> dict[str, Any]:
    client.send(
        {
            "jsonrpc": "2.0",
            "id": request_id,
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
    response = client.receive_until_response(request_id, timeout_seconds=120)
    client.send({"jsonrpc": "2.0", "method": "initialized"})
    return response


def safe_ndjson(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {
            "exists": False,
            "line_count": 0,
            "valid_line_count": 0,
            "invalid_line_count": 0,
            "event_types": {},
        }
    valid = 0
    invalid = 0
    non_empty = 0
    event_types: dict[str, int] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        non_empty += 1
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            invalid += 1
            continue
        valid += 1
        event_type = value.get("type")
        if isinstance(event_type, str):
            event_types[event_type] = event_types.get(event_type, 0) + 1
    return {
        "exists": True,
        "line_count": non_empty,
        "valid_line_count": valid,
        "invalid_line_count": invalid,
        "event_types": event_types,
    }


def observe_package(chat_root: pathlib.Path, thread_id: str | None) -> dict[str, Any]:
    package = plain_package_path(chat_root, thread_id)
    return {
        "package": str(package),
        "package_exists": package.exists(),
        "timeline": safe_ndjson(package / "timeline.ndjson"),
        "journal": safe_ndjson(package / "journal.ndjson"),
        "manifest_exists": (package / "manifest.json").exists(),
        "index_exists": (package / "indexes/thread-metadata.json").exists(),
    }


def mutate_package(
    chat_root: pathlib.Path,
    thread_id: str | None,
    scenario: str,
) -> dict[str, Any]:
    package = plain_package_path(chat_root, thread_id)
    timeline_path = package / "timeline.ndjson"
    journal_path = package / "journal.ndjson"
    before = observe_package(chat_root, thread_id)
    if scenario == "corrupt-timeline-line":
        timeline_path.write_text("{not valid json\n")
    elif scenario == "missing-timeline":
        timeline_path.unlink()
    elif scenario == "unrecoverable-journal-plus-corrupt-timeline":
        timeline_path.write_text("{not valid json\n")
        journal_path.write_text("{not valid json\n")
    else:
        raise ValueError(f"unknown scenario: {scenario}")
    return {
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
            list_after_mutation_response = send_thread_list(second_client, 102)
            search_after_mutation_response = send_thread_search(second_client, 103)
            read_after_mutation_response = send_thread_read(second_client, 104, thread_id)
            storage_after_read = observe_package(chat_root, thread_id)

            if scenario == "unrecoverable-journal-plus-corrupt-timeline":
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
    expected_recoverable = scenario != "unrecoverable-journal-plus-corrupt-timeline"
    read_recovered = (
        normalized_read_after_mutation["has_error"] is False
        and normalized_read_after_mutation["thread_id_matches"] is True
    )
    list_recovered = normalized_list_after_mutation["contains_started_thread"] is True
    search_recovered = normalized_search_after_mutation["contains_started_thread"] is True
    timeline_repaired = (
        storage_after_read["timeline"]["exists"] is True
        and storage_after_read["timeline"]["invalid_line_count"] == 0
        and storage_after_read["timeline"]["line_count"]
        == storage_after_read["journal"]["valid_line_count"]
    )
    hidden = (
        normalize_delete_error(read_after_mutation_response)["has_error"] is True
        and normalized_list_after_mutation["contains_started_thread"] is False
        and normalized_search_after_mutation["contains_started_thread"] is False
    )
    delete_removed_unrecoverable = (
        scenario != "unrecoverable-journal-plus-corrupt-timeline"
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
            and timeline_repaired
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
            "list_after_mutation_response": list_after_mutation_response,
            "search_after_mutation_response": search_after_mutation_response,
            "read_after_mutation_response": read_after_mutation_response,
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
        "timeline_repaired": timeline_repaired,
        "hidden_when_unrecoverable": hidden,
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
            "app-server-corrupt-timeline-repair-smoke-"
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
        "scope": "app-server-corrupt-timeline-repair-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "scenario_results": [
            {
                "scenario": result["scenario"],
                "read_recovered": result["read_recovered"],
                "list_recovered": result["list_recovered"],
                "search_recovered": result["search_recovered"],
                "timeline_repaired": result["timeline_repaired"],
                "hidden_when_unrecoverable": result["hidden_when_unrecoverable"],
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
            "corrupt timeline.ndjson with recoverable journal is rebuilt by thread/read",
            "missing timeline.ndjson with recoverable journal is rebuilt by thread/read",
            "read/list/search remain user-visible recoverable for corrupt or missing timeline when journal SessionMeta remains recoverable",
            "unrecoverable journal plus corrupt timeline is hidden from read/list/search",
            "thread/delete retry removes the unrecoverable corrupt-timeline package",
        ],
        "not_yet_proven": [
            "true process-kill write boundaries",
            "stale projection repair",
            ".chat.cold/ corrupt transition recovery",
            "CLI-level corrupt-package parity",
            "complete crash recovery",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Corrupt Timeline Repair Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path with a local mock
Responses API.

## Scope

This smoke covers retained packages where `timeline.ndjson` is corrupt or
missing while `journal.ndjson` remains recoverable. It also verifies that a
package with both corrupt timeline and unrecoverable journal is hidden rather
than fabricated.

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

This smoke does not prove true process-kill write boundaries, stale projection
repair, `.chat.cold/` transition recovery, CLI-level corrupt-package parity,
complete crash recovery, complete data fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
