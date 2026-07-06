#!/usr/bin/env python3
"""Verify the Debian 12 PTY oracle report used by release gates."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


DEFAULT_FIXTURE = "Conformance/ReferenceOutputs/MSPV1Debian12Oracle/pty-cases.json"
DEFAULT_COVERAGE = "Conformance/Fixtures/MSPV1PythonRuntimeCoverage.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify MSP Debian 12 PTY oracle report coverage and provenance."
    )
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--fixture", default=DEFAULT_FIXTURE, type=Path)
    parser.add_argument("--python-coverage", default=DEFAULT_COVERAGE, type=Path)
    parser.add_argument("--require-zero-failures", action="store_true")
    parser.add_argument("--require-linux-runner", action="store_true")
    parser.add_argument("--require-all-fixture-cases", action="store_true")
    parser.add_argument("--require-python-pty-cases", action="store_true")
    parser.add_argument("--expected-case-count", type=int)
    parser.add_argument("--summary-report", type=Path)
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
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


def integer(value: Any, name: str, failures: list[str]) -> int | None:
    if not isinstance(value, int):
        failures.append(f"{name} is not an integer")
        return None
    return value


def fixture_case_ids(fixture: dict[str, Any]) -> list[str]:
    cases = fixture.get("cases")
    if not isinstance(cases, list):
        raise ValueError("fixture.cases is not an array")
    ids: list[str] = []
    for index, case in enumerate(cases):
        if not isinstance(case, dict) or not isinstance(case.get("id"), str):
            raise ValueError(f"fixture.cases[{index}].id is missing")
        ids.append(case["id"])
    return ids


def pty_python_case_ids(coverage: dict[str, Any]) -> list[str]:
    gate = coverage.get("current_pty_runtime_gate")
    if not isinstance(gate, dict):
        gate = coverage.get("blocked_until_pty_runtime")
    if not isinstance(gate, dict):
        raise ValueError("coverage.current_pty_runtime_gate is missing")
    ids = gate.get("case_ids")
    if not isinstance(ids, list) or any(not isinstance(item, str) for item in ids):
        raise ValueError("coverage.current_pty_runtime_gate.case_ids is not a string array")
    return list(ids)


def looks_linux(report: dict[str, Any]) -> bool:
    platform = str(report.get("runnerPlatform") or "")
    lowered = platform.lower()
    if "macos" in lowered or "darwin" in lowered:
        return False
    return "linux" in lowered or "debian" in lowered


def verify(args: argparse.Namespace) -> dict[str, Any]:
    failures: list[str] = []
    report = load_json(args.report)
    fixture = load_json(args.fixture)
    fixture_ids = fixture_case_ids(fixture)
    fixture_id_set = set(fixture_ids)

    selected_count = integer(report.get("selectedCaseCount"), "selectedCaseCount", failures)
    passed_count = integer(report.get("passedCaseCount"), "passedCaseCount", failures)
    failed_count = integer(report.get("failedCaseCount"), "failedCaseCount", failures)
    passed_ids = string_list(report.get("passedCaseIDs"), "passedCaseIDs", failures)
    failed_ids = string_list(report.get("failedCaseIDs"), "failedCaseIDs", failures)

    if not isinstance(report.get("runnerBackend"), str):
        failures.append("runnerBackend is missing or not a string")
    if not isinstance(report.get("runnerPlatform"), str):
        failures.append("runnerPlatform is missing or not a string")
    if not isinstance(report.get("failures"), list):
        failures.append("failures is missing or not an array")

    selected_ids = set(passed_ids).union(failed_ids)
    unknown_ids = sorted(selected_ids.difference(fixture_id_set))
    if unknown_ids:
        failures.append("report contains case id(s) not in fixture: " + ", ".join(unknown_ids))

    if selected_count is not None and selected_count != len(selected_ids):
        failures.append(
            f"selectedCaseCount={selected_count} does not match selected ids={len(selected_ids)}"
        )
    if passed_count is not None and passed_count != len(passed_ids):
        failures.append(
            f"passedCaseCount={passed_count} does not match passed ids={len(passed_ids)}"
        )
    if failed_count is not None and failed_count != len(failed_ids):
        failures.append(
            f"failedCaseCount={failed_count} does not match failed ids={len(failed_ids)}"
        )

    if args.expected_case_count is not None and selected_count != args.expected_case_count:
        failures.append(
            f"selectedCaseCount={selected_count} does not match expected {args.expected_case_count}"
        )

    if args.require_zero_failures:
        if failed_count != 0 or failed_ids:
            failures.append("report has failed PTY oracle cases")

    if args.require_linux_runner and not looks_linux(report):
        failures.append("report runner is not proven Linux/Debian")

    if args.require_all_fixture_cases:
        missing = [case_id for case_id in fixture_ids if case_id not in selected_ids]
        if missing:
            failures.append("report did not select all fixture cases: " + ", ".join(missing[:20]))
        extra = sorted(selected_ids.difference(fixture_id_set))
        if extra:
            failures.append("report selected non-fixture cases: " + ", ".join(extra[:20]))

    python_pty_ids: list[str] = []
    if args.require_python_pty_cases:
        coverage = load_json(args.python_coverage)
        python_pty_ids = pty_python_case_ids(coverage)
        missing_python = [case_id for case_id in python_pty_ids if case_id not in passed_ids]
        if missing_python:
            failures.append(
                "PTY Python case(s) did not pass: " + ", ".join(missing_python)
            )

    return {
        "report": str(args.report),
        "fixture": str(args.fixture),
        "passed": not failures,
        "failures": failures,
        "selectedCaseCount": selected_count,
        "passedCaseCount": passed_count,
        "failedCaseCount": failed_count,
        "fixtureCaseCount": len(fixture_ids),
        "ptyPythonCaseCount": len(python_pty_ids),
        "runnerBackend": report.get("runnerBackend"),
        "runnerPlatform": report.get("runnerPlatform"),
    }


def write_summary(path: Path, summary: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    args = parse_args()
    try:
        summary = verify(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.summary_report:
        write_summary(args.summary_report, summary)

    if not summary["passed"]:
        if args.summary_report:
            print(f"summary_report={args.summary_report}", file=sys.stderr)
        for failure in summary["failures"]:
            print(failure, file=sys.stderr)
        return 1

    print("Debian PTY oracle report verified")
    print(f"report={args.report}")
    if args.summary_report:
        print(f"summary_report={args.summary_report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
