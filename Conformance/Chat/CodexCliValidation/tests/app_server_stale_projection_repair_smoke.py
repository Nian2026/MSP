#!/usr/bin/env python3
"""Run stale `.chat` projection repair app-server smoke.

This source-backed validation drives the real `codex app-server` JSON-RPC stdio path
for the adapted `.chat` backend. It corrupts, removes, or stales the
materialized `projections/chat-read.ndjson` and
`projections/model-context.ndjson` and `projections/audit.ndjson` caches after a
durable turn and verifies that normal `thread/read` repairs the projections
from canonical `timeline.ndjson` without changing user-visible read/list/search
behavior. It runs the same projection-repair cases against both the normal
`<thread-id>.chat/` package and the internal cold sibling representation
`<thread-id>.chat.cold/`, then verifies that `thread/resume` materializes the
cold package back to plain `.chat/` without losing repaired projections.

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
    normalize_thread_list_response,
    normalize_thread_response,
    normalize_thread_search_response,
    cold_package_path,
    move_plain_to_cold,
    plain_package_path,
    send_thread_list,
    send_thread_read,
    send_thread_resume,
    send_thread_search,
    send_thread_start,
    send_turn_start,
    summarize_mock_requests,
    utc_now_iso,
    write_json,
    write_mock_config,
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
    "Spec/Chat/Projections.md",
    "Spec/Chat/ContextAndJournal.md",
    "Conformance/Chat/CodexCliValidation/upstream/openai-codex-chat-backend/codex-rs/thread-store/src/chat/mod.rs",
    "Conformance/Chat/CodexCliValidation/tests/app_server_cold_package_smoke.py",
    "Conformance/Chat/CodexCliValidation/tests/app_server_corrupt_timeline_repair_smoke.py",
]

SCENARIOS = (
    "missing-projection",
    "corrupt-projection",
    "stale-projection",
)

PROJECTION_FILES = {
    "chat-read.machine": "chat-read.ndjson",
    "model-context": "model-context.ndjson",
    "audit": "audit.ndjson",
}

REPRESENTATIONS = ("plain", "cold")


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


def observe_projection(path: pathlib.Path) -> dict[str, Any]:
    observation = safe_ndjson(path)
    observation.update(
        {
            "metadata_valid": False,
            "projection_kind": None,
            "projection_format": None,
            "source_fingerprint": None,
            "source_event_ids_count": 0,
            "projection_event_count": 0,
        }
    )
    if not path.exists():
        return observation
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    if not lines:
        return observation
    try:
        metadata = json.loads(lines[0])
    except json.JSONDecodeError:
        return observation
    source_event_ids = metadata.get("source_event_ids")
    observation.update(
        {
            "metadata_valid": metadata.get("record_type") == "projection_metadata",
            "projection_kind": metadata.get("projection_kind"),
            "projection_format": metadata.get("projection_format"),
            "source_fingerprint": metadata.get("source_fingerprint"),
            "source_event_ids_count": len(source_event_ids)
            if isinstance(source_event_ids, list)
            else 0,
        }
    )
    event_count = 0
    for line in lines[1:]:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if value.get("record_type") == "projection_event":
            event_count += 1
    observation["projection_event_count"] = event_count
    return observation


def package_for_representation(
    chat_root: pathlib.Path,
    thread_id: str | None,
    representation: str,
) -> pathlib.Path:
    if representation == "plain":
        return plain_package_path(chat_root, thread_id)
    if representation == "cold":
        return cold_package_path(chat_root, thread_id)
    raise ValueError(f"unknown package representation: {representation}")


def observe_package(
    chat_root: pathlib.Path,
    thread_id: str | None,
    representation: str = "plain",
) -> dict[str, Any]:
    package = package_for_representation(chat_root, thread_id, representation)
    projections = {
        projection_kind: observe_projection(package / "projections" / projection_file)
        for projection_kind, projection_file in PROJECTION_FILES.items()
    }
    return {
        "package": str(package),
        "representation": representation,
        "package_exists": package.exists(),
        "timeline": safe_ndjson(package / "timeline.ndjson"),
        "journal": safe_ndjson(package / "journal.ndjson"),
        "projection": projections["chat-read.machine"],
        "projections": projections,
        "manifest_exists": (package / "manifest.json").exists(),
        "index_exists": (package / "indexes/thread-metadata.json").exists(),
    }


def mutate_projection(
    chat_root: pathlib.Path,
    thread_id: str | None,
    scenario: str,
    representation: str = "plain",
) -> dict[str, Any]:
    package = package_for_representation(chat_root, thread_id, representation)
    projection_paths = {
        projection_kind: package / "projections" / projection_file
        for projection_kind, projection_file in PROJECTION_FILES.items()
    }
    before = observe_package(chat_root, thread_id, representation)
    if scenario == "missing-projection":
        for projection_path in projection_paths.values():
            projection_path.unlink()
    elif scenario == "corrupt-projection":
        for projection_path in projection_paths.values():
            projection_path.write_text("{not valid json\n")
    elif scenario == "stale-projection":
        for projection_kind, projection_path in projection_paths.items():
            projection_path.write_text(
                json.dumps(
                    {
                        "record_type": "projection_metadata",
                        "projection_kind": projection_kind,
                        "projection_format": "ndjson",
                        "source_event_range": {"from_seq": 1, "to_seq": 1},
                        "source_event_ids": [],
                        "source_fingerprint": "stale",
                    }
                )
                + "\n"
            )
    else:
        raise ValueError(f"unknown scenario: {scenario}")
    return {
        "scenario": scenario,
        "representation": representation,
        "before": before,
        "after": observe_package(chat_root, thread_id, representation),
    }


def projection_repaired(
    observation: dict[str, Any], scenario: str, expected_kind: str
) -> bool:
    timeline_valid = observation["timeline"]["valid_line_count"]
    projection = observation["projections"][expected_kind]
    if projection["exists"] is not True:
        return False
    if projection["invalid_line_count"] != 0:
        return False
    if projection["metadata_valid"] is not True:
        return False
    if projection["projection_kind"] != expected_kind:
        return False
    if projection["projection_format"] != "ndjson":
        return False
    if projection["source_event_ids_count"] != timeline_valid:
        return False
    if projection["projection_event_count"] != timeline_valid:
        return False
    if scenario == "stale-projection" and projection["source_fingerprint"] == "stale":
        return False
    return True


def run_scenario(
    scenario: str,
    representation: str,
    output_dir: pathlib.Path,
    build_if_missing: bool,
) -> dict[str, Any]:
    binary_check = ensure_binary(CHAT_BACKEND_CODEX_RS, build_if_missing)
    codex_bin = CHAT_BACKEND_CODEX_RS / "target/debug/codex"
    scenario_id = f"{representation}-{scenario}"
    run_root = output_dir / "run" / scenario_id
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

        storage_after_first_turn = observe_package(chat_root, thread_id, "plain")
        cold_move: dict[str, Any] | None = None
        storage_after_cold_move: dict[str, Any] | None = None
        if representation == "cold":
            cold_move = move_plain_to_cold(chat_root, thread_id)
            storage_after_cold_move = observe_package(chat_root, thread_id, "cold")
        mutation = mutate_projection(chat_root, thread_id, scenario, representation)

        second_client = JsonRpcClient(codex_bin, workspace, codex_home, config_overrides)
        second_stderr = ""
        try:
            second_initialize_response = send_initialize(second_client, 101)
            list_after_mutation_response = send_thread_list(second_client, 102)
            search_after_mutation_response = send_thread_search(second_client, 103)
            read_after_mutation_response = send_thread_read(second_client, 104, thread_id)
            storage_after_read = observe_package(chat_root, thread_id, representation)
            storage_after_plain_read = observe_package(chat_root, thread_id, "plain")
            storage_after_cold_read = observe_package(chat_root, thread_id, "cold")
            resume_response: dict[str, Any] | None = None
            storage_after_resume: dict[str, Any] | None = None
            if representation == "cold":
                resume_response = send_thread_resume(second_client, 105, thread_id)
                storage_after_resume = observe_package(chat_root, thread_id, "plain")
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
    read_recovered = (
        normalized_read_after_mutation["has_error"] is False
        and normalized_read_after_mutation["thread_id_matches"] is True
    )
    list_recovered = normalized_list_after_mutation["contains_started_thread"] is True
    search_recovered = normalized_search_after_mutation["contains_started_thread"] is True
    projection_rebuilt = all(
        projection_repaired(storage_after_read, scenario, projection_kind)
        for projection_kind in PROJECTION_FILES
    )
    cold_read_did_not_materialize_plain = True
    cold_resume_materialized_plain = True
    cold_projection_survived_resume = True
    if representation == "cold":
        cold_read_did_not_materialize_plain = (
            storage_after_plain_read["package_exists"] is False
            and storage_after_cold_read["package_exists"] is True
        )
        cold_resume_materialized_plain = (
            storage_after_resume is not None
            and storage_after_resume["package_exists"] is True
            and cold_package_path(chat_root, thread_id).exists() is False
        )
        cold_projection_survived_resume = (
            storage_after_resume is not None
            and all(
                projection_repaired(storage_after_resume, scenario, projection_kind)
                for projection_kind in PROJECTION_FILES
            )
        )
    all_checks_passed = (
        read_recovered
        and list_recovered
        and search_recovered
        and projection_rebuilt
        and cold_read_did_not_materialize_plain
        and cold_resume_materialized_plain
        and cold_projection_survived_resume
    )

    return {
        "scenario": scenario,
        "scenario_id": scenario_id,
        "representation": representation,
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
            "resume_response": resume_response,
            "stderr_tail": second_stderr[-6000:],
            "process_exit_code": second_client.process.returncode,
        },
        "storage_after_first_turn": storage_after_first_turn,
        "cold_move": cold_move,
        "storage_after_cold_move": storage_after_cold_move,
        "mutation": mutation,
        "storage_after_read": storage_after_read,
        "storage_after_plain_read": storage_after_plain_read,
        "storage_after_cold_read": storage_after_cold_read,
        "storage_after_resume": storage_after_resume,
        "normalized_read_after_mutation": normalized_read_after_mutation,
        "normalized_list_after_mutation": normalized_list_after_mutation,
        "normalized_search_after_mutation": normalized_search_after_mutation,
        "read_recovered": read_recovered,
        "list_recovered": list_recovered,
        "search_recovered": search_recovered,
        "projection_rebuilt": projection_rebuilt,
        "cold_read_did_not_materialize_plain": cold_read_did_not_materialize_plain,
        "cold_resume_materialized_plain": cold_resume_materialized_plain,
        "cold_projection_survived_resume": cold_projection_survived_resume,
        "all_checks_passed": all_checks_passed,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-stale-projection-repair-smoke-"
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
    for representation in REPRESENTATIONS:
        for scenario in SCENARIOS:
            result = run_scenario(
                scenario, representation, output_dir, args.build_if_missing
            )
            scenario_results.append(result)
            write_json(
                output_dir / f"chat-backend/{result['scenario_id']}-response.json",
                result,
            )

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-stale-projection-repair-smoke",
        "is_final_parity_claim": False,
        "gate_files_read": GATE_FILES_READ,
        "source_files_read": SOURCE_FILES_READ,
        "scenario_results": [
            {
                "scenario": result["scenario"],
                "scenario_id": result["scenario_id"],
                "representation": result["representation"],
                "read_recovered": result["read_recovered"],
                "list_recovered": result["list_recovered"],
                "search_recovered": result["search_recovered"],
                "projection_rebuilt": result["projection_rebuilt"],
                "cold_read_did_not_materialize_plain": result[
                    "cold_read_did_not_materialize_plain"
                ],
                "cold_resume_materialized_plain": result[
                    "cold_resume_materialized_plain"
                ],
                "cold_projection_survived_resume": result[
                    "cold_projection_survived_resume"
                ],
                "projection_kinds": list(PROJECTION_FILES),
                "storage_after_read": result["storage_after_read"],
                "storage_after_resume": result["storage_after_resume"],
                "all_checks_passed": result["all_checks_passed"],
            }
            for result in scenario_results
        ],
        "all_checks_passed": all(
            result["all_checks_passed"] for result in scenario_results
        ),
        "proved": [
            "projections/chat-read.ndjson is materialized after a durable turn",
            "projections/model-context.ndjson is materialized after a durable turn",
            "projections/audit.ndjson is materialized after a durable turn",
            "missing chat-read.machine projection is rebuilt by thread/read",
            "missing model-context projection is rebuilt by thread/read",
            "missing audit projection is rebuilt by thread/read",
            "corrupt chat-read.machine projection is rebuilt by thread/read",
            "corrupt model-context projection is rebuilt by thread/read",
            "corrupt audit projection is rebuilt by thread/read",
            "stale chat-read.machine projection is rebuilt from canonical timeline",
            "stale model-context projection is rebuilt from canonical timeline",
            "stale audit projection is rebuilt from canonical timeline",
            "read/list/search remain user-visible recoverable when projection cache is missing, corrupt, or stale",
            "missing/corrupt/stale projection repair also works while the package is in .chat.cold/ representation",
            "cold projection read repair does not materialize plain .chat/ before resume",
            "thread/resume materializes repaired .chat.cold/ packages back to plain .chat/ with repaired projections intact",
        ],
        "not_yet_proven": [
            "true process-kill projection/index write boundary",
            "CLI-level projection repair parity",
            "complete crash recovery",
            "complete data fidelity",
            "final user-indistinguishability under all normal Codex usage",
        ],
    }
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Stale Projection Repair Smoke - {summary['generated_at']}

This is retained validation evidence for the `.chat` Codex backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path with a local mock
Responses API.

## Scope

This smoke covers materialized `projections/chat-read.ndjson`,
`projections/model-context.ndjson`, and `projections/audit.ndjson` cache repair
when projections are missing, corrupt, or stale while canonical
`timeline.ndjson` remains valid. It covers both normal `.chat/` packages and
cold `.chat.cold/` packages, including the cold read and resume transition.

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

This smoke does not prove true process-kill projection/index write boundaries,
CLI-level projection repair parity, complete crash recovery, complete data
fidelity, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["all_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
