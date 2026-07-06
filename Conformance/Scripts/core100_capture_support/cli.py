from __future__ import annotations

import argparse
import os
from pathlib import Path

from .case_builder import default_identity_file_path, default_known_hosts_path
from .config import DEFAULT_CASES, DEFAULT_OUTPUT, DEFAULT_RAW_DIR
from .fixtures import generate_cases, merge_public_fixture, safety_audit_file, safety_self_test, validate_file
from .vps import run_vps


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate = subparsers.add_parser("generate-cases")
    generate.add_argument("--output", type=Path, default=DEFAULT_CASES)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--cases", type=Path, default=DEFAULT_CASES)

    safety_audit = subparsers.add_parser("safety-audit")
    safety_audit.add_argument("--cases", type=Path, default=DEFAULT_CASES)

    subparsers.add_parser("safety-self-test")

    merge = subparsers.add_parser("merge-public-fixture")
    merge.add_argument("--existing", type=Path, default=DEFAULT_OUTPUT)
    merge.add_argument("--partial", type=Path, required=True)
    merge.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)

    run = subparsers.add_parser("run-vps")
    run.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    run.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    run.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)
    run.add_argument(
        "--host",
        default=os.environ.get("MSP_VPS_HOST"),
        help="SSH host for the Debian reference runner. Required when MSP_VPS_HOST is unset.",
    )
    run.add_argument(
        "--known-hosts",
        type=Path,
        default=default_known_hosts_path(),
        help="Project-local SSH known_hosts file. StrictHostKeyChecking stays enabled.",
    )
    run.add_argument(
        "--identity-file",
        type=Path,
        default=default_identity_file_path(),
        help="SSH identity file for the VPS. Also enables IdentitiesOnly=yes.",
    )
    run.add_argument("--limit", type=int)
    run.add_argument("--case", action="append", default=[])
    args = parser.parse_args()
    if args.command == "run-vps" and not args.host:
        parser.error("run-vps requires --host or MSP_VPS_HOST")
    return args


def main() -> int:
    args = parse_args()
    if args.command == "generate-cases":
        return generate_cases(args.output)
    if args.command == "validate":
        return validate_file(args.cases)
    if args.command == "safety-audit":
        return safety_audit_file(args.cases)
    if args.command == "safety-self-test":
        return safety_self_test()
    if args.command == "merge-public-fixture":
        return merge_public_fixture(args.existing, args.partial, args.output)
    if args.command == "run-vps":
        return run_vps(
            args.cases,
            args.output,
            args.raw_dir,
            args.host,
            args.limit,
            args.case,
            args.known_hosts,
            args.identity_file,
        )
    raise AssertionError(args.command)
