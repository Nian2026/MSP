#!/usr/bin/env python3
"""Verify that MSP release gates keep Readex as a read-only reference."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from final_gate_verifier_support.readex_boundary import verify_readex_boundary_root


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify MSP release scripts do not mutate or depend on Readex source."
    )
    parser.add_argument("--root", default=".", type=Path)
    parser.add_argument("--summary-report", type=Path)
    return parser.parse_args()


def verify(root: Path) -> dict[str, Any]:
    return verify_readex_boundary_root(root)


def write_summary(path: Path, summary: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    args = parse_args()
    try:
        summary = verify(args.root)
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

    print("MSP Readex boundary verified")
    if args.summary_report:
        print(f"summary_report={args.summary_report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
