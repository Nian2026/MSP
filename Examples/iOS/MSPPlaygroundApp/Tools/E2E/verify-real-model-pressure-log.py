#!/usr/bin/env python3
"""CLI wrapper for shared MSP real-model pressure event-log verification."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def conformance_scripts_dir() -> Path:
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "Conformance" / "Scripts" / "msp_pressure_evidence.py"
        if candidate.is_file():
            return candidate.parent
    raise SystemExit("could not locate Conformance/Scripts/msp_pressure_evidence.py")


sys.path.insert(0, str(conformance_scripts_dir()))

from msp_pressure_evidence import (  # noqa: E402
    REQUIRED_MODEL,
    verify_pressure_event_log_report,
    write_json_report,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify a real-model MSP pressure run."
    )
    parser.add_argument("event_log", type=Path)
    parser.add_argument("--expected-final-answers", type=int, default=2)
    parser.add_argument(
        "--required-final-sentinel",
        action="append",
        default=None,
        help="Sentinel that must appear in a non-feedback final answer. May be repeated.",
    )
    parser.add_argument(
        "--require-exec-session-contract",
        action="store_true",
        help="Require Codex-style yield/poll/PTY/stdin/interrupt evidence in the E2E event log.",
    )
    parser.add_argument(
        "--require-provider-smoke",
        action="store_true",
        help="Require checked provider-smoke evidence in the pressure report.",
    )
    parser.add_argument("--provider-smoke-request", type=Path)
    parser.add_argument("--provider-smoke-response", type=Path)
    parser.add_argument("--required-model", default=REQUIRED_MODEL)
    parser.add_argument("--model", help="Model id used for this real-model pressure suite.")
    parser.add_argument("--prompt-file", type=Path, help="Prompt JSON file used for this pressure suite.")
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        report, failures = verify_pressure_event_log_report(
            event_log=args.event_log,
            expected_final_answers=args.expected_final_answers,
            required_final_sentinels=args.required_final_sentinel,
            require_exec_session_contract=args.require_exec_session_contract,
            require_provider_smoke=args.require_provider_smoke,
            provider_smoke_request=args.provider_smoke_request,
            provider_smoke_response=args.provider_smoke_response,
            required_model=args.required_model,
            model=args.model,
            prompt_file=args.prompt_file,
        )
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    if args.report:
        write_json_report(args.report, report)

    if failures:
        raise SystemExit("\n".join(failures))

    print("real-model pressure log passed")
    print(f"event_log={args.event_log}")
    if args.report:
        print(f"report={args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
