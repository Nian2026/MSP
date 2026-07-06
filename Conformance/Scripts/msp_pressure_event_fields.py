"""Typed field access for MSP pressure event logs."""

from __future__ import annotations

from typing import Any


TEXT_FIELDS_BY_EVENT = {
    "assistant_progress": ["text"],
    "assistant_progress_delta": ["text"],
    "tool_preparing": ["status_text"],
    "tool_started": ["cmd", "status_text"],
    "tool_output_delta": ["text"],
    "tool_completed": ["content_text", "error_message"],
    "final_answer_delta": ["text"],
    "final_answer": ["text"],
    "model_request_preparing": ["status_text"],
    "model_stream_retrying": ["status_text"],
    "probe_agent_runtime_bridge_run_before": ["cmd"],
    "probe_agent_runtime_bridge_run_after": ["cmd"],
    "runtime_error": ["message"],
    "transcript_visible_text_probe": ["snippet"],
}


def field(record: dict[str, Any], name: str) -> str:
    fields = record.get("fields") or {}
    value = fields.get(name) if isinstance(fields, dict) else None
    return value if isinstance(value, str) else ""


def field_int(record: dict[str, Any], name: str) -> int | None:
    value = field(record, name)
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def events_named(events: list[dict[str, Any]], name: str) -> list[dict[str, Any]]:
    return [event for event in events if event.get("event") == name]


def model_visible_texts(events: list[dict[str, Any]]):
    for index, event in enumerate(events):
        name = event.get("event")
        for key in TEXT_FIELDS_BY_EVENT.get(name, []):
            yield f"event[{index}].{name}.{key}", field(event, key)
