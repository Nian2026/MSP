"""JSON and scalar validation helpers for MSP pressure evidence."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

EXPECTED_FEEDBACK_FIELDS = [
    "looks_like_regular_linux",
    "can_distinguish_from_regular_linux",
    "suspicious_outputs",
    "leaked_internal_paths",
    "notes",
]


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON file {path}: {exc}") from exc


def string_list(value: Any, name: str, failures: list[str]) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        failures.append(f"{name} is not a string array")
        return []
    return list(value)


def require_empty_string_list(value: Any, name: str, failures: list[str]) -> None:
    items = string_list(value, name, failures)
    if items:
        failures.append(f"{name} is not empty: " + "; ".join(items))


def boolean_value(value: Any, name: str, failures: list[str]) -> bool | None:
    if not isinstance(value, bool):
        failures.append(f"feedback field {name!r} must be a boolean; got {value!r}")
        return None
    return value


def require_feedback_schema(feedback: Any, name: str, failures: list[str]) -> None:
    if not isinstance(feedback, dict):
        failures.append(f"{name} is not an object")
        return
    missing = [field for field in EXPECTED_FEEDBACK_FIELDS if field not in feedback]
    unexpected = sorted(set(feedback).difference(EXPECTED_FEEDBACK_FIELDS))
    if missing:
        failures.append(f"{name} missing required field(s): " + ", ".join(missing))
    if unexpected:
        failures.append(f"{name} has unexpected field(s): " + ", ".join(unexpected))
    notes = feedback.get("notes")
    if not isinstance(notes, str) or not notes.strip():
        failures.append(f"{name}.notes must be a non-empty string")


def write_json_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
