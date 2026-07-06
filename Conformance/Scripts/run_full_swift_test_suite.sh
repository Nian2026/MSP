#!/usr/bin/env bash
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_FULL_SWIFT_TEST_SUITE_OUT_DIR:-$ROOT_DIR/.build/msp-conformance/full-swift-test-suite/$STAMP}"
REPORT="$OUT_DIR/full-swift-test-suite-report.json"
SCRATCH_ROOT="${MSP_FULL_SWIFT_TEST_SUITE_SCRATCH_ROOT:-$OUT_DIR/scratch}"
LOG="$OUT_DIR/full-swift-test-suite.log"
MINIMUM_EXECUTED_TEST_COUNT="${MSP_FULL_SWIFT_TEST_SUITE_MINIMUM_EXECUTED_TEST_COUNT:-850}"

usage() {
  cat <<USAGE
Usage:
  $0

Runs the unfiltered root SwiftPM test suite as final-gate evidence. This gate
fails on skipped tests; it prepares the optional oracle/runtime environment
that would otherwise make the root suite silently skip coverage.

Environment:
  MSP_FULL_SWIFT_TEST_SUITE_OUT_DIR        output root
  MSP_FULL_SWIFT_TEST_SUITE_SCRATCH_ROOT   SwiftPM scratch root
  MSP_CPYTHON_LIBRARY_PATH / MSP_CPYTHON_HOME
                                           optional if cached macOS CPython exists
  MSP_CODEX_APPLY_PATCH_DYLIB              optional if the default vendored dylib exists
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

resolve_cached_macos_cpython() {
  python3 - "$ROOT_DIR/.build/msp-cpython-macos-cache" <<'PY'
from pathlib import Path
import sys

cache = Path(sys.argv[1])
frameworks = sorted(cache.glob("Python-*-macOS-support.*/Python.xcframework/**/Python.framework"))
for framework in frameworks:
    library = framework / "Python"
    homes = sorted(framework.glob("Versions/*/lib/python*"))
    if library.is_file() and homes:
        home = homes[0].parents[1]
        print(str(library))
        print(str(home))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

if [[ -z "${MSP_CPYTHON_LIBRARY_PATH:-}" ]]; then
  cached_paths="$(resolve_cached_macos_cpython)" || {
    echo "MSP_CPYTHON_LIBRARY_PATH is required for the full Swift test suite." >&2
    echo "Set MSP_CPYTHON_LIBRARY_PATH/MSP_CPYTHON_HOME or cache macOS CPython with:" >&2
    echo "  MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=macOS Conformance/Scripts/cache_beeware_cpython_apple_support.sh" >&2
    exit 2
  }
  export MSP_CPYTHON_LIBRARY_PATH="$(printf '%s\n' "$cached_paths" | sed -n '1p')"
  export MSP_CPYTHON_HOME="$(printf '%s\n' "$cached_paths" | sed -n '2p')"
fi

if [[ ! -f "$MSP_CPYTHON_LIBRARY_PATH" ]]; then
  echo "MSP_CPYTHON_LIBRARY_PATH does not exist: $MSP_CPYTHON_LIBRARY_PATH" >&2
  exit 2
fi
if [[ -n "${MSP_CPYTHON_HOME:-}" && ! -d "$MSP_CPYTHON_HOME" ]]; then
  echo "MSP_CPYTHON_HOME does not exist: $MSP_CPYTHON_HOME" >&2
  exit 2
fi

DEFAULT_APPLY_PATCH_TARGET_DIR="${MSP_CODEX_APPLY_PATCH_TARGET_DIR:-$ROOT_DIR/.build/msp-codex-apply-patch-bridge/target}"
DEFAULT_APPLY_PATCH_DYLIB="$DEFAULT_APPLY_PATCH_TARGET_DIR/release/libmsp_codex_apply_patch_bridge.dylib"
DEFAULT_APPLY_PATCH_BUILD_SCRIPT="$ROOT_DIR/Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/build-rust-bridge.sh"
if [[ -z "${MSP_CODEX_APPLY_PATCH_DYLIB:-}" && ! -f "$DEFAULT_APPLY_PATCH_DYLIB" && -x "$DEFAULT_APPLY_PATCH_BUILD_SCRIPT" ]]; then
  echo "building default MSP_CODEX_APPLY_PATCH_DYLIB with $DEFAULT_APPLY_PATCH_BUILD_SCRIPT"
  MSP_CODEX_APPLY_PATCH_TARGET_DIR="$DEFAULT_APPLY_PATCH_TARGET_DIR" "$DEFAULT_APPLY_PATCH_BUILD_SCRIPT"
fi
if [[ -z "${MSP_CODEX_APPLY_PATCH_DYLIB:-}" && -f "$DEFAULT_APPLY_PATCH_DYLIB" ]]; then
  export MSP_CODEX_APPLY_PATCH_DYLIB="$DEFAULT_APPLY_PATCH_DYLIB"
fi
if [[ -z "${MSP_CODEX_APPLY_PATCH_DYLIB:-}" || ! -f "$MSP_CODEX_APPLY_PATCH_DYLIB" ]]; then
  echo "MSP_CODEX_APPLY_PATCH_DYLIB is required for the full Swift test suite." >&2
  echo "Expected default dylib: $DEFAULT_APPLY_PATCH_DYLIB" >&2
  exit 2
fi

export MSP_RUN_CORE100_ORACLE=1
export MSP_RUN_DEBIAN12_ORACLE=1
export MSP_RUN_DEBIAN12_PTY_ORACLE=1
export MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON=1
export MSP_DEBIAN12_PTY_ORACLE_BACKEND=linux-external
export MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX=1

if [[ -z "${MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE:-}" ]]; then
  python_executable="$(command -v python3 || true)"
  if [[ -z "$python_executable" ]]; then
    echo "python3 executable not found; set MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE" >&2
    exit 127
  fi
  export MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE="$python_executable"
fi

if [[ -z "${MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE:-}" ]]; then
  node_executable="$(command -v node || true)"
  if [[ -z "$node_executable" ]]; then
    echo "node executable not found; set MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE" >&2
    exit 127
  fi
  export MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE="$node_executable"
fi

mkdir -p "$OUT_DIR" "$SCRATCH_ROOT"

echo "== full SwiftPM test suite =="
swift test \
  --scratch-path "$SCRATCH_ROOT" \
  >"$LOG" 2>&1
exit_code=$?

python3 - "$REPORT" "$OUT_DIR" "$SCRATCH_ROOT" "$LOG" "$exit_code" "$MINIMUM_EXECUTED_TEST_COUNT" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2]).resolve()
scratch_root = Path(sys.argv[3]).resolve()
log_path = Path(sys.argv[4]).resolve()
exit_code = int(sys.argv[5])
minimum_executed_test_count = int(sys.argv[6])

