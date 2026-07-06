"""Event-log evidence verification for MSP pressure gates."""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

from msp_pressure_contract import (
    EXEC_SESSION_CONTRACT_SUITES,
    REQUIRED_MODEL,
    REQUIRED_PROMPT_FILES,
    REQUIRED_SENTINELS,
    required_pressure_turn_count,
)
from msp_pressure_event_fields import TEXT_FIELDS_BY_EVENT, events_named, field
from msp_pressure_exec_session_contract import (
    exec_session_contract_summary,
    validate_exec_session_contract,
)
from msp_pressure_feedback_evidence import (
    find_forbidden_leaks,
    leak_kind_summary,
    validate_feedback_leak_quotes,
    validate_feedback_negative_evidence,
    validate_feedback_suspicious_output_quotes,
)
from msp_pressure_feedback_json import extract_json_object
from msp_pressure_model_provenance import model_response_provenance_summary
from msp_pressure_prompt_contract import (
    prompt_contract_error,
    prompt_contract_evidence,
    repository_root,
)
from msp_pressure_prompt_delivery import prompt_delivery_summary
from msp_pressure_json_support import (
    boolean_value,
    require_feedback_schema,
    string_list,
)
from msp_pressure_matrix_summary import (
    MODEL_RESPONSE_PROVENANCE_CORE_FIELDS,
    PROMPT_DELIVERY_CORE_FIELDS,
)
from msp_pressure_provider_smoke import build_provider_smoke_evidence


EXPECTED_EVENT_LOG_RELATIVE_PATH = Path("events.jsonl")
RUNTIME_PROVIDER_REQUEST_LAYER = "runtime_provider"
EXPECTED_EVENT_TOP_LEVEL_FIELDS = {"timestamp", "event", "fields"}
ISO8601_UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
TEXT_LIKE_EVENT_FIELD_NAMES = {
    "cmd",
    "content_text",
    "error_message",
    "message",
    "output",
    "output_text",
    "snippet",
    "status_text",
    "stderr",
    "stdout",
    "text",
    "visible_text",
}


def validate_event_timestamp(timestamp: Any, path: Path, line_number: int) -> datetime:
    if not isinstance(timestamp, str):
        raise ValueError(f"{path}:{line_number}: event timestamp must be a string")
    if not ISO8601_UTC_TIMESTAMP.fullmatch(timestamp):
        raise ValueError(f"{path}:{line_number}: event timestamp must be an ISO-8601 UTC timestamp")
    try:
        return datetime.fromisoformat(timestamp.removesuffix("Z") + "+00:00")
    except ValueError as exc:
        raise ValueError(f"{path}:{line_number}: event timestamp must be an ISO-8601 UTC timestamp") from exc


def validate_event_record(event: dict[str, Any], path: Path, line_number: int) -> datetime:
    unexpected_keys = sorted(set(event).difference(EXPECTED_EVENT_TOP_LEVEL_FIELDS))
    if unexpected_keys:
        raise ValueError(
            f"{path}:{line_number}: event has unexpected top-level field(s): "
            + ", ".join(unexpected_keys)
        )

    name = event.get("event")
    if not isinstance(name, str) or not name:
        raise ValueError(f"{path}:{line_number}: event must have a non-empty string event name")

    if "timestamp" not in event:
        raise ValueError(f"{path}:{line_number}: event timestamp is missing")
    timestamp = validate_event_timestamp(event["timestamp"], path, line_number)

    if "fields" not in event:
        raise ValueError(f"{path}:{line_number}: event fields are missing")
    fields = event["fields"]
    if not isinstance(fields, dict):
        raise ValueError(f"{path}:{line_number}: event fields must be a JSON object")
    invalid_keys = sorted(key for key in fields if not isinstance(key, str))
    if invalid_keys:
        raise ValueError(f"{path}:{line_number}: event field names must be strings")
    invalid_values = sorted(key for key, value in fields.items() if not isinstance(value, str))
    if invalid_values:
        raise ValueError(
            f"{path}:{line_number}: event field values must be strings: "
            + ", ".join(invalid_values)
        )
    registered_text_fields = set(TEXT_FIELDS_BY_EVENT.get(name, []))
    unregistered_text_fields = sorted(
        set(fields)
        .intersection(TEXT_LIKE_EVENT_FIELD_NAMES)
        .difference(registered_text_fields)
    )
    if unregistered_text_fields:
        raise ValueError(
            f"{path}:{line_number}: model-visible text field is not registered for event "
            f"{name}: " + ", ".join(unregistered_text_fields)
        )
    return timestamp


