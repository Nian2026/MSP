"""Prompt-delivery evidence verification for MSP pressure gates."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from msp_pressure_prompt_contract import prompt_delivery_contract, repository_root


RUNTIME_PROVIDER_REQUEST_LAYER = "runtime_provider"


def field(record: dict[str, Any], name: str) -> str:
    fields = record.get("fields") or {}
    value = fields.get(name) if isinstance(fields, dict) else None
    return value if isinstance(value, str) else ""


def field_int(record: dict[str, Any], name: str) -> int | None:
    text = field(record, name)
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def events_named(events: list[dict[str, Any]], name: str) -> list[dict[str, Any]]:
    return [event for event in events if event.get("event") == name]


def ordered_subsequence_indices(haystack: list[str], needles: list[str]) -> list[int] | None:
    indices: list[int] = []
    start = 0
    for needle in needles:
        try:
            offset = haystack[start:].index(needle)
        except ValueError:
            return None
        index = start + offset
        indices.append(index)
        start = index + 1
    return indices


def prompt_delivery_summary(
    events: list[dict[str, Any]],
    prompt_file: Path,
    expected_count: int,
    failures: list[str],
    prefix: str = "",
) -> dict[str, Any]:
    local_failures: list[str] = []
    try:
        expected = prompt_delivery_contract(prompt_file, repository_root())
    except ValueError as exc:
        local_failures.append(f"prompt_delivery is invalid: {exc}")
        evidence = {
            "passed": False,
            "failures": local_failures,
            "path": str(prompt_file),
            "hash_algorithm": "sha256-utf8",
            "prompt_count": 0,
            "prompt_sha256s": [],
            "auto_submit_sequence_loaded_count": 0,
            "auto_submit_count": 0,
            "auto_submit_indices": [],
        }
        failures.extend(f"{prefix}{failure}" for failure in local_failures)
        return evidence

    expected_hashes = expected["prompt_sha256s"]
    sequence_events = events_named(events, "auto_submit_sequence_loaded")
    auto_submit_events = events_named(events, "auto_submit")
    model_request_events = [
        event
        for event in events_named(events, "model_request_built")
        if field(event, "request_layer") == RUNTIME_PROVIDER_REQUEST_LAYER
    ]
    final_answer_events = events_named(events, "final_answer")
    indices = [field_int(event, "prompt_index") for event in auto_submit_events]
    request_hashes = [field(event, "request_last_user_input_sha256") for event in model_request_events]
    final_answer_hashes = [
        field(event, "request_last_user_input_sha256")
        for event in final_answer_events
    ]
    request_layers = [field(event, "request_layer") for event in model_request_events]
    request_prompt_match_indices = ordered_subsequence_indices(request_hashes, expected_hashes)
    evidence = {
        "passed": True,
        "failures": [],
        "path": expected["path"],
        "hash_algorithm": expected["hash_algorithm"],
        "prompt_count": expected["prompt_count"],
        "prompt_sha256s": expected_hashes,
        "auto_submit_sequence_loaded_count": len(sequence_events),
        "auto_submit_count": len(auto_submit_events),
        "auto_submit_indices": indices,
        "model_request_count": len(model_request_events),
        "model_request_layers": request_layers,
        "model_request_last_user_input_sha256s": request_hashes,
        "model_request_prompt_match_indices": request_prompt_match_indices or [],
        "final_answer_request_last_user_input_sha256s": final_answer_hashes,
    }

    if expected["prompt_count"] != expected_count:
        local_failures.append(
            f"prompt_delivery.prompt_count does not match expected final answers: {expected['prompt_count']} != {expected_count}"
        )
    if len(sequence_events) != 1:
        local_failures.append(
            f"prompt_delivery expected exactly one auto_submit_sequence_loaded event; got {len(sequence_events)}"
        )
    for event in sequence_events:
        if field(event, "prompt_hash_algorithm") != "sha256-utf8":
            local_failures.append("prompt_delivery auto_submit_sequence_loaded.prompt_hash_algorithm is not sha256-utf8")
        if field_int(event, "prompt_count") != expected_count:
            local_failures.append("prompt_delivery auto_submit_sequence_loaded.prompt_count does not match prompt file")
        if field(event, "prompt_sha256s") != ",".join(expected_hashes):
            local_failures.append("prompt_delivery auto_submit_sequence_loaded.prompt_sha256s does not match prompt file")

    if len(auto_submit_events) != expected_count:
        local_failures.append(f"prompt_delivery expected {expected_count} auto_submit events; got {len(auto_submit_events)}")
    if indices != list(range(1, expected_count + 1)):
        local_failures.append("prompt_delivery auto_submit prompt_index sequence does not match prompt file order")
    for index, event in enumerate(auto_submit_events, start=1):
        expected_hash = expected_hashes[index - 1] if index <= len(expected_hashes) else None
        if field(event, "prompt_hash_algorithm") != "sha256-utf8":
            local_failures.append(f"prompt_delivery auto_submit[{index}].prompt_hash_algorithm is not sha256-utf8")
        if field_int(event, "prompt_count") != expected_count:
            local_failures.append(f"prompt_delivery auto_submit[{index}].prompt_count does not match prompt file")
        if expected_hash is not None and field(event, "prompt_sha256") != expected_hash:
            local_failures.append(f"prompt_delivery auto_submit[{index}].prompt_sha256 does not match prompt file")

    if len(model_request_events) < expected_count:
        local_failures.append(
            f"prompt_delivery expected at least {expected_count} model_request_built events; got {len(model_request_events)}"
        )
    for index, event in enumerate(model_request_events, start=1):
        if field(event, "request_user_input_hash_algorithm") != "sha256-utf8":
            local_failures.append(f"prompt_delivery model_request_built[{index}].request_user_input_hash_algorithm is not sha256-utf8")
        request_user_input_count = field_int(event, "request_user_input_count")
        if request_user_input_count is None or request_user_input_count <= 0:
            local_failures.append(f"prompt_delivery model_request_built[{index}].request_user_input_count must be positive")
        if not field(event, "request_last_user_input_sha256"):
            local_failures.append(f"prompt_delivery model_request_built[{index}].request_last_user_input_sha256 is missing")
    if request_prompt_match_indices is None:
        local_failures.append("prompt_delivery model_request_built request_last_user_input_sha256s do not contain prompt hashes in order")
    if len(final_answer_hashes) != expected_count:
        local_failures.append(
            "prompt_delivery final_answer_request_last_user_input_sha256s does not match prompt file count"
        )
    elif final_answer_hashes != expected_hashes:
        local_failures.append(
            "prompt_delivery final_answer_request_last_user_input_sha256s do not match prompt file order"
        )

    if local_failures:
        evidence["passed"] = False
        evidence["failures"] = local_failures
        failures.extend(f"{prefix}{failure}" for failure in local_failures)
    return evidence
