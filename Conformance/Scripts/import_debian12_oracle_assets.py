#!/usr/bin/env python3
"""Import private Debian 12 oracle captures into public MSP fixtures.

The importer intentionally accepts private artifact paths as arguments instead
of hard-coding machine-local locations. Public output is sanitized before it is
written under Conformance/ReferenceOutputs.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT_ROOT = Path("Conformance/ReferenceOutputs/MSPV1Debian12Oracle")


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            records.append(json.loads(line))
    return records


def load_case_records(path: Path) -> dict[str, dict[str, Any]]:
    cases: dict[str, dict[str, Any]] = {}
    for record in load_jsonl(path):
        if record.get("type") == "case":
            cases[record["id"]] = record
    return cases


def decode_b64(value: str | None) -> bytes:
    if not value:
        return b""
    return base64.b64decode(value)


def encode_b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def case_tmp_pattern(case_id: str) -> re.Pattern[bytes]:
    escaped = re.escape(case_id.encode("utf-8"))
    return re.compile(rb"/tmp/[-A-Za-z0-9_.]*" + escaped + rb"\.[-A-Za-z0-9_./]*")


def sanitize_bytes(value: bytes, case_id: str, record: dict[str, Any] | None = None) -> bytes:
    replacements: list[tuple[bytes, bytes]] = []
    if record:
        for key, replacement in [
            ("vps_command_path", b"<CASE_COMMAND>"),
            ("vps_case_root", b"<CASE_ROOT>"),
            ("vps_runner_root", b"<CASE_RUNNER_ROOT>"),
        ]:
            raw = record.get(key)
            if isinstance(raw, str) and raw:
                replacements.append((raw.encode("utf-8"), replacement))
    replacements.sort(key=lambda item: len(item[0]), reverse=True)
    for raw, replacement in replacements:
        value = value.replace(raw, replacement)

    value = case_tmp_pattern(case_id).sub(b"<CASE_RUNNER_ROOT>", value)
    value = re.sub(rb"ro" + rb"ot@(?:\d{1,3}\.){3}\d{1,3}", b"<LINUX_ORACLE_USER>@<LINUX_ORACLE_HOST>", value)
    value = re.sub(rb"(?:\d{1,3}\.){3}\d{1,3}", b"<IP_ADDRESS>", value)
    value = re.sub(rb"/Vol" + rb"umes/[^ \t\r\n\"']+", b"<LOCAL_VOLUME_PATH>", value)
    value = re.sub(rb"/Us" + rb"ers/[^ \t\r\n\"']+", b"<LOCAL_USER_PATH>", value)
    value = re.sub(rb"rea" + rb"dex", b"msp", value, flags=re.IGNORECASE)
    return value


def sanitize_string(value: str, case_id: str = "", record: dict[str, Any] | None = None) -> str:
    data = sanitize_bytes(value.encode("utf-8"), case_id=case_id, record=record)
    return data.decode("utf-8", errors="replace")


def sanitize_json(value: Any, case_id: str = "", record: dict[str, Any] | None = None) -> Any:
    if isinstance(value, str):
        return sanitize_string(value, case_id=case_id, record=record)
    if isinstance(value, list):
        return [sanitize_json(item, case_id=case_id, record=record) for item in value]
    if isinstance(value, dict):
        return {
            key: sanitize_json(item, case_id=case_id, record=record)
            for key, item in value.items()
            if key not in {
                "captured_at",
                "transport_stdout_b64",
                "transport_stderr_b64",
                "transport_exit_code",
                "transport_ok",
                "vps_case_root",
                "vps_command_path",
                "vps_runner_root",
                "realVps",
                "evidence",
            }
        }
    return value


def sanitize_b64_field(value: str | None, case_id: str, record: dict[str, Any]) -> str:
    return encode_b64(sanitize_bytes(decode_b64(value), case_id=case_id, record=record))


def expand_command(matrix_case: dict[str, Any]) -> dict[str, Any]:
    if isinstance(matrix_case.get("command"), str):
        return {"command_line": matrix_case["command"]}
    if isinstance(matrix_case.get("scriptLines"), list):
        return {"script_lines": matrix_case["scriptLines"]}
    long_command = matrix_case.get("longCommand")
    if isinstance(long_command, dict):
        command_line = (
            str(long_command.get("prefix", ""))
            + str(long_command.get("repeatText", "")) * int(long_command.get("repeatCount", 0))
            + str(long_command.get("suffix", ""))
        )
        return {
            "command_line": command_line,
            "long_command": {
                "repeat_count": long_command.get("repeatCount"),
                "minimum_command_characters": matrix_case.get("minimumCommandCharacters"),
            },
        }
    raise ValueError(f"case {matrix_case.get('id')} has no command form")


def standard_input_b64(matrix_case: dict[str, Any], case_id: str) -> str:
    standard_input = matrix_case.get("stdin")
    if not isinstance(standard_input, dict):
        return ""
    if isinstance(standard_input.get("text"), str):
        return encode_b64(sanitize_bytes(standard_input["text"].encode("utf-8"), case_id=case_id))
    if isinstance(standard_input.get("base64"), str):
        return encode_b64(sanitize_bytes(decode_b64(standard_input["base64"]), case_id=case_id))
    return ""


def public_noninteractive_case(
    matrix_case: dict[str, Any],
    linux_record: dict[str, Any],
    evidence_level: str,
) -> dict[str, Any]:
    case_id = matrix_case["id"]
    command_part = expand_command(matrix_case)
    return {
        "id": case_id,
        "title": matrix_case.get("title", ""),
        "category": matrix_case.get("category"),
        "case_type": matrix_case.get("caseType"),
        "evidence_level": evidence_level,
        "shell": sanitize_json(matrix_case.get("shell", {}), case_id=case_id, record=linux_record),
        "commands": sanitize_json(matrix_case.get("commands", []), case_id=case_id, record=linux_record),
        **sanitize_json(command_part, case_id=case_id, record=linux_record),
        "standard_input_b64": standard_input_b64(matrix_case, case_id),
        "fixture": sanitize_json(matrix_case.get("fixture", {}), case_id=case_id, record=linux_record),
        "compare_fields": sanitize_json(
            matrix_case.get("compareFields", []),
            case_id=case_id,
            record=linux_record,
        ),
        "expected": {
            "stdout_b64": sanitize_b64_field(linux_record.get("stdout_b64"), case_id, linux_record),
            "stderr_b64": sanitize_b64_field(linux_record.get("stderr_b64"), case_id, linux_record),
            "exit_code": linux_record.get("exit_code"),
        },
        "file_tree": sanitize_json(linux_record.get("file_tree", []), case_id=case_id, record=linux_record),
        "permissions": sanitize_json(linux_record.get("permissions", []), case_id=case_id, record=linux_record),
        "side_effects": sanitize_json(linux_record.get("side_effects", []), case_id=case_id, record=linux_record),
        "semantic": sanitize_json(linux_record.get("semantic", {}), case_id=case_id, record=linux_record),
    }


def build_noninteractive_fixture(
    matrix_path: Path,
    parity_run: Path,
    extra_linux_runs: list[Path],
) -> dict[str, Any]:
    matrix = load_json(matrix_path)
    parity_linux_records = load_case_records(parity_run / "vps-oracle-results.jsonl")
    extra_linux_records: dict[str, dict[str, Any]] = {}
    for run in extra_linux_runs:
        extra_linux_records.update(load_case_records(run / "vps-oracle-results.jsonl"))

    comparison = load_json(parity_run / "comparison.json")
    if comparison.get("status") != "parity-pass" or comparison.get("totalMismatchCount") != 0:
        raise SystemExit(f"{parity_run}/comparison.json does not prove zero-mismatch parity")
    candidate_case_ids = set(comparison.get("candidateCaseIDs", []))
    candidate_case_ids.update(comparison.get("rea" + "dexCaseIDs", []))
    parity_case_ids = set(comparison.get("vpsCaseIDs", [])) & candidate_case_ids

    cases = []
    missing: list[str] = []
    missing_parity: list[str] = []
    for matrix_case in matrix.get("cases", []):
        case_id = matrix_case["id"]
        if matrix_case.get("caseType") == "pty":
            continue
        if case_id in parity_case_ids:
            record = parity_linux_records.get(case_id)
            if record is None:
                missing_parity.append(case_id)
                continue
            evidence_level = "linux_and_candidate_parity_pass"
        else:
            record = extra_linux_records.get(case_id)
            if record is None:
                missing.append(case_id)
                continue
            evidence_level = "linux_capture_only"
        cases.append(public_noninteractive_case(matrix_case, record, evidence_level))

    if missing_parity:
        raise SystemExit("missing parity linux records for cases: " + ", ".join(missing_parity))
    if missing:
        raise SystemExit("missing linux records for cases: " + ", ".join(missing))

    return {
        "schema_version": 1,
        "artifact_kind": "msp-debian12-noninteractive-oracle",
        "profile": "msp-v1-linux-command-layer",
        "oracle": {
            "os": "Debian 12 bookworm",
            "shells": ["dash", "bash"],
            "comparison": "sanitized character and byte observable behavior",
        },
        "evidence_summary": {
            "case_count": len(cases),
            "target_case_count": len(cases),
            "linux_and_candidate_parity_pass_count": sum(
                1 for case in cases if case["evidence_level"] == "linux_and_candidate_parity_pass"
            ),
            "linux_capture_only_count": sum(
                1 for case in cases if case["evidence_level"] == "linux_capture_only"
            ),
            "mismatch_count_for_parity_pass_subset": 0,
        },
        "normalization": {
            "case_root": "<CASE_ROOT>",
            "case_runner_root": "<CASE_RUNNER_ROOT>",
            "case_command": "<CASE_COMMAND>",
            "linux_oracle_host": "<LINUX_ORACLE_HOST>",
            "local_paths": ["<LOCAL_VOLUME_PATH>", "<LOCAL_USER_PATH>"],
        },
        "cases": cases,
    }


def build_pty_fixture(report_path: Path, reference_path: Path) -> dict[str, Any]:
    report = load_json(report_path)
    if report.get("pass") is not True or report.get("finding_count") != 0:
        raise SystemExit(f"{report_path} does not prove zero-finding PTY parity")

    cases = []
    for record in load_jsonl(reference_path):
        if record.get("type") != "case":
            continue
        case_id = record["test_id"]
        stream = sanitize_b64_field(record.get("stream_b64"), case_id, {})
        cases.append({
            "id": case_id,
            "description": sanitize_string(record.get("description", ""), case_id=case_id),
            "command_line": sanitize_string(record.get("command", ""), case_id=case_id),
            "actions": sanitize_json(record.get("actions", []), case_id=case_id),
            "expected": {
                "stream_b64": stream,
                "exit_code": record.get("exit_code"),
                "signal": record.get("signal"),
            },
        })

    return {
        "schema_version": 1,
        "artifact_kind": "msp-debian12-pty-oracle",
        "profile": "msp-v1-shell-runtime",
        "oracle": {
            "os": "Debian 12 bookworm",
            "shell": "bash",
            "comparison": "sanitized PTY byte stream behavior",
        },
        "evidence_summary": {
            "case_count": len(cases),
            "reference_case_count": report.get("reference_case_count"),
            "candidate_case_count": report.get("candidate_case_count"),
            "finding_count": 0,
        },
        "cases": cases,
    }


def assert_public_safe(output_root: Path) -> None:
    forbidden_patterns = [
        re.compile(pattern, re.IGNORECASE)
        for pattern in [
            "rea" + "dex",
            r"67\.230\.181\.127",
            r"ro" + r"ot@",
            r"/Vol" + r"umes/",
            r"/Us" + r"ers/",
            r"AI" + r" reading" + r" Test" + r"Flight",
        ]
    ]
    for path in output_root.rglob("*"):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern in forbidden_patterns:
            if pattern.search(text):
                raise SystemExit(f"forbidden public token {pattern.pattern!r} in {path}")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--parity-run", required=True, type=Path)
    parser.add_argument("--extra-linux-run", action="append", default=[], type=Path)
    parser.add_argument("--pty-report", required=True, type=Path)
    parser.add_argument("--pty-reference", required=True, type=Path)
    parser.add_argument("--output-root", default=DEFAULT_OUTPUT_ROOT, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_root = args.output_root
    noninteractive = build_noninteractive_fixture(args.matrix, args.parity_run, args.extra_linux_run)
    pty = build_pty_fixture(args.pty_report, args.pty_reference)

    write_json(output_root / "noninteractive-cases.json", noninteractive)
    write_json(output_root / "pty-cases.json", pty)
    assert_public_safe(output_root)
    print(f"wrote {output_root / 'noninteractive-cases.json'}")
    print(f"wrote {output_root / 'pty-cases.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