def load_events(path: Path) -> list[dict[str, Any]]:
    events = []
    previous_timestamp: datetime | None = None
    previous_line_number: int | None = None
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                raise ValueError(f"{path}:{line_number}: blank JSONL event line is not allowed")
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSONL: {exc}") from exc
            if not isinstance(event, dict):
                raise ValueError(f"{path}:{line_number}: event must be a JSON object")
            timestamp = validate_event_record(event, path, line_number)
            if previous_timestamp is not None and timestamp < previous_timestamp:
                raise ValueError(
                    f"{path}:{line_number}: event timestamp moved backwards; "
                    f"line {line_number} is earlier than line {previous_line_number}"
                )
            previous_timestamp = timestamp
            previous_line_number = line_number
            events.append(event)
    return events


def model_request_summary(events: list[dict[str, Any]], required_model: str, expected_count: int) -> dict[str, Any]:
    models = []
    layers = []
    failures = []
    for index, event in enumerate(events):
        if event.get("event") != "model_request_built":
            continue
        layer = field(event, "request_layer")
        if layer != RUNTIME_PROVIDER_REQUEST_LAYER:
            continue
        layers.append(layer)
        model = field(event, "model")
        if model:
            models.append(model)
        else:
            failures.append(f"event[{index}].model_request_built.model is missing")
    if not models and not failures:
        failures.append("model_request_built event is missing")
    if len(models) < expected_count:
        failures.append(f"model_request_built count {len(models)} is below expected pressure turn count {expected_count}")
    for model in models:
        if model != required_model:
            failures.append(f"model_request_built model is not {required_model}: {model}")
    return {
        "count": len(models),
        "expected_count": expected_count,
        "request_layers": layers,
        "models": sorted(set(models)),
        "all_match_required": not failures,
        "failures": failures,
    }

def required_sentinel_answer_indices(
    final_answers_before_feedback: list[str],
    required_final_sentinels: list[str],
    failures: list[str],
    missing_message_template: str,
    shared_message_prefix: str,
) -> dict[str, list[int]]:
    indices_by_sentinel: dict[str, list[int]] = {}
    sentinels_by_answer: dict[int, list[str]] = {}
    for sentinel in required_final_sentinels:
        indices = [
            index
            for index, answer in enumerate(final_answers_before_feedback)
            if sentinel in answer
        ]
        indices_by_sentinel[sentinel] = indices
        if not indices:
            failures.append(missing_message_template.format(sentinel=sentinel))
            continue
        if len(indices) > 1:
            rendered = ", ".join(f"final_answer[{index}]" for index in indices)
            failures.append(
                f"{shared_message_prefix}completion sentinel appears in multiple final answers: "
                f"{sentinel} at {rendered}"
            )
        for index in indices:
            sentinels_by_answer.setdefault(index, []).append(sentinel)

    for index, sentinels in sorted(sentinels_by_answer.items()):
        if len(sentinels) > 1:
            failures.append(
                f"{shared_message_prefix}completion sentinels share one final answer: "
                f"final_answer[{index}] contains " + ", ".join(sentinels)
            )
    if required_final_sentinels:
        for index in range(len(final_answers_before_feedback)):
            if index not in sentinels_by_answer:
                failures.append(
                    f"{shared_message_prefix}completion final_answer has no required sentinel: "
                    f"final_answer[{index}]"
                )
    return indices_by_sentinel

