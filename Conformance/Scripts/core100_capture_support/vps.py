from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from .case_builder import b64, ssh_config_path_value
from .config import (
    MAX_CREATED_FILE_BYTES,
    MAX_FILE_CONTENT_BYTES,
    MAX_FILE_TREE_BYTES,
    MAX_FILE_TREE_RECORDS,
    MAX_STDERR_BYTES,
    MAX_STDOUT_BYTES,
)
from .fixtures import public_fixture_from_capture, remote_capture_limit_findings
from .json_io import load_json, write_json
from .remote_runner_source import REMOTE_RUNNER
from .validation import validate_cases


def run_vps(
    cases_path: Path,
    output_path: Path,
    raw_dir: Path,
    host: str,
    limit: int | None,
    selected: list[str],
    known_hosts: Path | None,
    identity_file: Path | None,
) -> int:
    fixture = load_json(cases_path)
    cases = fixture.get("cases", [])
    findings = validate_cases(cases)
    if findings:
        for finding in findings:
            print(finding, file=sys.stderr)
        return 2
    if selected:
        selected_set = set(selected)
        known = {item["id"] for item in cases}
        unknown = selected_set - known
        if unknown:
            print(f"unknown case id(s): {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        cases = [item for item in cases if item["id"] in selected_set]
    if limit is not None:
        if limit <= 0:
            print("--limit must be positive", file=sys.stderr)
            return 2
        cases = cases[:limit]
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    payload = {
        "run_id": run_id,
        "cases": cases,
        "max_file_content": MAX_FILE_CONTENT_BYTES,
        "max_stdout": MAX_STDOUT_BYTES,
        "max_stderr": MAX_STDERR_BYTES,
        "max_file_tree_records": MAX_FILE_TREE_RECORDS,
        "max_file_tree_bytes": MAX_FILE_TREE_BYTES,
        "max_created_file_bytes": MAX_CREATED_FILE_BYTES,
    }
    remote_code = REMOTE_RUNNER.replace("__PAYLOAD__", b64(json.dumps(payload, ensure_ascii=False)))
    ssh_options = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=yes",
    ]
    if known_hosts is not None:
        ssh_options.extend(["-o", f"UserKnownHostsFile={ssh_config_path_value(known_hosts)}"])
    if identity_file is not None:
        ssh_options.extend(["-o", "IdentitiesOnly=yes", "-i", str(identity_file)])
    command = [
        "ssh",
        *ssh_options,
        host,
        "python3",
        "-",
    ]
    print(f"capturing {len(cases)} case(s) on {host}")
    process = subprocess.run(
        command,
        input=remote_code.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    raw_dir.mkdir(parents=True, exist_ok=True)
    (raw_dir / f"{run_id}-ssh-stdout.json").write_bytes(process.stdout)
    (raw_dir / f"{run_id}-ssh-stderr.txt").write_bytes(process.stderr)
    if process.returncode != 0:
        sys.stderr.write(process.stderr.decode("utf-8", errors="replace"))
        return process.returncode
    try:
        remote = json.loads(process.stdout.decode("utf-8"))
    except json.JSONDecodeError:
        sys.stderr.write(process.stdout.decode("utf-8", errors="replace"))
        return 2
    limit_findings = remote_capture_limit_findings(remote)
    if limit_findings:
        write_json(raw_dir / f"{run_id}-limit-findings.json", {
            "output_not_promoted": str(output_path),
            "finding_count": len(limit_findings),
            "findings": limit_findings,
        })
        for finding in limit_findings:
            print(finding, file=sys.stderr)
        print("capture hit safety limits; normalized fixture was not promoted", file=sys.stderr)
        return 3
    public = public_fixture_from_capture(cases, remote)
    write_json(output_path, public)
    write_json(raw_dir / f"{run_id}-public-summary.json", {
        "output": str(output_path),
        "case_count": public["evidence_summary"]["case_count"],
        "timeout_count": public["evidence_summary"]["timeout_count"],
        "limit_exceeded_count": public["evidence_summary"]["limit_exceeded_count"],
    })
    print(f"wrote normalized fixture to {output_path}")
    print(json.dumps(public["evidence_summary"], ensure_ascii=False, indent=2, sort_keys=True))
    return 0
