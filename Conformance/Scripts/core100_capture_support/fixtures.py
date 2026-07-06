from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .case_builder import case
from .cases import generated_cases
from .config import (
    MAX_CASES_PER_RUN,
    MAX_COMMAND_LINE_BYTES,
    MAX_CREATED_FILE_BYTES,
    MAX_FILE_CONTENT_BYTES,
    MAX_FILE_TREE_BYTES,
    MAX_FILE_TREE_RECORDS,
    MAX_FIXTURE_DIRECTORIES,
    MAX_FIXTURE_FILE_BYTES,
    MAX_FIXTURE_FILES,
    MAX_STDERR_BYTES,
    MAX_STDIN_BYTES,
    MAX_STDOUT_BYTES,
    REMOTE_RUN_ROOT_PREFIX,
    ROOT,
)
from .json_io import load_json, write_json
from .validation import validate_cases


def command_rows_from_matrix() -> set[str]:
    required_path = ROOT / "Conformance" / "Fixtures" / "MSPV1LinuxCommandLayer.required-commands.json"
    fixture = json.loads(required_path.read_text(encoding="utf-8"))
    return {
        item["name"]
        for item in fixture.get("commands", [])
        if item.get("status") == "implemented"
    }


def coverage_summary(cases: list[dict[str, Any]]) -> dict[str, Any]:
    by_command: dict[str, int] = {command: 0 for command in sorted(command_rows_from_matrix())}
    for item in cases:
        primary_command = item.get("primary_command")
        if primary_command in by_command:
            by_command[primary_command] += 1
    missing = sorted(command for command, count in by_command.items() if count == 0)
    return {
        "case_count": len(cases),
        "core100_command_count": len(by_command),
        "covered_core100_command_count": len(by_command) - len(missing),
        "missing_core100_commands": missing,
        "per_command_case_count": by_command,
        "shell_stress_case_count": sum(1 for item in cases if item.get("category") == "core100-shell-stress"),
    }