def verify_pressure_event_log_report(
    event_log: Path,
    expected_final_answers: int,
    required_final_sentinels: list[str] | None,
    require_exec_session_contract: bool,
    require_provider_smoke: bool,
    provider_smoke_request: Path | None,
    provider_smoke_response: Path | None,
    required_model: str = REQUIRED_MODEL,
    model: str | None = None,
    prompt_file: Path | None = None,
) -> tuple[dict[str, Any], list[str]]:
    events = load_events(event_log)
    runtime_errors = [field(event, "message") for event in events if event.get("event") == "runtime_error"]
    if runtime_errors:
        failures = ["runtime_error observed:\n" + "\n".join(runtime_errors)]
        return {
            "event_log": str(event_log),
            "passed": False,
            "failures": failures,
            "required_model": required_model,
            "model": model,
        }, failures

    failures: list[str] = []
    prompt_contract: dict[str, Any] | None = None
    prompt_delivery: dict[str, Any] | None = None
    if prompt_file is not None:
        try:
            prompt_contract = prompt_contract_evidence(prompt_file, repository_root())
            prompt_count = prompt_contract.get("prompt_count")
            if prompt_count != expected_final_answers:
                failures.append(
                    "prompt_contract.prompt_count does not match expected final answers: "
                    f"{prompt_count} != {expected_final_answers}"
                )
            prompt_sentinels = prompt_contract.get("required_final_sentinels")
            requested_sentinels = required_final_sentinels or ["PRESSURE_TASK_DONE"]
            if prompt_sentinels != requested_sentinels:
                failures.append("prompt_contract.required_final_sentinels does not match verifier sentinels")
        except ValueError as exc:
            failures.append(f"prompt_contract is invalid: {exc}")
            prompt_contract = prompt_contract_error(prompt_file, str(exc), repository_root())
        prompt_delivery = prompt_delivery_summary(
            events,
            prompt_file,
            expected_final_answers,
            failures,
        )
    tool_started = [event for event in events if event.get("event") == "tool_started"]
    tool_completed = [event for event in events if event.get("event") == "tool_completed"]
    if not tool_started or not tool_completed:
        failures.append("pressure run did not execute workspace commands")

    final_answers = [
        field(event, "text")
        for event in events
        if event.get("event") == "final_answer"
    ]
    if len(final_answers) < expected_final_answers:
        failures.append(f"expected at least {expected_final_answers} final answers; got {len(final_answers)}")
    if len(final_answers) > expected_final_answers:
        failures.append(f"expected no more than {expected_final_answers} final answers; got {len(final_answers)}")
    if any(not answer for answer in final_answers):
        failures.append("final_answer text was not captured; E2E text logging is required")

    required_final_sentinels = required_final_sentinels or ["PRESSURE_TASK_DONE"]
    final_answers_before_feedback = final_answers[:-1] or final_answers
    sentinel_answer_indices = required_sentinel_answer_indices(
        final_answers_before_feedback,
        required_final_sentinels,
        failures,
        "missing pressure completion sentinel: {sentinel}",
        "",
    )

    leaks = find_forbidden_leaks(events)
    if final_answers:
        try:
            feedback = extract_json_object(final_answers[-1])
        except ValueError as exc:
            failures.append(f"feedback answer is invalid: {exc}")
            feedback = {}
    else:
        feedback = {}

    require_feedback_schema(feedback, "feedback", failures)
    looks_like_linux = boolean_value(feedback.get("looks_like_regular_linux"), "looks_like_regular_linux", failures)
    can_distinguish = boolean_value(
        feedback.get("can_distinguish_from_regular_linux"),
        "can_distinguish_from_regular_linux",
        failures,
    )
    suspicious_outputs = string_list(feedback.get("suspicious_outputs"), "suspicious_outputs", failures)
    leaked_internal_paths = string_list(feedback.get("leaked_internal_paths"), "leaked_internal_paths", failures)
    validate_feedback_suspicious_output_quotes(suspicious_outputs, events, failures)
    validate_feedback_leak_quotes(leaked_internal_paths, events, failures)
    validate_feedback_negative_evidence(
        looks_like_linux,
        can_distinguish,
        suspicious_outputs,
        leaked_internal_paths,
        failures,
    )
    exec_session_summary = exec_session_contract_summary(events)
    request_model_summary = model_request_summary(events, required_model, expected_final_answers)
    model_response_provenance = model_response_provenance_summary(
        events,
        expected_final_answers,
        failures,
    )

    model_failures = []
    if not model:
        model_failures.append("pressure suite model is missing")
    elif model != required_model:
        model_failures.append(f"pressure suite model is not {required_model}: {model}")
    failures.extend(model_failures)
    failures.extend(request_model_summary["failures"])
    if leaks:
        failures.append("model-visible output leaked internal paths: " + json.dumps(leaks, ensure_ascii=False))
    if looks_like_linux is not True:
        failures.append("model feedback says the run did not look like a regular Linux workspace")
    if can_distinguish is True:
        failures.append("model feedback says it can distinguish this from a regular Linux workspace")
    if suspicious_outputs:
        failures.append("model reported suspicious outputs: " + json.dumps(suspicious_outputs, ensure_ascii=False))
    if leaked_internal_paths:
        failures.append("model reported leaked internal paths: " + json.dumps(leaked_internal_paths, ensure_ascii=False))
    if require_exec_session_contract:
        failures.extend(validate_exec_session_contract(exec_session_summary))
    provider_smoke = build_provider_smoke_evidence(
        provider_smoke_request,
        provider_smoke_response,
        require_provider_smoke,
        failures,
        required_model,
    )

    report = {
        "event_log": str(event_log),
        "passed": not failures,
        "failures": failures,
        "required_model": required_model,
        "model": model,
        "model_matches_required": not model_failures,
        "model_failures": model_failures,
        "model_request_built": request_model_summary,
        "final_answer_count": len(final_answers),
        "tool_started_count": len(tool_started),
        "tool_completed_count": len(tool_completed),
        "required_final_sentinels": required_final_sentinels,
        "required_final_sentinel_answer_indices": sentinel_answer_indices,
        "feedback": feedback,
        "scanner_leaks": leaks,
        "model_response_provenance": model_response_provenance,
        "exec_session_contract": exec_session_summary,
        "provider_smoke": provider_smoke,
    }
    if prompt_contract is not None:
        report["prompt_contract"] = prompt_contract
    if prompt_delivery is not None:
        report["prompt_delivery"] = prompt_delivery
    return report, failures


