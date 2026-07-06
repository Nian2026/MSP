"""Feedback and model-visible leak evidence for MSP pressure logs."""

from __future__ import annotations

from typing import Any

from msp_pressure_contract import FORBIDDEN_PATTERNS
from msp_pressure_event_fields import TEXT_FIELDS_BY_EVENT, field, model_visible_texts
from msp_pressure_feedback_json import extract_json_object
from msp_pressure_json_support import EXPECTED_FEEDBACK_FIELDS


FEEDBACK_CORE_FIELDS = set(EXPECTED_FEEDBACK_FIELDS)


def is_structured_feedback_text(text: str) -> bool:
    try:
        value = extract_json_object(text)
    except ValueError:
        return False
    return FEEDBACK_CORE_FIELDS.issubset(value.keys())


def structured_feedback_window(events: list[dict[str, Any]]) -> tuple[int | None, int | None]:
    final_answer_indices = [
        index for index, event in enumerate(events)
        if event.get("event") == "final_answer"
    ]
    if not final_answer_indices:
        return None, None
    feedback_index = final_answer_indices[-1]
    if not is_structured_feedback_text(field(events[feedback_index], "text")):
        return None, None
    previous_final_index = final_answer_indices[-2] if len(final_answer_indices) >= 2 else None
    return previous_final_index, feedback_index


def leak_patterns_for_source(
    event_index: int,
    event_name: str,
    field_name: str,
    feedback_window: tuple[int | None, int | None],
):
    previous_final_index, feedback_index = feedback_window
    if feedback_index is None:
        return FORBIDDEN_PATTERNS
    is_feedback_final_answer = event_index == feedback_index and event_name == "final_answer" and field_name == "text"
    is_feedback_delta = (
        event_name == "final_answer_delta"
        and field_name == "text"
        and (previous_final_index is None or event_index > previous_final_index)
        and event_index < feedback_index
    )
    if is_feedback_final_answer or is_feedback_delta:
        return [
            (label, pattern)
            for label, pattern in FORBIDDEN_PATTERNS
            if not label.startswith("plain_")
        ]
    return FORBIDDEN_PATTERNS


def find_forbidden_leaks(events: list[dict[str, Any]]) -> list[dict[str, str]]:
    leaks = []
    feedback_window = structured_feedback_window(events)
    for index, event in enumerate(events):
        name = event.get("event")
        for key in TEXT_FIELDS_BY_EVENT.get(name, []):
            text = field(event, key)
            if not text:
                continue
            source = f"event[{index}].{name}.{key}"
            for label, pattern in leak_patterns_for_source(index, str(name), key, feedback_window):
                for match in pattern.finditer(text):
                    leaks.append({"source": source, "kind": label, "match": match.group(0)})
    return leaks


def model_visible_texts_before_structured_feedback(events: list[dict[str, Any]]) -> list[str]:
    previous_final_index, feedback_index = structured_feedback_window(events)
    texts: list[str] = []
    for index, event in enumerate(events):
        name = str(event.get("event"))
        for key in TEXT_FIELDS_BY_EVENT.get(name, []):
            text = field(event, key)
            if not text:
                continue
            is_feedback_final_answer = (
                feedback_index is not None
                and index == feedback_index
                and name == "final_answer"
                and key == "text"
            )
            is_feedback_delta = (
                feedback_index is not None
                and name == "final_answer_delta"
                and key == "text"
                and (previous_final_index is None or index > previous_final_index)
                and index < feedback_index
            )
            if is_feedback_final_answer or is_feedback_delta:
                continue
            texts.append(text)
    return texts


def validate_feedback_observed_quotes(
    reported_values: list[str],
    report_label: str,
    events: list[dict[str, Any]],
    failures: list[str],
    prefix: str = "",
) -> None:
    if not reported_values:
        return
    observed_texts = model_visible_texts_before_structured_feedback(events)
    for reported_value in reported_values:
        if not any(reported_value in observed_text for observed_text in observed_texts):
            failures.append(
                f"{prefix}model reported {report_label} was not quoted from observed output: "
                f"{reported_value}"
            )


def validate_feedback_leak_quotes(
    leaked_internal_paths: list[str],
    events: list[dict[str, Any]],
    failures: list[str],
    prefix: str = "",
) -> None:
    validate_feedback_observed_quotes(
        leaked_internal_paths,
        "leaked internal path",
        events,
        failures,
        prefix,
    )


def validate_feedback_suspicious_output_quotes(
    suspicious_outputs: list[str],
    events: list[dict[str, Any]],
    failures: list[str],
    prefix: str = "",
) -> None:
    validate_feedback_observed_quotes(
        suspicious_outputs,
        "suspicious output",
        events,
        failures,
        prefix,
    )


def validate_feedback_negative_evidence(
    looks_like_linux: bool | None,
    can_distinguish: bool | None,
    suspicious_outputs: list[str],
    leaked_internal_paths: list[str],
    failures: list[str],
    prefix: str = "",
) -> None:
    if looks_like_linux is not False and can_distinguish is not True:
        return
    if suspicious_outputs or leaked_internal_paths:
        return
    failures.append(
        f"{prefix}model negative Linux feedback did not include suspicious_outputs "
        "or leaked_internal_paths evidence"
    )


def leak_kind_summary(leaks: list[Any]) -> str:
    kinds: list[str] = []
    for leak in leaks:
        if isinstance(leak, dict) and isinstance(leak.get("kind"), str):
            kinds.append(leak["kind"])
    if not kinds:
        return "unknown"
    return ", ".join(sorted(set(kinds)))
