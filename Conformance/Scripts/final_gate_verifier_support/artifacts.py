from __future__ import annotations

import json
from pathlib import Path
from typing import Any

def require_file(path_value: Any, name: str, failures: list[str]) -> Path | None:
    if not isinstance(path_value, str) or not path_value:
        failures.append(f"{name} is missing or not a path string")
        return None
    path = Path(path_value)
    if not path.is_file():
        failures.append(f"{name} does not exist: {path}")
        return None
    return path


def require_artifact_under_report_root(
    path: Path | None,
    name: str,
    report_root: Path,
    failures: list[str],
) -> None:
    if path is None:
        return
    try:
        path.resolve().relative_to(report_root.resolve())
    except ValueError:
        failures.append(f"{name} is outside final gate report directory: {path}")


def require_canonical_artifact_path(
    path: Path | None,
    expected: Path,
    name: str,
    failures: list[str],
) -> None:
    if path is None:
        return
    if path.resolve() != expected.resolve():
        failures.append(f"{name} does not match final gate canonical path: expected {expected}, got {path}")


def verify_report_out_dir(report: dict[str, Any], report_root: Path, failures: list[str]) -> None:
    out_dir = report.get("out_dir")
    if not isinstance(out_dir, str) or not out_dir:
        failures.append("final gate out_dir is missing or not a path string")
        return
    if Path(out_dir).resolve() != report_root.resolve():
        failures.append("final gate out_dir does not match report directory")


def load_json_from_text(text: str, name: str, failures: list[str]) -> dict[str, Any]:
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        failures.append(f"{name} does not contain a JSON object")
        return {}
    try:
        value = json.loads(text[start:end + 1])
    except json.JSONDecodeError as exc:
        failures.append(f"{name} contains invalid JSON: {exc}")
        return {}
    if not isinstance(value, dict):
        failures.append(f"{name} JSON is not an object")
        return {}
    return value


def looks_linux(report: dict[str, Any]) -> bool:
    platform = str(report.get("runnerPlatform") or "")
    lowered = platform.lower()
    if "darwin" in lowered or "macos" in lowered:
        return False
    return "linux" in lowered or "debian" in lowered