def generate_cases(output: Path) -> int:
    cases = generated_cases()
    findings = validate_cases(cases)
    if findings:
        for finding in findings:
            print(finding, file=sys.stderr)
        return 2
    fixture = {
        "schema_version": 1,
        "artifact_kind": "msp-core100-oracle-capture-cases",
        "profile": "msp-core100-linux-command-layer",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "safety_policy": "Conformance/OracleCapture/DebianOracleCaptureSafetyPolicy.md",
        "summary": coverage_summary(cases),
        "cases": cases,
    }
    write_json(output, fixture)
    print(f"wrote {len(cases)} case(s) to {output}")
    summary = fixture["summary"]
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def validate_file(path: Path) -> int:
    fixture = load_json(path)
    cases = fixture.get("cases", [])
    findings = validate_cases(cases)
    if findings:
        for finding in findings:
            print(finding, file=sys.stderr)
        return 2
    print(f"validated {len(cases)} case(s)")
    print(json.dumps(coverage_summary(cases), ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def safety_audit_file(path: Path) -> int:
    fixture = load_json(path)
    cases = fixture.get("cases", [])
    findings = validate_cases(cases)
    report = {
        "artifact_kind": "msp-core100-oracle-safety-audit",
        "cases": str(path),
        "accepted_case_count": 0 if findings else len(cases),
        "finding_count": len(findings),
        "findings": findings,
        "limits": {
            "remote_run_root_prefix": REMOTE_RUN_ROOT_PREFIX,
            "max_cases_per_run": MAX_CASES_PER_RUN,
            "max_command_line_bytes": MAX_COMMAND_LINE_BYTES,
            "max_stdin_bytes": MAX_STDIN_BYTES,
            "max_fixture_directories": MAX_FIXTURE_DIRECTORIES,
            "max_fixture_files": MAX_FIXTURE_FILES,
            "max_fixture_file_bytes": MAX_FIXTURE_FILE_BYTES,
            "max_stdout_bytes": MAX_STDOUT_BYTES,
            "max_stderr_bytes": MAX_STDERR_BYTES,
            "max_file_content_bytes": MAX_FILE_CONTENT_BYTES,
            "max_file_tree_records": MAX_FILE_TREE_RECORDS,
            "max_file_tree_bytes": MAX_FILE_TREE_BYTES,
            "max_created_file_bytes": MAX_CREATED_FILE_BYTES,
        },
        "summary": coverage_summary(cases) if not findings else None,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not findings else 2


def safety_self_test() -> int:
    valid_cases = [
        case("safety-valid-bin-sh", "/bin/sh -c 'printf ok\\n'", ["sh", "printf"]),
        case("safety-valid-relative-rm", "mkdir d; : > d/file; rm -r d; test ! -e d", ["mkdir", ":", "rm", "test"]),
    ]
    failures: list[str] = []
    valid_findings = validate_cases(valid_cases)
    if valid_findings:
        failures.append("valid cases were rejected: " + "; ".join(valid_findings))

    invalid_cases = [
        case("unsafe-etc-read", "cat /etc/passwd", ["cat"]),
        case("unsafe-bin-shadow-boundary", "cat /bin/shadow", ["cat"]),
        case("unsafe-root-delete", "rm -rf /", ["rm"]),
        case("unsafe-find-root-delete", "find / -delete", ["find"]),
        case("unsafe-network-curl", "curl https://example.com", ["curl"]),
        case("unsafe-hostname-setter", "hostname new-name", ["hostname"]),
        case("unsafe-python-host-write", "python3 - <<'PY'\nopen('/etc/passwd','w').write('x')\nPY", ["python3"]),
        {
            **case("unsafe-fixture-escape", "printf ok", ["printf"]),
            "fixture": {"kind": "isolated-temp-tree", "directories": ["../escape"], "files": []},
        },
        {
            **case("unsafe-too-long-command", "printf " + ("x" * (MAX_COMMAND_LINE_BYTES + 1)), ["printf"]),
        },
    ]
    for invalid in invalid_cases:
        findings = validate_cases([invalid])
        if not findings:
            failures.append(f"unsafe case was accepted: {invalid['id']}")

    if failures:
        print(json.dumps({
            "artifact_kind": "msp-core100-oracle-safety-self-test",
            "status": "failed",
            "failures": failures,
        }, ensure_ascii=False, indent=2, sort_keys=True))
        return 2
    print(json.dumps({
        "artifact_kind": "msp-core100-oracle-safety-self-test",
        "status": "passed",
        "valid_case_count": len(valid_cases),
        "rejected_unsafe_case_count": len(invalid_cases),
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def public_fixture_from_capture(cases: list[dict[str, Any]], remote: dict[str, Any]) -> dict[str, Any]:
    case_by_id = {item["id"]: item for item in cases}
    public_cases = []
    for record in remote["results"]:
        matrix_case = case_by_id[record["id"]]
        public_cases.append({
            "id": record["id"],
            "title": matrix_case.get("title", ""),
            "category": matrix_case.get("category"),
            "case_type": matrix_case.get("case_type"),
            "evidence_level": "linux_capture_only",
            "shell": matrix_case.get("shell"),
            "primary_command": matrix_case.get("primary_command"),
            "commands": matrix_case.get("commands", []),
            "command_line": matrix_case.get("command_line"),
            "standard_input_b64": matrix_case.get("standard_input_b64", ""),
            "fixture": matrix_case.get("fixture", {}),
            "compare_fields": matrix_case.get("compare_fields", []),
            "expected": {
                "stdout_b64": record.get("stdout_b64", ""),
                "stderr_b64": record.get("stderr_b64", ""),
                "exit_code": record.get("exit_code"),
            },
            "timeout": record.get("timeout", False),
            "elapsed_seconds": record.get("elapsed_seconds"),
            "stdout_truncated": record.get("stdout_truncated", False),
            "stderr_truncated": record.get("stderr_truncated", False),
            "limit_exceeded": record.get("limit_exceeded", False),
            "limit_reasons": record.get("limit_reasons", []),
            "file_tree": record.get("file_tree", []),
            "permissions": [],
            "side_effects": [],
        })
    summary = coverage_summary(cases)
    return {
        "schema_version": 1,
        "artifact_kind": "msp-core100-debian12-noninteractive-oracle",
        "profile": "msp-core100-linux-command-layer",
        "oracle": {
            "os": "Debian 12 bookworm",
            "shells": ["dash", "bash"],
            "comparison": "sanitized byte-level observable behavior",
        },
        "normalization": {
            "case_root": "<CASE_ROOT>",
            "case_runner_root": "<CASE_RUNNER_ROOT>",
        },
        "evidence_summary": {
            "case_count": len(public_cases),
            "linux_capture_only_count": len(public_cases),
            "timeout_count": sum(1 for item in public_cases if item.get("timeout")),
            "limit_exceeded_count": sum(1 for item in public_cases if item.get("limit_exceeded")),
            "core100_command_count": summary["core100_command_count"],
            "covered_core100_command_count": summary["covered_core100_command_count"],
            "missing_core100_commands": summary["missing_core100_commands"],
            "shell_stress_case_count": summary["shell_stress_case_count"],
            "per_command_case_count": summary["per_command_case_count"],
        },
        "cases": public_cases,
    }


def remote_capture_limit_findings(remote: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    for record in remote.get("results", []):
        reasons = record.get("limit_reasons", [])
        if record.get("limit_exceeded") or reasons:
            findings.append(f"{record.get('id')}: capture limit exceeded: {', '.join(reasons) or 'unknown'}")
    return findings


def public_fixture_summary(cases: list[dict[str, Any]]) -> dict[str, Any]:
    summary = coverage_summary(cases)
    summary.update({
        "linux_capture_only_count": sum(1 for item in cases if item.get("evidence_level") == "linux_capture_only"),
        "timeout_count": sum(1 for item in cases if item.get("timeout")),
        "limit_exceeded_count": sum(1 for item in cases if item.get("limit_exceeded")),
    })
    return summary


def merge_public_fixture(existing_path: Path, partial_path: Path, output_path: Path) -> int:
    existing = load_json(existing_path)
    partial = load_json(partial_path)
    existing_cases = existing.get("cases", [])
    partial_cases = partial.get("cases", [])
    if not isinstance(existing_cases, list) or not isinstance(partial_cases, list):
        print("public fixture merge requires both inputs to contain a cases array", file=sys.stderr)
        return 2

    merged_by_id = {item["id"]: item for item in existing_cases}
    existing_order = [item["id"] for item in existing_cases]
    appended_ids: list[str] = []
    for item in partial_cases:
        case_id = item["id"]
        if case_id not in merged_by_id:
            appended_ids.append(case_id)
        merged_by_id[case_id] = item

    merged_cases = [merged_by_id[case_id] for case_id in existing_order if case_id in merged_by_id]
    merged_cases.extend(merged_by_id[case_id] for case_id in appended_ids)
    merged = dict(existing)
    merged["cases"] = merged_cases
    merged["evidence_summary"] = public_fixture_summary(merged_cases)
    write_json(output_path, merged)
    print(json.dumps({
        "artifact_kind": "msp-core100-public-fixture-merge",
        "existing_case_count": len(existing_cases),
        "partial_case_count": len(partial_cases),
        "output": str(output_path),
        "output_case_count": len(merged_cases),
        "replaced_case_count": sum(1 for item in partial_cases if item["id"] in existing_order),
        "appended_case_count": len(appended_ids),
    }, ensure_ascii=False, indent=2, sort_keys=True))
    return 0