def resolve_event_log_path(raw_path: Any, report_path: Path, failures: list[str]) -> Path | None:
    if not isinstance(raw_path, str) or not raw_path:
        failures.append("event_log is missing or not a path string")
        return None
    base_dir = report_path.parent.resolve()
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        candidate = report_path.parent / candidate
    try:
        candidate.resolve().relative_to(base_dir)
    except ValueError:
        failures.append(f"event_log artifact is outside suite report directory: {raw_path}")
        return None
    expected = report_path.parent / EXPECTED_EVENT_LOG_RELATIVE_PATH
    if candidate.resolve() != expected.resolve():
        failures.append(f"event_log artifact does not match canonical suite path: expected {expected}, got {candidate}")
        return None
    if candidate.is_file():
        return candidate
    failures.append(f"event_log artifact does not exist: {raw_path}")
    return None


def compare_event_log_core_fields(
    section: str,
    report_value: Any,
    event_value: Any,
    fields: list[str],
    failures: list[str],
) -> None:
    if not isinstance(report_value, dict) or not isinstance(event_value, dict):
        if report_value != event_value:
            failures.append(f"{section} does not match event_log evidence")
        return
    for key in fields:
        if report_value.get(key) != event_value.get(key):
            failures.append(f"{section}.{key} does not match event_log evidence")


