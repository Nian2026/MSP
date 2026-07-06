#!/usr/bin/env python3
"""Field-by-field TurnContextItem parity smoke for Codex `.chat` backend.

This source-backed validation drives the real app-server path for both the original
Codex backend and the adapted `.chat` backend, then compares the persisted
`turn_context` rollout items field by field.
"""

from __future__ import annotations

from validation_paths import validation_results_root

import argparse
import datetime as dt
import json
import pathlib
from typing import Any

from app_server_durable_turn_smoke import CHAT_BACKEND_CODEX_RS
from app_server_durable_turn_smoke import ORIGINAL_CODEX_RS
from app_server_durable_turn_smoke import VALIDATION_DIR
from app_server_durable_turn_smoke import ensure_binary
from app_server_durable_turn_smoke import read_json_lines
from app_server_durable_turn_smoke import run_tree
from app_server_durable_turn_smoke import utc_now_iso
from app_server_durable_turn_smoke import write_json


TURN_CONTEXT_FIELDS = [
    "turn_id",
    "cwd",
    "workspace_roots",
    "current_date",
    "timezone",
    "approval_policy",
    "sandbox_policy",
    "permission_profile",
    "network",
    "file_system_sandbox_policy",
    "model",
    "comp_hash",
    "personality",
    "collaboration_mode",
    "multi_agent_version",
    "multi_agent_mode",
    "realtime_active",
    "effort",
    "summary",
]


def rollout_items_from_original_storage(storage: dict[str, Any]) -> list[dict[str, Any]]:
    codex_home = pathlib.Path(storage["codex_home"])
    items: list[dict[str, Any]] = []
    for rollout in storage.get("rollout_files") or []:
        items.extend(read_json_lines(codex_home / rollout))
    return items


