"""Feedback JSON parsing helpers for MSP pressure gates."""

from __future__ import annotations

import json
from typing import Any


def extract_json_object(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        raise ValueError("feedback answer must be a raw JSON object, not Markdown fenced JSON")
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"feedback answer must be a JSON object: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("feedback JSON was not an object")
    return value