def compare_report_to_event_log(
    name: str,
    report: dict[str, Any],
    report_path: Path,
    failures: list[str],
    required_model: str,
) -> dict[str, Any]:
    event_path = resolve_event_log_path(report.get("event_log"), report_path, failures)
    if event_path is None:
        return {}
    try:
        events = load_events(event_path)
    except ValueError as exc:
        failures.append(str(exc))
        return {}

    runtime_errors = [field(event, "message") for event in events if event.get("event") == "runtime_error"]
    if runtime_errors:
        failures.append("event_log runtime_error observed: " + "; ".join(runtime_errors))

    required_sentinels = REQUIRED_SENTINELS.get(name, [])
    required_turn_count = required_pressure_turn_count(name)
    request_summary = model_request_summary(events, required_model, required_turn_count)
    model_response_provenance = model_response_provenance_summary(
        events,
        required_turn_count,
        failures,
        "event_log ",
    )
    prompt_delivery = {}
    if name in REQUIRED_PROMPT_FILES:
        prompt_delivery = prompt_delivery_summary(
            events,
            repository_root() / REQUIRED_PROMPT_FILES[name],
            required_turn_count,
            failures,
            "event_log ",
        )
    final_answers = [field(event, "text") for event in events if event.get("event") == "final_answer"]
    tool_started_count = len(events_named(events, "tool_started"))
    tool_completed_count = len(events_named(events, "tool_completed"))
    if len(final_answers) < required_turn_count:
        failures.append(f"event_log final_answer count {len(final_answers)} is below expected pressure turn count {required_turn_count}")
    if len(final_answers) > required_turn_count:
        failures.append(f"event_log final_answer count {len(final_answers)} is above expected pressure turn count {required_turn_count}")
    if tool_started_count <= 0 or tool_completed_count <= 0:
        failures.append("event_log did not execute workspace commands")
    final_answers_before_feedback = final_answers[:-1] or final_answers
    sentinel_answer_indices = required_sentinel_answer_indices(
        final_answers_before_feedback,
        required_sentinels,
        failures,
        "event_log is missing required sentinel: {sentinel}",
        "event_log ",
    )
    try:
        feedback = extract_json_object(final_answers[-1]) if final_answers else {}
    except ValueError as exc:
        failures.append(f"event_log feedback is invalid: {exc}")
        feedback = {}
    require_feedback_schema(feedback, "event_log feedback", failures)
    looks_like_linux = boolean_value(
        feedback.get("looks_like_regular_linux"),
        "looks_like_regular_linux",
        failures,
    )
    can_distinguish = boolean_value(
        feedback.get("can_distinguish_from_regular_linux"),
        "can_distinguish_from_regular_linux",
        failures,
    )
    suspicious_outputs = string_list(feedback.get("suspicious_outputs"), "suspicious_outputs", failures)
    leaked_internal_paths = string_list(feedback.get("leaked_internal_paths"), "leaked_internal_paths", failures)
    validate_feedback_suspicious_output_quotes(suspicious_outputs, events, failures, "event_log ")
    validate_feedback_leak_quotes(leaked_internal_paths, events, failures, "event_log ")
    validate_feedback_negative_evidence(
        looks_like_linux,
        can_distinguish,
        suspicious_outputs,
        leaked_internal_paths,
        failures,
        "event_log ",
    )
    leaks = find_forbidden_leaks(events)
    if leaks:
        failures.append("event_log scanner found model-visible internal path leaks: " + leak_kind_summary(leaks))
    event_summary: dict[str, Any] = {
        "model_request_built": request_summary,
        "final_answer_count": len(final_answers),
        "tool_started_count": tool_started_count,
        "tool_completed_count": tool_completed_count,
        "required_final_sentinels": required_sentinels,
        "required_final_sentinel_answer_indices": sentinel_answer_indices,
        "feedback": feedback,
        "scanner_leaks": leaks,
        "model_response_provenance": model_response_provenance,
        "prompt_delivery": prompt_delivery,
    }
    if name in EXEC_SESSION_CONTRACT_SUITES:
        event_summary["exec_session_contract"] = exec_session_contract_summary(events)

    for key in [
        "model_request_built",
        "required_final_sentinels",
        "required_final_sentinel_answer_indices",
        "scanner_leaks",
    ]:
        if report.get(key) != event_summary[key]:
            failures.append(f"{key} does not match event_log evidence")
    compare_event_log_core_fields(
        "model_response_provenance",
        report.get("model_response_provenance"),
        event_summary["model_response_provenance"],
        MODEL_RESPONSE_PROVENANCE_CORE_FIELDS,
        failures,
    )
    compare_event_log_core_fields(
        "prompt_delivery",
        report.get("prompt_delivery"),
        event_summary["prompt_delivery"],
        PROMPT_DELIVERY_CORE_FIELDS,
        failures,
    )
    report_feedback = report.get("feedback")
    event_feedback = event_summary["feedback"]
    if not isinstance(report_feedback, dict):
        failures.append("feedback does not match event_log evidence")
    else:
        for key in [
            "looks_like_regular_linux",
            "can_distinguish_from_regular_linux",
            "suspicious_outputs",
            "leaked_internal_paths",
            "notes",
        ]:
            if report_feedback.get(key) != event_feedback.get(key):
                failures.append(f"feedback.{key} does not match event_log evidence")
    for key in ["final_answer_count", "tool_started_count", "tool_completed_count"]:
        if report.get(key) != event_summary[key]:
            failures.append(f"{key} does not match event_log evidence: {report.get(key)} != {event_summary[key]}")
    if name in EXEC_SESSION_CONTRACT_SUITES:
        report_contract = report.get("exec_session_contract")
        if not isinstance(report_contract, dict):
            failures.append("exec_session_contract does not match event_log evidence")
        else:
            for key, value in report_contract.items():
                if event_summary["exec_session_contract"].get(key) != value:
                    failures.append(f"exec_session_contract.{key} does not match event_log evidence")
    return event_summary