def rollout_items_from_chat_journal(chat_summary: dict[str, Any]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for package in chat_summary.get("packages") or []:
        package_path = pathlib.Path(package["package"])
        for line in read_json_lines(package_path / "journal.ndjson"):
            payload = (line.get("source_transport") or {}).get("payload") or {}
            item = dict(payload)
            item["_journal_commit_seq"] = line.get("commit_seq")
            item["_journal_event_id"] = line.get("event_id")
            items.append(item)
    return items


def turn_context_items(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [item for item in items if item.get("type") == "turn_context"]


def normalize_dynamic_value(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, str):
        normalized = value
        for old, new in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
            normalized = normalized.replace(old, new)
        return normalized
    if isinstance(value, list):
        return [normalize_dynamic_value(item, replacements) for item in value]
    if isinstance(value, dict):
        return {
            key: normalize_dynamic_value(nested, replacements)
            for key, nested in sorted(value.items())
        }
    return value


def normalize_turn_context_payload(
    payload: dict[str, Any],
    replacements: dict[str, str],
) -> dict[str, Any]:
    normalized = {
        field: normalize_dynamic_value(payload.get(field), replacements)
        for field in TURN_CONTEXT_FIELDS
    }
    normalized["turn_id_present"] = bool(payload.get("turn_id"))
    normalized["turn_id"] = "<turn-id>" if payload.get("turn_id") else None
    return normalized


def field_presence(payload: dict[str, Any]) -> dict[str, bool]:
    return {field: field in payload for field in TURN_CONTEXT_FIELDS}


def summarize_turn_contexts(
    contexts: list[dict[str, Any]],
    replacements: dict[str, str],
) -> list[dict[str, Any]]:
    summaries = []
    for item in contexts:
        payload = item.get("payload") or {}
        summaries.append(
            {
                "type": item.get("type"),
                "journal_commit_seq": item.get("_journal_commit_seq"),
                "journal_event_id": item.get("_journal_event_id"),
                "field_presence": field_presence(payload),
                "normalized_payload": normalize_turn_context_payload(payload, replacements),
                "raw_field_names": sorted(payload.keys()),
            }
        )
    return summaries


def timeline_turn_context_links(chat_summary: dict[str, Any]) -> list[dict[str, Any]]:
    links: list[dict[str, Any]] = []
    for package in chat_summary.get("packages") or []:
        package_path = pathlib.Path(package["package"])
        journal_by_commit = {
            line.get("commit_seq"): line
            for line in read_json_lines(package_path / "journal.ndjson")
        }
        for event in read_json_lines(package_path / "timeline.ndjson"):
            body = event.get("body") or {}
            if (
                event.get("type") != "runtime_context_snapshot"
                or body.get("source_type") != "turn_context"
            ):
                continue
            commit_seq = (event.get("source_ref") or {}).get("journal_commit_seq")
            journal_line = journal_by_commit.get(commit_seq) or {}
            source_payload = (journal_line.get("source_transport") or {}).get("payload") or {}
            links.append(
                {
                    "package": str(package_path),
                    "event_id": event.get("id"),
                    "commit_seq": event.get("commit_seq"),
                    "source_ref_journal_commit_seq": commit_seq,
                    "journal_event_id": journal_line.get("event_id"),
                    "journal_source_type": source_payload.get("type"),
                    "linked": (
                        journal_line.get("event_id") == event.get("id")
                        and source_payload.get("type") == "turn_context"
                    ),
                }
            )
    return links


def compare_turn_contexts(
    original_result: dict[str, Any],
    chat_result: dict[str, Any],
) -> dict[str, Any]:
    original_items = rollout_items_from_original_storage(
        original_result["original_storage_summary"]
    )
    chat_items = rollout_items_from_chat_journal(chat_result["chat_package_summary"])
    original_contexts = turn_context_items(original_items)
    chat_contexts = turn_context_items(chat_items)

    original_replacements = {
        original_result["workspace"]: "<workspace>",
        original_result["codex_home"]: "<codex-home>",
    }
    chat_replacements = {
        chat_result["workspace"]: "<workspace>",
        chat_result["codex_home"]: "<codex-home>",
    }

    original_summaries = summarize_turn_contexts(
        original_contexts,
        original_replacements,
    )
    chat_summaries = summarize_turn_contexts(
        chat_contexts,
        chat_replacements,
    )
    original_normalized = [
        summary["normalized_payload"] for summary in original_summaries
    ]
    chat_normalized = [summary["normalized_payload"] for summary in chat_summaries]
    original_presence = [summary["field_presence"] for summary in original_summaries]
    chat_presence = [summary["field_presence"] for summary in chat_summaries]
    timeline_links = timeline_turn_context_links(chat_result["chat_package_summary"])

    return {
        "expected_turn_context_fields": TURN_CONTEXT_FIELDS,
        "original_turn_context_count": len(original_contexts),
        "chat_journal_turn_context_count": len(chat_contexts),
        "chat_timeline_turn_context_count": len(timeline_links),
        "counts_equal": len(original_contexts) == len(chat_contexts),
        "field_presence_equal": original_presence == chat_presence,
        "normalized_payloads_equal": original_normalized == chat_normalized,
        "timeline_links_all_valid": bool(timeline_links)
        and all(link["linked"] for link in timeline_links),
        "original_turn_contexts": original_summaries,
        "chat_journal_turn_contexts": chat_summaries,
        "chat_timeline_turn_context_links": timeline_links,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=validation_results_root()
        / (
            "app-server-turn-context-field-parity-smoke-"
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

    comparison = compare_turn_contexts(original_result, chat_result)
    original_lines = original_result["original_storage_summary"]["rollouts"][0]["line_count"]
    chat_lines = chat_result["chat_package_summary"]["packages"][0]["journal_line_count"]

    summary = {
        "generated_at": utc_now_iso(),
        "scope": "app-server-turn-context-field-parity-smoke",
        "gate_files_read": [
            "Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt",
            "Spec/Chat/README.md",
            "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md",
            "Conformance/Chat/CodexCliValidation/BASELINE_CHECKS.md",
            "Conformance/Chat/CodexCliValidation/CODEX_BACKEND_MAPPING.md",
            "Conformance/Chat/CodexCliValidation/PARITY_TEST_MATRIX.md",
            "Conformance/Chat/CodexCliValidation/PUBLIC_EVIDENCE.md",
        ],
        "binary_checks": binary_checks,
        "original_thread_read_normalized": original_result["normalized_thread_read"],
        "chat_backend_thread_read_normalized": chat_result["normalized_thread_read"],
        "normalized_thread_read_equal": (
            original_result["normalized_thread_read"]
            == chat_result["normalized_thread_read"]
        ),
        "original_rollout_line_count": original_lines,
        "chat_journal_line_count": chat_lines,
        "line_counts_equal": original_lines == chat_lines,
        **comparison,
        "not_yet_proven": [
            "optional TurnContextItem variants not present in this app-server slice",
            "strict-mode permission edge cases",
            "complete environment snapshot parity across all configuration variants",
            "final user-indistinguishability",
        ],
    }

    write_json(output_dir / "original/turn-context-response.json", original_result)
    write_json(output_dir / "chat-backend/turn-context-response.json", chat_result)
    write_json(output_dir / "summary.json", summary)

    report = f"""# App-Server Turn Context Field Parity Smoke - {summary['generated_at']}

This is retained validation evidence for the Codex `.chat` backend adaptation.
It drives the real `codex app-server` JSON-RPC stdio path for the original
backend and the `.chat` backend, then compares persisted `TurnContextItem`
payloads field by field.

## Gate

Before this work, the public `.chat` spec files, vendor manifest,
baseline checks, backend mapping, parity matrix, current data-fidelity report,
and current data-fidelity JSON were read.

## Scope

This smoke covers the `TurnContextItem` payload persisted by a completed
app-server turn. It compares original rollout `turn_context.payload` with the
`.chat` journal `source_transport.payload.payload`, normalizing only dynamic
turn ids and temporary run paths. It also checks that the `.chat` timeline
contains linked `runtime_context_snapshot` events for the turn context.

## Result

- original rollout line count equals `.chat` journal line count: `{summary['line_counts_equal']}`
- normalized `thread/read` response equal: `{summary['normalized_thread_read_equal']}`
- original turn context count: `{summary['original_turn_context_count']}`
- `.chat` journal turn context count: `{summary['chat_journal_turn_context_count']}`
- `.chat` timeline turn context snapshot count: `{summary['chat_timeline_turn_context_count']}`
- turn context counts equal: `{summary['counts_equal']}`
- turn context field presence equal: `{summary['field_presence_equal']}`
- normalized turn context payloads equal: `{summary['normalized_payloads_equal']}`
- timeline snapshot links all point to matching journal `turn_context`: `{summary['timeline_links_all_valid']}`

## Turn Context Comparison

```json
{json.dumps({'original': summary['original_turn_contexts'], 'chat-backend': summary['chat_journal_turn_contexts']}, indent=2, sort_keys=True)}
```

## Timeline Links

```json
{json.dumps(summary['chat_timeline_turn_context_links'], indent=2, sort_keys=True)}
```

## Evidence Files

```text
{output_dir.relative_to(VALIDATION_DIR)}/summary.json
{output_dir.relative_to(VALIDATION_DIR)}/original/turn-context-response.json
{output_dir.relative_to(VALIDATION_DIR)}/chat-backend/turn-context-response.json
```

## Not Yet Proven

This smoke does not prove optional `TurnContextItem` variants absent from this
run, strict-mode permission edge cases, complete environment snapshot parity
across every configuration variant, or final user-indistinguishability.
"""
    (output_dir / "report.md").write_text(report)
    print(json.dumps(summary, indent=2, sort_keys=True))

    ok = (
        summary["line_counts_equal"]
        and summary["normalized_thread_read_equal"]
        and summary["counts_equal"]
        and summary["original_turn_context_count"] >= 1
        and summary["field_presence_equal"]
        and summary["normalized_payloads_equal"]
        and summary["timeline_links_all_valid"]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
