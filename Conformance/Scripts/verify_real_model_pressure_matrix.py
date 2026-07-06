#!/usr/bin/env python3
"""Verify the required MSP real-model pressure suite matrix."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from msp_pressure_evidence import (
    REQUIRED_MODEL,
    REQUIRED_PRESSURE_SUITES,
    summarize_suite,
)


def parse_suite(argument: str) -> tuple[str, Path]:
    if "=" not in argument:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    name, raw_path = argument.split("=", 1)
    name = name.strip()
    if not name:
        raise argparse.ArgumentTypeError("suite name cannot be empty")
    return name, Path(raw_path)


def write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def canonical_suite_report_path(root: Path, suite: str) -> Path:
    return root / suite / "pressure-report.json"


def suite_path_failures_for_root(root: Path, suites: dict[str, Path]) -> list[str]:
    failures: list[str] = []
    for name, path in suites.items():
        if name not in REQUIRED_PRESSURE_SUITES:
            continue
        expected_path = canonical_suite_report_path(root, name)
        if path.resolve() != expected_path.resolve():
            failures.append(
                f"suite path does not match canonical matrix root path: {name}"
            )
    return failures


def duplicate_suite_names(suite_arguments: list[tuple[str, Path]]) -> list[str]:
    seen: set[str] = set()
    duplicates: set[str] = set()
    for name, _ in suite_arguments:
        if name in seen:
            duplicates.add(name)
        seen.add(name)
    return sorted(duplicates)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the required MSP real-model pressure report matrix."
    )
    parser.add_argument(
        "--suite",
        action="append",
        type=parse_suite,
        default=[],
        metavar="NAME=PATH",
        help="Suite report path. Expected names are the required pressure suite ids.",
    )
    parser.add_argument("--root", type=Path, help="Root containing required suite subdirectories.")
    parser.add_argument("--report", type=Path, help="Matrix JSON report to write.")
    parser.add_argument("--required-model", default=REQUIRED_MODEL)
    parser.add_argument("--model", help="Model id used for the real-model pressure suites.")
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help="Write a partial matrix report instead of requiring all suites.",
    )
    args = parser.parse_args()

    duplicates = duplicate_suite_names(args.suite)
    if duplicates:
        print("duplicate pressure suite(s): " + ", ".join(duplicates), file=sys.stderr)
        return 2

    suites = dict(args.suite)
    if args.root:
        for name in REQUIRED_PRESSURE_SUITES:
            suites.setdefault(name, canonical_suite_report_path(args.root, name))

    unknown = sorted(set(suites).difference(REQUIRED_PRESSURE_SUITES))
    if unknown:
        print("unknown pressure suite(s): " + ", ".join(unknown), file=sys.stderr)
        return 2

    if args.root:
        path_failures = suite_path_failures_for_root(args.root, suites)
        if path_failures:
            for failure in path_failures:
                print(failure, file=sys.stderr)
            return 2

    missing = [name for name in REQUIRED_PRESSURE_SUITES if name not in suites]
    if missing and not args.allow_partial:
        print("missing required pressure suite(s): " + ", ".join(missing), file=sys.stderr)
        return 2

    model_failures = []
    if not args.model:
        model_failures.append("pressure matrix model is missing")
    elif args.model != args.required_model:
        model_failures.append(f"pressure matrix model is not {args.required_model}: {args.model}")

    suite_summaries = {
        name: summarize_suite(name, suites[name], args.required_model)
        for name in REQUIRED_PRESSURE_SUITES
        if name in suites
    }
    all_required_suites_present = not missing
    model_matches_required = not model_failures
    matrix_passed = model_matches_required and all_required_suites_present and all(
        summary.get("passed") is True
        for summary in suite_summaries.values()
    )

    matrix_report = {
        "required_model": args.required_model,
        "model": args.model,
        "model_matches_required": model_matches_required,
        "required_suites": REQUIRED_PRESSURE_SUITES,
        "all_required_suites_present": all_required_suites_present,
        "missing_suites": missing,
        "model_failures": model_failures,
        "matrix_passed": matrix_passed,
        "suite_count": len(suite_summaries),
        "suites": suite_summaries,
    }
    if args.report:
        write_report(args.report, matrix_report)

    if not matrix_passed:
        if args.report:
            print(f"report={args.report}", file=sys.stderr)
        for failure in model_failures:
            print(failure, file=sys.stderr)
        for name, summary in suite_summaries.items():
            for failure in summary.get("failures", []):
                print(f"{name}: {failure}", file=sys.stderr)
        if missing:
            print("missing required pressure suite(s): " + ", ".join(missing), file=sys.stderr)
        return 1

    print("real-model pressure matrix passed")
    if args.report:
        print(f"report={args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
