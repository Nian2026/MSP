#!/usr/bin/env python3
"""Fail-fast gate for MSP Core100 closure.

This script is intentionally stricter than the ordinary Swift test suite. It
checks whether the declared Core100 inventory, compatibility attack matrix,
oracle capture fixture, local Linux source snapshot, and safety audit are all
in a state where a parent agent may even start claiming full closure.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[2]
REQUIRED_COMMANDS = ROOT / "Conformance" / "Fixtures" / "MSPV1LinuxCommandLayer.required-commands.json"
MATRIX_ROOT = ROOT / "Conformance" / "Inventory" / "CommandCompatibilityDrafts"
CAPTURE_CASES = ROOT / "Conformance" / "OracleCapture" / "Core100CaptureCases.generated.json"
SOURCE_ROOT = ROOT / "References" / "LinuxSourceSnapshot" / "debian12-bookworm" / "sources"

EXPECTED_BATCHES: dict[str, list[str]] = {
    "batch-01-shell-path-runtime.md": [
        ":",
        "[",
        "[[",
        "basename",
        "builtin",
        "cd",
        "command",
        "dirname",
        "echo",
        "env",
        "false",
        "printf",
        "printenv",
        "pwd",
        "test",
        "true",
        "type",
        "which",
    ],
    "batch-02-filesystem.md": [
        "chmod",
        "cp",
        "du",
        "find",
        "install",
        "link",
        "ln",
        "ls",
        "mkdir",
        "mktemp",
        "mv",
        "rm",
        "rmdir",
        "touch",
        "tree",
        "truncate",
        "unlink",
    ],
    "batch-03-text-streams.md": [
        "cat",
        "comm",
        "cut",
        "expand",
        "fmt",
        "fold",
        "grep",
        "head",
        "join",
        "nl",
        "paste",
        "sort",
        "tail",
        "tac",
        "tee",
        "tr",
        "uniq",
        "unexpand",
        "wc",
        "yes",
    ],
    "batch-04-text-languages-search.md": [
        "awk",
        "sed",
        "rg",
        "xargs",
        "seq",
        "shuf",
        "strings",
        "tsort",
        "split",
    ],
    "batch-05-data-comparison-numeric.md": [
        "b2sum",
        "base32",
        "base64",
        "basenc",
        "bc",
        "cksum",
        "cmp",
        "date",
        "dd",
        "diff",
        "expr",
        "factor",
        "md5sum",
        "numfmt",
        "od",
        "sha1sum",
        "sha256sum",
        "sha512sum",
        "sum",
        "xxd",
    ],
    "batch-06-metadata-process-identity.md": [
        "file",
        "groups",
        "hostname",
        "id",
        "ldd",
        "nproc",
        "pathchk",
        "ps",
        "readlink",
        "realpath",
        "sleep",
        "stat",
        "timeout",
        "tty",
        "uname",
        "whoami",
    ],
}

REQUIRED_SOURCE_DIRS = [
    "bash-5.2.15",
    "bc-1.07.1",
    "binutils-2.40",
    "coreutils-9.1",
    "dash-0.5.12",
    "debianutils-5.7",
    "diffutils-3.8",
    "file-5.44",
    "findutils-4.9.0",
    "glibc-2.36",
    "grep-3.8",
    "hostname-3.23+nmu1",
    "mawk-1.3.4-20200120",
    "procps-ng-4.0.2",
    "ripgrep-13.0.0",
    "sed-4.9",
    "tree-2.1.0",
    "vim-9.0.1378",
]

COMMAND_FIELD_RE = re.compile(r"^- (?:\*\*)?Command(?:\*\*)?: `([^`]+)`", re.MULTILINE)
OPEN_MARKERS = [
    "Still open implementation",
    "Still open oracle/stress",
]
OPEN_AFTER_FIELD_RE = re.compile(
    r"^\s*- \*\*(Implementation open after this batch|Oracle/stress open after this batch)\*\*: (.+)$",
    re.MULTILINE,
)
UNRESOLVED_FIELD_RE = re.compile(
    r"^\s*- (?:\*\*)?(Must implement|Oracle/stress gaps)(?:\*\*)?:\s*(.+)$",
    re.MULTILINE,
)
UNRESOLVED_PHRASES = [
    "parent request",
    "parent-owned",
    "parent owned",
    "parent should",
    "parent sampling",
    "needs parent",
    "still needs",
    "remaining debt",
    "open debt",
    "implementation debt",
    "compatibility debt",
    "not closed",
    "missing:",
]


def is_none_value(value: str) -> bool:
    normalized = value.strip().lower()
    return (
        normalized.startswith("none")
        or normalized.startswith("no remaining")
        or normalized.startswith("no open")
        or normalized.startswith("nothing remaining")
    )


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def fail(message: str, failures: list[str]) -> None:
    failures.append(message)


def summarize_failures_by_file(failures: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for message in failures:
        if message.startswith("Conformance/"):
            file_name = message.split(" ", 1)[0]
        else:
            file_name = "<global>"
        counts[file_name] = counts.get(file_name, 0) + 1
    return dict(sorted(counts.items()))


def check_inventory(failures: list[str]) -> list[str]:
    data = load_json(REQUIRED_COMMANDS)
    commands = data.get("commands", [])
    names = [command.get("name") for command in commands]
    implemented = [command.get("name") for command in commands if command.get("status") == "implemented"]
    batch_names = [name for names_in_batch in EXPECTED_BATCHES.values() for name in names_in_batch]

    if len(names) != 100:
        fail(f"required command inventory must contain 100 commands, found {len(names)}", failures)
    if len(set(names)) != len(names):
        duplicates = sorted({name for name in names if names.count(name) > 1})
        fail(f"required command inventory contains duplicates: {duplicates}", failures)
    if sorted(implemented) != sorted(names):
        missing_status = sorted(set(names) - set(implemented))
        fail(f"all Core100 commands must be declared implemented before closure, missing: {missing_status}", failures)
    if sorted(batch_names) != sorted(names):
        fail(
            "batch assignment must exactly match required command inventory: "
            f"missing_from_batches={sorted(set(names) - set(batch_names))}, "
            f"extra_in_batches={sorted(set(batch_names) - set(names))}",
            failures,
        )
    if len(set(batch_names)) != len(batch_names):
        duplicates = sorted({name for name in batch_names if batch_names.count(name) > 1})
        fail(f"batch assignment contains duplicate commands: {duplicates}", failures)
    return names


def check_matrix(failures: list[str]) -> None:
    for file_name, expected_commands in EXPECTED_BATCHES.items():
        path = MATRIX_ROOT / file_name
        if not path.exists():
            fail(f"missing compatibility matrix file: {path.relative_to(ROOT)}", failures)
            continue
        text = path.read_text(encoding="utf-8")
        found_commands = COMMAND_FIELD_RE.findall(text)
        if found_commands != expected_commands:
            fail(
                f"{path.relative_to(ROOT)} command sections mismatch: "
                f"expected={expected_commands}, found={found_commands}",
                failures,
            )
        for marker in OPEN_MARKERS:
            marker_count = text.count(marker)
            if marker_count:
                fail(
                    f"{path.relative_to(ROOT)} still contains {marker_count} `{marker}` marker(s)",
                    failures,
                )
        for field_name, value in OPEN_AFTER_FIELD_RE.findall(text):
            if not is_none_value(value):
                fail(
                    f"{path.relative_to(ROOT)} has unresolved `{field_name}`: {value.strip()}",
                    failures,
                )
        for field_name, value in UNRESOLVED_FIELD_RE.findall(text):
            if not is_none_value(value):
                fail(
                    f"{path.relative_to(ROOT)} has non-empty `{field_name}`: {value.strip()}",
                    failures,
                )
        lower_text = text.lower()
        for phrase in UNRESOLVED_PHRASES:
            phrase_count = lower_text.count(phrase)
            if phrase_count:
                fail(
                    f"{path.relative_to(ROOT)} contains {phrase_count} unresolved `{phrase}` phrase(s)",
                    failures,
                )
        if "Reference source" not in text:
            fail(f"{path.relative_to(ROOT)} has no source reference evidence", failures)
        if "Performance model" not in text:
            fail(f"{path.relative_to(ROOT)} has no performance model evidence", failures)
        if "Oracle/stress gaps" not in text:
            fail(f"{path.relative_to(ROOT)} has no oracle/stress evidence", failures)


def check_sources(failures: list[str]) -> None:
    missing = [name for name in REQUIRED_SOURCE_DIRS if not (SOURCE_ROOT / name).is_dir()]
    if missing:
        fail(f"missing local Linux source snapshot directories: {missing}", failures)


def check_capture_fixture(required_commands: list[str], failures: list[str]) -> None:
    data = load_json(CAPTURE_CASES)
    cases = data.get("cases", [])
    summary = data.get("summary", {})
    per_command = summary.get("per_command_case_count", {})

    if len(cases) != summary.get("case_count"):
        fail(f"capture fixture case_count mismatch: len(cases)={len(cases)} summary={summary.get('case_count')}", failures)
    if summary.get("core100_command_count") != 100:
        fail(f"summary.core100_command_count must be 100, found {summary.get('core100_command_count')}", failures)
    if summary.get("covered_core100_command_count") != 100:
        fail(
            "summary.covered_core100_command_count must be 100, "
            f"found {summary.get('covered_core100_command_count')}",
            failures,
        )
    if summary.get("missing_core100_commands") != []:
        fail(f"summary.missing_core100_commands must be empty, found {summary.get('missing_core100_commands')}", failures)
    if summary.get("shell_stress_case_count", 0) < 57:
        fail(f"shell_stress_case_count must be at least 57, found {summary.get('shell_stress_case_count')}", failures)

    missing_cases = [name for name in required_commands if per_command.get(name, 0) <= 0]
    if missing_cases:
        fail(f"commands without oracle cases: {missing_cases}", failures)

    unsafe_cases = []
    for item in cases:
        case_id = item.get("id", "<missing>")
        if not item.get("command_line"):
            unsafe_cases.append(f"{case_id}: missing command_line")
        if "standard_input_b64" not in item:
            unsafe_cases.append(f"{case_id}: missing standard_input_b64")
        fixture = item.get("fixture", {})
        if fixture.get("kind") != "isolated-temp-tree":
            unsafe_cases.append(f"{case_id}: fixture.kind must be isolated-temp-tree")
        if item.get("timeout_seconds", 0) <= 0:
            unsafe_cases.append(f"{case_id}: timeout_seconds must be positive")
        if not item.get("commands"):
            unsafe_cases.append(f"{case_id}: missing commands")
        if not item.get("compare_fields"):
            unsafe_cases.append(f"{case_id}: missing compare_fields")
    if unsafe_cases:
        fail("capture fixture structural failures:\n  " + "\n  ".join(unsafe_cases[:50]), failures)


def run_safety_audit(failures: list[str]) -> None:
    commands = [
        [sys.executable, "Conformance/Scripts/core100_oracle_capture.py", "safety-self-test"],
        [
            sys.executable,
            "Conformance/Scripts/core100_oracle_capture.py",
            "safety-audit",
            "--cases",
            "Conformance/OracleCapture/Core100CaptureCases.generated.json",
        ],
    ]
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    for command in commands:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode != 0:
            fail(
                "safety command failed: "
                + " ".join(command)
                + f"\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
                failures,
            )
            continue
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            fail(f"safety command did not emit JSON: {' '.join(command)}: {error}", failures)
            continue
        if payload.get("finding_count", 0) != 0:
            fail(f"safety audit finding_count must be 0: {' '.join(command)} -> {payload}", failures)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check whether MSP Core100 can be called fully closed.")
    parser.add_argument(
        "--skip-safety-audit",
        action="store_true",
        help="Skip invoking core100_oracle_capture.py safety checks.",
    )
    args = parser.parse_args()

    failures: list[str] = []
    required_commands = check_inventory(failures)
    check_matrix(failures)
    check_sources(failures)
    check_capture_fixture(required_commands, failures)
    if not args.skip_safety_audit:
        run_safety_audit(failures)

    summary = {
        "artifact_kind": "msp-core100-closure-gate",
        "required_command_count": len(required_commands),
        "batch_count": len(EXPECTED_BATCHES),
        "failure_count": len(failures),
        "failure_count_by_file": summarize_failures_by_file(failures),
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
