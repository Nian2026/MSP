#!/usr/bin/env python3
"""Verify the live noninteractive Linux/VPS oracle report."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


DEFAULT_FIXTURE = "Conformance/ReferenceOutputs/MSPV1Debian12Oracle/noninteractive-cases.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify live noninteractive Linux/VPS oracle report coverage and provenance."
    )
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--fixture", default=DEFAULT_FIXTURE, type=Path)
    parser.add_argument("--require-zero-failures", action="store_true")
    parser.add_argument("--require-linux-runner", action="store_true")
    parser.add_argument("--require-debian12-runner", action="store_true")
    parser.add_argument("--require-all-fixture-cases", action="store_true")
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


def looks_linux(report: dict[str, Any]) -> bool:
    system = str(report.get("runnerSystem") or "")
    platform = str(report.get("runnerPlatform") or "")
    os_release = str(report.get("runnerOSRelease") or "")
    combined = "\n".join([system, platform, os_release]).lower()
    if "darwin" in combined or "macos" in combined:
        return False
    return "linux" in combined or "debian" in combined


def looks_debian12(report: dict[str, Any]) -> bool:
    os_release = str(report.get("runnerOSRelease") or "").lower()
    platform = str(report.get("runnerPlatform") or "").lower()
    combined = os_release + "\n" + platform
    return ("id=debian" in combined or "debian" in combined) and (
        'version_id="12"' in combined or "version_id=12" in combined or "bookworm" in combined
    )


def verify(args: argparse.Namespace) -> dict[str, Any]:
    failures: list[str] = []
    report = load_json(args.report)
    fixture = load_json(args.fixture)
    fixture_ids = fixture_case_ids(fixture)
    fixture_id_set = set(fixture_ids)

    if report.get("gate") != "msp-live-noninteractive-linux-vps-oracle":
        failures.append("live VPS oracle gate is not msp-live-noninteractive-linux-vps-oracle")
    if report.get("artifactKind") != "msp-live-noninteractive-linux-vps-oracle":
        failures.append("live VPS oracle artifactKind is wrong")
    if report.get("liveRun") is not True:
        failures.append("live VPS oracle report does not prove a live run")
    if report.get("runnerBackend") != "ssh-linux-vps":
        failures.append("live VPS oracle runnerBackend is not ssh-linux-vps")
    if not isinstance(report.get("runnerHost"), str) or not report.get("runnerHost"):
        failures.append("live VPS oracle runnerHost is missing")
    if not isinstance(report.get("runnerPlatform"), str) or not report.get("runnerPlatform"):
        failures.append("live VPS oracle runnerPlatform is missing")
    if not isinstance(report.get("runnerOSRelease"), str) or not report.get("runnerOSRelease"):
        failures.append("live VPS oracle runnerOSRelease is missing")

    selected_count = integer(report.get("selectedCaseCount"), "selectedCaseCount", failures)
    passed_count = integer(report.get("passedCaseCount"), "passedCaseCount", failures)
    failed_count = integer(report.get("failedCaseCount"), "failedCaseCount", failures)
    fixture_count = integer(report.get("fixtureCaseCount"), "fixtureCaseCount", failures)
    passed_ids = string_list(report.get("passedCaseIDs"), "passedCaseIDs", failures)
    failed_ids = string_list(report.get("failedCaseIDs"), "failedCaseIDs", failures)

    if fixture_count is not None and fixture_count != len(fixture_ids):
        failures.append(f"fixtureCaseCount={fixture_count} does not match fixture cases={len(fixture_ids)}")

    selected_ids = set(passed_ids).union(failed_ids)
    unknown_ids = sorted(selected_ids.difference(fixture_id_set))
    if unknown_ids:
        failures.append("report contains case id(s) not in fixture: " + ", ".join(unknown_ids))

    if selected_count is not None and selected_count != len(selected_ids):
        failures.append(f"selectedCaseCount={selected_count} does not match selected ids={len(selected_ids)}")
    if passed_count is not None and passed_count != len(passed_ids):
        failures.append(f"passedCaseCount={passed_count} does not match passed ids={len(passed_ids)}")
    if failed_count is not None and failed_count != len(failed_ids):
        failures.append(f"failedCaseCount={failed_count} does not match failed ids={len(failed_ids)}")

    if args.expected_case_count is not None and selected_count != args.expected_case_count:
        failures.append(f"selectedCaseCount={selected_count} does not match expected {args.expected_case_count}")

    runner_failures = report.get("runnerFailures")
    if not isinstance(runner_failures, list) or runner_failures:
        failures.append("live VPS oracle runnerFailures is missing or non-empty")
    if not isinstance(report.get("failures"), list):
        failures.append("live VPS oracle failures is missing or not an array")

    if args.require_zero_failures:
        if report.get("passed") is not True:
            failures.append("live VPS oracle report did not pass")
        if failed_count != 0 or failed_ids:
            failures.append("report has failed live noninteractive oracle cases")

    if args.require_linux_runner and not looks_linux(report):
        failures.append("report runner is not proven Linux/Debian")
    if args.require_debian12_runner and not looks_debian12(report):
        failures.append("report runner is not proven Debian 12/bookworm")

    if args.require_all_fixture_cases:
        missing = [case_id for case_id in fixture_ids if case_id not in selected_ids]
        if missing:
            failures.append("report did not select all fixture cases: " + ", ".join(missing[:20]))
        extra = sorted(selected_ids.difference(fixture_id_set))
        if extra:
            failures.append("report selected non-fixture cases: " + ", ".join(extra[:20]))

    compatibility = report.get("compatibilityAdjustments")
    if not isinstance(compatibility, list) or compatibility:
        failures.append("live VPS oracle compatibilityAdjustments is missing or non-empty")

    return {
        "report": str(args.report),
        "fixture": str(args.fixture),
        "passed": not failures,
        "failures": failures,
        "selectedCaseCount": selected_count,
        "passedCaseCount": passed_count,
        "failedCaseCount": failed_count,
        "fixtureCaseCount": len(fixture_ids),
        "runnerBackend": report.get("runnerBackend"),
        "runnerHost": report.get("runnerHost"),
        "runnerPlatform": report.get("runnerPlatform"),
        "runnerOSRelease": report.get("runnerOSRelease"),
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
    print("Live noninteractive Linux VPS oracle report verified")
    print(f"report={args.report}")
    if args.summary_report:
        print(f"summary_report={args.summary_report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
