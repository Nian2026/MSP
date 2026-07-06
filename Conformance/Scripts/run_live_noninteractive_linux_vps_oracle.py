#!/usr/bin/env python3
"""Run Debian noninteractive oracle fixtures on a live Linux VPS over SSH."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = ROOT / "Conformance/ReferenceOutputs/MSPV1Debian12Oracle/noninteractive-cases.json"

REMOTE_RUNNER = r'''
import base64
import json
import os
import platform
import shutil
import stat
import subprocess
import tempfile
import traceback

cases = json.loads(base64.b64decode("__CASES__").decode("utf-8"))


def read_os_release():
    try:
        with open("/etc/os-release", "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def safe_join(root, relative):
    if relative.startswith("/"):
        raise RuntimeError("absolute fixture path is not allowed: " + relative)
    parts = relative.split("/")
    if ".." in parts:
        raise RuntimeError("escaping fixture path is not allowed: " + relative)
    return os.path.normpath(os.path.join(root, relative))


def file_content(item):
    if item.get("content_b64") is not None:
        return base64.b64decode(item["content_b64"])
    return item.get("content", "").encode("utf-8")


def prepare_fixture(root, fixture):
    os.chmod(root, 0o755)
    for directory in fixture.get("directories", []):
        path = safe_join(root, directory)
        os.makedirs(path, exist_ok=True)
        os.chmod(path, 0o755)
    for item in fixture.get("files", []):
        path = safe_join(root, item["path"])
        parent = os.path.dirname(path)
        os.makedirs(parent, exist_ok=True)
        if item.get("target") is not None:
            os.symlink(item["target"], path)
        else:
            with open(path, "wb") as handle:
                handle.write(file_content(item))
        mode = item.get("mode")
        if mode:
            os.chmod(path, int(mode, 8))
        elif item.get("target") is None:
            os.chmod(path, 0o644)


def snapshot_file_tree(root):
    entries = []

    def append(path, rel):
        if rel == "./.msp" or rel.startswith("./.msp/"):
            return
        st = os.lstat(path)
        mode = f"{stat.S_IMODE(st.st_mode):03o}"
        if stat.S_ISLNK(st.st_mode):
            entries.append({
                "kind": "symlink",
                "mode": "777",
                "path": rel,
                "size": None,
                "target": os.readlink(path),
            })
            return
        if stat.S_ISDIR(st.st_mode):
            children = sorted(os.listdir(path))
            if rel == "./tmp" and not children:
                return
            entries.append({
                "kind": "directory",
                "mode": mode,
                "path": rel,
                "size": None,
            })
            for child in children:
                child_rel = "./" + child if rel == "." else rel + "/" + child
                append(os.path.join(path, child), child_rel)
            return
        if stat.S_ISREG(st.st_mode):
            with open(path, "rb") as handle:
                data = handle.read()
            entries.append({
                "kind": "file",
                "mode": mode,
                "path": rel,
                "size": len(data),
                "content_b64": base64.b64encode(data).decode("ascii"),
            })
            return
        entries.append({
            "kind": "other",
            "mode": mode,
            "path": rel,
            "size": st.st_size,
        })

    append(root, ".")
    return sorted(entries, key=lambda item: (item["path"], item["kind"]))


def script_text(case):
    if case.get("command_line") is not None:
        return case["command_line"]
    return "\n".join(case.get("script_lines") or [])


def shell_argv(case):
    shell = case.get("shell") or {}
    argv = list(shell.get("argv") or ["/bin/bash", "--noprofile", "--norc"])
    return argv + ["-c", script_text(case)]


def run_case(case):
    root = tempfile.mkdtemp(prefix="msp-live-debian12-")
    try:
        prepare_fixture(root, case.get("fixture") or {})
        stdin = base64.b64decode(case.get("standard_input_b64") or "")
        result = subprocess.run(
            shell_argv(case),
            cwd=root,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
        )
        return {
            "id": case["id"],
            "root_path": root,
            "stdout_b64": base64.b64encode(result.stdout).decode("ascii"),
            "stderr_b64": base64.b64encode(result.stderr).decode("ascii"),
            "exit_code": result.returncode,
            "file_tree": snapshot_file_tree(root),
        }
    except BaseException as exc:
        return {
            "id": case.get("id", "<unknown>"),
            "root_path": root,
            "runner_error": str(exc),
            "traceback": traceback.format_exc(),
            "stdout_b64": "",
            "stderr_b64": base64.b64encode(str(exc).encode("utf-8", errors="replace")).decode("ascii"),
            "exit_code": -1,
            "file_tree": [],
        }
    finally:
        shutil.rmtree(root, ignore_errors=True)


print(json.dumps({
    "runner": {
        "platform": platform.platform(),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "os_release": read_os_release(),
    },
    "results": [run_case(case) for case in cases],
}, ensure_ascii=False))
'''


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run MSP Debian noninteractive oracle cases on a live Linux VPS."
    )
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument(
        "--host",
        default=os.environ.get("MSP_LIVE_LINUX_VPS_HOST") or os.environ.get("MSP_VPS_HOST"),
    )
    parser.add_argument("--case", action="append", dest="cases", default=[])
    parser.add_argument("--limit", type=int)
    parser.add_argument("--connect-timeout", default=os.environ.get("MSP_LIVE_LINUX_VPS_CONNECT_TIMEOUT", "10"))
    args = parser.parse_args()
    if not args.host:
        parser.error("--host, MSP_LIVE_LINUX_VPS_HOST, or MSP_VPS_HOST is required")
    return args


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def script_text(case: dict[str, Any]) -> str:
    if case.get("command_line") is not None:
        return str(case["command_line"])
    return "\n".join(case.get("script_lines") or [])


def normalize_entry(entry: dict[str, Any]) -> dict[str, Any]:
    normalized = {
        "kind": entry.get("kind"),
        "mode": entry.get("mode"),
        "path": entry.get("path"),
        "size": entry.get("size"),
    }
    if entry.get("content_b64") is not None:
        normalized["content_b64"] = entry.get("content_b64")
    if entry.get("target") is not None:
        normalized["target"] = entry.get("target")
    return normalized


def normalized_file_tree(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted((normalize_entry(entry) for entry in entries), key=lambda item: (str(item.get("path")), str(item.get("kind"))))


def byte_comparison(expected_b64: str, actual_b64: str) -> dict[str, Any]:
    expected = base64.b64decode(expected_b64)
    actual = base64.b64decode(actual_b64)
    first: int | None = None
    for index, (lhs, rhs) in enumerate(zip(expected, actual)):
        if lhs != rhs:
            first = index
            break
    if first is None and len(expected) != len(actual):
        first = min(len(expected), len(actual))
    return {
        "expectedByteCount": len(expected),
        "actualByteCount": len(actual),
        "firstDifferentByteOffset": first,
        "expectedByteAtOffset": expected[first] if first is not None and first < len(expected) else None,
        "actualByteAtOffset": actual[first] if first is not None and first < len(actual) else None,
        "expectedUtf8Preview": expected[:400].decode("utf-8", errors="replace"),
        "actualUtf8Preview": actual[:400].decode("utf-8", errors="replace"),
    }


def replacing_bytes(data: bytes, target: bytes, replacement: bytes) -> bytes:
    if not target:
        return data
    return data.replace(target, replacement)


def live_expected_output_b64(case: dict[str, Any], actual: dict[str, Any], stream: str) -> str:
    expected = case.get("expected") or {}
    key = f"{stream}_b64"
    data = base64.b64decode(expected.get(key) or "")
    root = str(actual.get("root_path") or "").encode("utf-8")
    shell = case.get("shell") or {}
    argv = shell.get("argv") or []
    command = str(argv[0] if argv else "/bin/bash").encode("utf-8")
    if root:
        data = replacing_bytes(data, b"<CASE_ROOT>/", root + b"/")
        data = replacing_bytes(data, b"<CASE_ROOT>", root)
    data = replacing_bytes(data, b"<CASE_COMMAND>", command)
    return base64.b64encode(data).decode("ascii")


def likely_layer(mismatch: dict[str, bool], actual: dict[str, Any]) -> str:
    stderr = base64.b64decode(actual.get("stderr_b64") or "").decode("utf-8", errors="replace")
    if actual.get("runner_error"):
        return "live_vps_runner_or_fixture_setup"
    if "command not found" in stderr:
        return "live_vps_command_availability"
    if not mismatch["fileTreeMatches"]:
        return "live_vps_file_tree_or_side_effects"
    if not mismatch["stdoutMatches"] or not mismatch["stderrMatches"] or not mismatch["exitCodeMatches"]:
        return "live_vps_output_or_exit_semantics"
    return "unknown"


def compare_case(case: dict[str, Any], actual: dict[str, Any]) -> dict[str, Any] | None:
    expected_tree = normalized_file_tree(case.get("file_tree") or [])
    actual_tree = normalized_file_tree(actual.get("file_tree") or [])
    expected = case.get("expected") or {}
    expected_stdout_b64 = live_expected_output_b64(case, actual, "stdout")
    expected_stderr_b64 = live_expected_output_b64(case, actual, "stderr")
    mismatch = {
        "stdoutMatches": actual.get("stdout_b64") == expected_stdout_b64,
        "stderrMatches": actual.get("stderr_b64") == expected_stderr_b64,
        "exitCodeMatches": actual.get("exit_code") == expected.get("exit_code"),
        "fileTreeMatches": actual_tree == expected_tree,
    }
    if all(mismatch.values()) and not actual.get("runner_error"):
        return None
    return {
        "id": case["id"],
        "category": case.get("category"),
        "evidenceLevel": case.get("evidence_level"),
        "command": script_text(case),
        "mismatch": mismatch,
        "likelyLayer": likely_layer(mismatch, actual),
        "expected": {
            "stdoutB64": expected_stdout_b64,
            "stderrB64": expected_stderr_b64,
            "exitCode": expected.get("exit_code"),
            "fileTree": expected_tree,
        },
        "actual": {
            "stdoutB64": actual.get("stdout_b64", ""),
            "stderrB64": actual.get("stderr_b64", ""),
            "exitCode": actual.get("exit_code"),
            "fileTree": actual_tree,
        },
        "diagnostics": {
            "stdout": byte_comparison(expected_stdout_b64, actual.get("stdout_b64", "")),
            "stderr": byte_comparison(expected_stderr_b64, actual.get("stderr_b64", "")),
        },
        "runnerError": actual.get("runner_error"),
        "runnerTraceback": actual.get("traceback"),
    }


def selected_cases(fixture: dict[str, Any], ids: list[str], limit: int | None) -> list[dict[str, Any]]:
    cases = list(fixture.get("cases") or [])
    known = {case.get("id") for case in cases}
    unknown = sorted(set(ids).difference(known))
    if unknown:
        raise ValueError("unknown case id(s): " + ", ".join(unknown))
    if ids:
        wanted = set(ids)
        cases = [case for case in cases if case.get("id") in wanted]
    if limit is not None:
        cases = cases[:limit]
    return cases


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def base_report(args: argparse.Namespace, fixture: dict[str, Any], cases: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "artifactKind": "msp-live-noninteractive-linux-vps-oracle",
        "gate": "msp-live-noninteractive-linux-vps-oracle",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "fixture": str(args.fixture),
        "fixtureCaseCount": len(fixture.get("cases") or []),
        "selectedCaseCount": len(cases),
        "runnerBackend": "ssh-linux-vps",
        "runnerHost": args.host,
        "liveRun": True,
        "compatibilityAdjustments": [],
    }


def run_remote(args: argparse.Namespace, cases: list[dict[str, Any]]) -> dict[str, Any]:
    payload = base64.b64encode(json.dumps(cases, ensure_ascii=False).encode("utf-8")).decode("ascii")
    remote_code = REMOTE_RUNNER.replace("__CASES__", payload)
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
        raise RuntimeError(process.stderr.decode("utf-8", errors="replace") or f"ssh exited {process.returncode}")
    try:
        remote = json.loads(process.stdout.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError("remote runner returned invalid JSON: " + str(exc) + "\n" + process.stdout.decode("utf-8", errors="replace")) from exc
    return remote


def main() -> int:
    args = parse_args()
    fixture = load_json(args.fixture)
    try:
        cases = selected_cases(fixture, args.cases, args.limit)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    report = base_report(args, fixture, cases)
    try:
        remote = run_remote(args, cases)
        runner = remote.get("runner") or {}
        result_by_id = {item.get("id"): item for item in remote.get("results") or []}
        failures = [
            failure
            for case in cases
            for failure in [compare_case(case, result_by_id.get(case["id"], {"id": case["id"], "runner_error": "missing remote result"}))]
            if failure is not None
        ]
        passed_ids = [case["id"] for case in cases if not any(failure["id"] == case["id"] for failure in failures)]
        report.update({
            "passed": not failures,
            "runnerPlatform": runner.get("platform"),
            "runnerSystem": runner.get("system"),
            "runnerRelease": runner.get("release"),
            "runnerMachine": runner.get("machine"),
            "runnerPython": runner.get("python"),
            "runnerOSRelease": runner.get("os_release"),
            "passedCaseCount": len(passed_ids),
            "failedCaseCount": len(failures),
            "passedCaseIDs": passed_ids,
            "failedCaseIDs": [failure["id"] for failure in failures],
            "failures": failures,
            "runnerFailures": [],
        })
    except RuntimeError as exc:
        report.update({
            "passed": False,
            "runnerPlatform": "",
            "runnerSystem": "",
            "runnerRelease": "",
            "runnerMachine": "",
            "runnerPython": "",
            "runnerOSRelease": "",
            "passedCaseCount": 0,
            "failedCaseCount": len(cases),
            "passedCaseIDs": [],
            "failedCaseIDs": [case["id"] for case in cases],
            "failures": [],
            "runnerFailures": [str(exc)],
        })
        write_report(args.report, report)
        print(str(exc), file=sys.stderr)
        return 1

    write_report(args.report, report)
    if report["passed"]:
        print("Live noninteractive Linux VPS oracle passed")
        print(f"report={args.report}")
        return 0
    print(f"Live noninteractive Linux VPS oracle failed: {report['failedCaseCount']} case(s)", file=sys.stderr)
    print(f"report={args.report}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
