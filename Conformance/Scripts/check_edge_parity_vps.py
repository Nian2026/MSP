#!/usr/bin/env python3
import argparse
import base64
import json
import os
import re
import subprocess
import sys
from pathlib import Path


REMOTE_RUNNER = r'''
import base64
import json
import os
import shutil
import subprocess
import tempfile

fixture = json.loads(base64.b64decode("__PAYLOAD__").decode("utf-8"))
selected = set(json.loads(base64.b64decode("__SELECTED__").decode("utf-8")))
results = []


def safe_join(root, relative):
    path = os.path.normpath(os.path.join(root, relative))
    root_real = os.path.realpath(root)
    path_real = os.path.realpath(os.path.dirname(path))
    if path_real != root_real and not path_real.startswith(root_real + os.sep):
        raise RuntimeError("setup path escapes workspace: " + relative)
    return path


for case in fixture["cases"]:
    if selected and case["id"] not in selected:
        continue
    root = tempfile.mkdtemp(prefix="msp-edge-")
    try:
        setup_failed = None
        for item in case.get("setup_files", []):
            path = safe_join(root, item["path"])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(item.get("content", "").encode("utf-8"))

        for setup in case.get("setup_script", []):
            setup_result = subprocess.run(
                setup,
                cwd=root,
                shell=True,
                executable="/bin/bash",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if setup_result.returncode != 0:
                setup_failed = {
                    "command": setup,
                    "stdout_b64": base64.b64encode(setup_result.stdout).decode("ascii"),
                    "stderr_b64": base64.b64encode(setup_result.stderr).decode("ascii"),
                    "exit_code": setup_result.returncode,
                }
                break

        if setup_failed is None:
            result = subprocess.run(
                case["command_line"],
                cwd=root,
                shell=True,
                executable="/bin/bash",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            results.append({
                "id": case["id"],
                "stdout_b64": base64.b64encode(result.stdout).decode("ascii"),
                "stderr_b64": base64.b64encode(result.stderr).decode("ascii"),
                "exit_code": result.returncode,
            })
        else:
            results.append({
                "id": case["id"],
                "setup_failed": setup_failed,
                "stdout_b64": "",
                "stderr_b64": "",
                "exit_code": 127,
            })
    finally:
        shutil.rmtree(root, ignore_errors=True)

print(json.dumps({"results": results}, ensure_ascii=False))
'''


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run MSP v1 edge parity cases on a Linux VPS and compare observable output."
    )
    parser.add_argument(
        "--fixture",
        default="Conformance/Fixtures/MSPV1LinuxCommandLayer.edge-parity-cases.json",
        help="Edge parity fixture path.",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("MSP_VPS_HOST"),
        help="SSH host, default from MSP_VPS_HOST. Required when MSP_VPS_HOST is unset.",
    )
    parser.add_argument(
        "--case",
        action="append",
        dest="cases",
        default=[],
        help="Run only the given case id. May be repeated.",
    )
    parser.add_argument(
        "--connect-timeout",
        default="10",
        help="SSH ConnectTimeout value.",
    )
    args = parser.parse_args()
    if not args.host:
        parser.error("--host or MSP_VPS_HOST is required")
    return args


def decode_text(encoded):
    return base64.b64decode(encoded).decode("utf-8", errors="replace")


def expected_stdout_matches(case, stdout):
    if "stdout" in case:
        return stdout == case["stdout"], case["stdout"]
    pattern = case.get("stdout_matches")
    if pattern is None:
        return False, "<missing stdout expectation>"
    return re.fullmatch(pattern, stdout) is not None, f"<regex {pattern!r}>"


def compare_case(case, actual):
    stdout = decode_text(actual["stdout_b64"])
    stderr = decode_text(actual["stderr_b64"])
    stdout_ok, stdout_expected = expected_stdout_matches(case, stdout)
    stderr_ok = stderr == case["stderr"]
    exit_ok = actual["exit_code"] == case["exit_code"]
    return {
        "id": case["id"],
        "ok": stdout_ok and stderr_ok and exit_ok and "setup_failed" not in actual,
        "stdout": stdout,
        "stderr": stderr,
        "exit_code": actual["exit_code"],
        "stdout_expected": stdout_expected,
        "stderr_expected": case["stderr"],
        "exit_code_expected": case["exit_code"],
        "setup_failed": actual.get("setup_failed"),
    }


def main():
    args = parse_args()
    fixture_path = Path(args.fixture)
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    selected = set(args.cases)
    cases = [
        case for case in fixture["cases"]
        if not selected or case["id"] in selected
    ]
    known_ids = {case["id"] for case in fixture["cases"]}
    unknown = selected - known_ids
    if unknown:
        print(f"Unknown case id(s): {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2

    payload = base64.b64encode(json.dumps({"cases": cases}).encode("utf-8")).decode("ascii")
    selected_payload = base64.b64encode(json.dumps([]).encode("utf-8")).decode("ascii")
    remote_code = REMOTE_RUNNER.replace("__PAYLOAD__", payload).replace("__SELECTED__", selected_payload)
    command = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={args.connect_timeout}",
        args.host,
        "python3",
        "-",
    ]
    process = subprocess.run(
        command,
        input=remote_code.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        sys.stderr.write(process.stderr.decode("utf-8", errors="replace"))
        return process.returncode

    try:
        remote = json.loads(process.stdout.decode("utf-8"))
    except json.JSONDecodeError:
        sys.stderr.write(process.stdout.decode("utf-8", errors="replace"))
        sys.stderr.write(process.stderr.decode("utf-8", errors="replace"))
        return 2

    case_by_id = {case["id"]: case for case in cases}
    comparisons = [
        compare_case(case_by_id[result["id"]], result)
        for result in remote["results"]
    ]
    failed = [item for item in comparisons if not item["ok"]]

    print(f"checked {len(comparisons)} edge case(s) on {args.host}")
    if not failed:
        print("all edge cases match VPS observable output")
        return 0

    print(f"{len(failed)} mismatch(es):", file=sys.stderr)
    for item in failed:
        print(f"\n[{item['id']}]", file=sys.stderr)
        if item["setup_failed"]:
            setup = item["setup_failed"]
            print(f"setup failed: {setup['command']} exit={setup['exit_code']}", file=sys.stderr)
            print(f"setup stdout={decode_text(setup['stdout_b64'])!r}", file=sys.stderr)
            print(f"setup stderr={decode_text(setup['stderr_b64'])!r}", file=sys.stderr)
            continue
        if item["stdout"] != item["stdout_expected"]:
            print(f"stdout expected={item['stdout_expected']!r}", file=sys.stderr)
            print(f"stdout actual  ={item['stdout']!r}", file=sys.stderr)
        if item["stderr"] != item["stderr_expected"]:
            print(f"stderr expected={item['stderr_expected']!r}", file=sys.stderr)
            print(f"stderr actual  ={item['stderr']!r}", file=sys.stderr)
        if item["exit_code"] != item["exit_code_expected"]:
            print(f"exit expected={item['exit_code_expected']}", file=sys.stderr)
            print(f"exit actual  ={item['exit_code']}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
