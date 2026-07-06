from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from msp_pressure_evidence import REQUIRED_MODEL

from .verifier import verify

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the final MSP exec-session release gate report and all referenced evidence artifacts."
    )
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--required-model", default=REQUIRED_MODEL)
    parser.add_argument("--summary-report", type=Path)
    return parser.parse_args()


def write_summary(path: Path, summary: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


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
    print("MSP final exec-session release gate report verified")
    print(f"report={args.report}")
    if args.summary_report:
        print(f"summary_report={args.summary_report}")
    return 0