summary_re = re.compile(
    r"Executed\s+([0-9,]+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>[0-9,]+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>[0-9,]+)\s+failures?"
    r"(?:\s+\((?P<unexpected>[0-9,]+)\s+unexpected\))?",
    re.IGNORECASE,
)
skipped_re = re.compile(r"Test skipped - (?P<reason>.+)$")

def parse_int(value: str | None) -> int:
    return int((value or "0").replace(",", ""))

text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
summaries = list(summary_re.finditer(text))
executed = max((parse_int(match.group(1)) for match in summaries), default=0)
skipped = max((parse_int(match.group("skipped")) for match in summaries), default=0)
failure_count = max((parse_int(match.group("failures")) for match in summaries), default=0)
unexpected_failure_count = max((parse_int(match.group("unexpected")) for match in summaries), default=0)
skipped_reasons = [
    match.group("reason")
    for line in text.splitlines()
    for match in [skipped_re.search(line)]
    if match is not None
]

required_log_fragments = [
    "MSPApplyPatchToolTests",
    "MSPPythonHostProcessSubprocessShellMatrixTests",
    "MSPCPythonEngineWorkspaceTests",
    "MSPCPythonEngineSubprocessTests",
    "MSPCPythonEngineControlledSubprocessMatrixTests",
    "MSPCPythonEngineControlledSubprocessCommunicationTests",
    "MSPCPythonEngineControlledSubprocessFileTargetTests",
    "MSPCPythonEngineControlledSubprocessStreamingTests",
    "MSPCPythonEngineControlledSubprocessSignalTests",
    "MSPCPythonEngineSubprocessLifecycleTests",
    "MSPCPythonEngineSubprocessPressureMatrixTests",
    "MSPCPythonEnginePressureTests",
    "ModelShellProxyCore100OracleConformanceTests",
    "ModelShellProxyDebian12OracleConformanceTests",
    "ModelShellProxyDebian12PTYOracleConformanceTests",
    "ModelShellProxyFinalGateVerifierConformanceTests",
    "ModelShellProxyReleaseGateAuxiliarySourceGuardTests",
    "ModelShellProxyReleaseGateConformanceTests",
    "ModelShellProxyReleaseGatePreflightConformanceTests",
    "ModelShellProxyReleaseGateVerifierSourceGuardTests",
]

environment_contract = {
    "MSP_RUN_CORE100_ORACLE": os.environ.get("MSP_RUN_CORE100_ORACLE", ""),
    "MSP_RUN_DEBIAN12_ORACLE": os.environ.get("MSP_RUN_DEBIAN12_ORACLE", ""),
    "MSP_RUN_DEBIAN12_PTY_ORACLE": os.environ.get("MSP_RUN_DEBIAN12_PTY_ORACLE", ""),
    "MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON": os.environ.get("MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON", ""),
    "MSP_DEBIAN12_PTY_ORACLE_BACKEND": os.environ.get("MSP_DEBIAN12_PTY_ORACLE_BACKEND", ""),
    "MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX": os.environ.get("MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX", ""),
    "MSP_CPYTHON_LIBRARY_PATH": os.environ.get("MSP_CPYTHON_LIBRARY_PATH", ""),
    "MSP_CPYTHON_HOME": os.environ.get("MSP_CPYTHON_HOME", ""),
    "MSP_CODEX_APPLY_PATCH_DYLIB": os.environ.get("MSP_CODEX_APPLY_PATCH_DYLIB", ""),
    "MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE": os.environ.get("MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE", ""),
    "MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE": os.environ.get("MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE", ""),
}

failures: list[str] = []
if exit_code != 0:
    failures.append(f"swift test exited {exit_code}")
if not text.strip():
    failures.append("Swift test log is empty")
if not summaries:
    failures.append("Swift test log does not contain an execution summary")
if executed < minimum_executed_test_count:
    failures.append(
        f"full Swift test suite executed {executed}, below required minimum {minimum_executed_test_count}"
    )
if skipped > 0:
    failures.append(f"full Swift test suite skipped {skipped} tests")
if failure_count > 0:
    failures.append(f"full Swift test suite reported {failure_count} failures")
if unexpected_failure_count > 0:
    failures.append(f"full Swift test suite reported {unexpected_failure_count} unexpected failures")
for fragment in required_log_fragments:
    if fragment not in text:
        failures.append(f"full Swift test suite log does not mention required coverage: {fragment}")
for key in [
    "MSP_RUN_CORE100_ORACLE",
    "MSP_RUN_DEBIAN12_ORACLE",
    "MSP_RUN_DEBIAN12_PTY_ORACLE",
    "MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON",
    "MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX",
]:
    if environment_contract[key] != "1":
        failures.append(f"full Swift test suite environment {key} is not 1")
if environment_contract["MSP_DEBIAN12_PTY_ORACLE_BACKEND"] != "linux-external":
    failures.append("full Swift test suite did not require linux-external PTY oracle backend")
for key in [
    "MSP_CPYTHON_LIBRARY_PATH",
    "MSP_CODEX_APPLY_PATCH_DYLIB",
    "MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE",
    "MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE",
]:
    value = environment_contract[key]
    if not value or not Path(value).exists():
        failures.append(f"full Swift test suite environment {key} does not point to an existing path")

report = {
    "passed": not failures,
    "gate": "msp-full-swift-test-suite",
    "package_path": ".",
    "command": ["swift", "test", "--scratch-path", str(scratch_root)],
    "unfiltered": True,
    "swift_filter": "",
    "minimum_executed_test_count": minimum_executed_test_count,
    "required_log_fragments": required_log_fragments,
    "out_dir": str(out_dir),
    "scratch_root": str(scratch_root),
    "log": str(log_path),
    "exit_code": exit_code,
    "executed_test_count": executed,
    "skipped_test_count": skipped,
    "skipped_reasons": skipped_reasons,
    "failure_count": failure_count,
    "unexpected_failure_count": unexpected_failure_count,
    "environment_contract": environment_contract,
    "failures": failures,
}
report_path.write_text(
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

if [[ "$exit_code" != "0" ]]; then
  echo "MSP full Swift test suite failed" >&2
  echo "report=$REPORT" >&2
  exit "$exit_code"
fi

if python3 - "$REPORT" <<'PY'
import json
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(0 if report.get("passed") is True else 1)
PY
then
  echo "MSP full Swift test suite passed"
  echo "report=$REPORT"
else
  echo "MSP full Swift test suite failed" >&2
  echo "report=$REPORT" >&2
  exit 1
fi
