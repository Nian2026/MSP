#!/usr/bin/env bash
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_OUT_DIR:-$ROOT_DIR/.build/msp-conformance/dynamic-embedded-cpython-swift-tests/$STAMP}"
REPORT="$OUT_DIR/dynamic-embedded-cpython-swift-tests-report.json"
SCRATCH_ROOT="${MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_SCRATCH_ROOT:-$OUT_DIR/scratch}"
LOG="$OUT_DIR/dynamic-embedded-cpython-swift-tests.log"
FILTER="MSPCPythonEngineWorkspaceTests|MSPCPythonEngineSubprocessTests|MSPCPythonEngineControlledSubprocessMatrixTests|MSPCPythonEngineControlledSubprocessCommunicationTests|MSPCPythonEngineControlledSubprocessFileTargetTests|MSPCPythonEngineControlledSubprocessStreamingTests|MSPCPythonEngineControlledSubprocessSignalTests|MSPCPythonEngineSubprocessLifecycleTests|MSPCPythonEngineSubprocessPressureMatrixTests|MSPCPythonEnginePressureTests"
MINIMUM_DYNAMIC_TEST_COUNT=20

usage() {
  cat <<USAGE
Usage:
  MSP_CPYTHON_LIBRARY_PATH=/path/to/Python.framework/Python \\
  MSP_CPYTHON_HOME=/path/to/Python.framework/Versions/Current \\
    $0

Runs the dynamic embedded CPython Swift tests that exercise MSP's real CPython
workspace, path mapping, traceback, VFS, and subprocess semantics. Skipped
dynamic CPython tests fail this gate.

Environment:
  MSP_CPYTHON_LIBRARY_PATH                              optional if cached macOS CPython exists
  MSP_CPYTHON_HOME                                      optional but usually required
  MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_OUT_DIR      output root
  MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_SCRATCH_ROOT SwiftPM scratch root
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
    echo "MSP_CPYTHON_LIBRARY_PATH is required for dynamic embedded CPython Swift tests." >&2
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

mkdir -p "$OUT_DIR" "$SCRATCH_ROOT"

echo "== dynamic embedded CPython Swift tests =="
swift test \
  --scratch-path "$SCRATCH_ROOT" \
  --filter "$FILTER" \
  >"$LOG" 2>&1
status=$?

python3 - "$REPORT" "$OUT_DIR" "$SCRATCH_ROOT" "$LOG" "$status" "$FILTER" "$MINIMUM_DYNAMIC_TEST_COUNT" <<'PY'
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
swift_filter = sys.argv[6]
minimum_dynamic_test_count = int(sys.argv[7])

summary_re = re.compile(
    r"Executed\s+([0-9,]+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>[0-9,]+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>[0-9,]+)\s+failures?"
    r"(?:\s+\((?P<unexpected>[0-9,]+)\s+unexpected\))?",
    re.IGNORECASE,
)
test_case_re = re.compile(
    r"Test Case '-\[[^.]+\.(?P<class>[A-Za-z0-9_]+) (?P<method>[A-Za-z0-9_]+)\]' (?:started|passed|failed)"
)

def parse_int(value: str | None) -> int:
    return int((value or "0").replace(",", ""))

text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
summaries = list(summary_re.finditer(text))
executed = max((parse_int(match.group(1)) for match in summaries), default=0)
skipped = max((parse_int(match.group("skipped")) for match in summaries), default=0)
failures_count = max((parse_int(match.group("failures")) for match in summaries), default=0)
unexpected = max((parse_int(match.group("unexpected")) for match in summaries), default=0)

required_classes = [
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
]
required_test_cases = [
    "MSPCPythonEngineWorkspaceTestsBytesAndMetadata/testCPythonEngineDefaultsVirtualTextFilesToUTF8WhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDoesNotSurfaceSurrogateOutputWhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessPressureMatrixTests/testCPythonEngineSubprocessPopenOsPopenSystemPressureMatrixWhenLibraryIsAvailable",
]
executed_test_names = sorted(
    {
        f"{match.group('class')}/{match.group('method')}"
        for match in test_case_re.finditer(text)
        if match.group(0).endswith("' passed")
    }
)
failures: list[str] = []
if exit_code != 0:
    failures.append(f"swift test exited {exit_code}")
if not text.strip():
    failures.append("Swift test log is empty")
if not summaries:
    failures.append("Swift test log does not contain an execution summary")
if executed < minimum_dynamic_test_count:
    failures.append(
        f"dynamic embedded CPython Swift tests executed {executed}, below required minimum {minimum_dynamic_test_count}"
    )
if skipped > 0:
    failures.append(f"dynamic embedded CPython Swift tests skipped {skipped} tests")
if failures_count > 0:
    failures.append(f"dynamic embedded CPython Swift tests reported {failures_count} failures")
if unexpected > 0:
    failures.append(f"dynamic embedded CPython Swift tests reported {unexpected} unexpected failures")
for required in required_classes:
    if required not in text:
        failures.append(f"Swift test log does not mention required dynamic test class: {required}")
for required in required_test_cases:
    if required not in executed_test_names:
        failures.append(f"Swift test log does not prove required dynamic test case executed: {required}")

report = {
    "passed": not failures,
    "gate": "msp-dynamic-embedded-cpython-swift-tests",
    "swift_filter": swift_filter,
    "minimum_dynamic_test_count": minimum_dynamic_test_count,
    "required_test_classes": required_classes,
    "required_test_cases": required_test_cases,
    "executed_test_names": executed_test_names,
    "out_dir": str(out_dir),
    "scratch_root": str(scratch_root),
    "log": str(log_path),
    "exit_code": exit_code,
    "executed_test_count": executed,
    "skipped_test_count": skipped,
    "failure_count": failures_count,
    "unexpected_failure_count": unexpected,
    "cpython_library_path": os.environ.get("MSP_CPYTHON_LIBRARY_PATH", ""),
    "cpython_home": os.environ.get("MSP_CPYTHON_HOME", ""),
    "failures": failures,
}
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

if [[ "$status" != "0" ]]; then
  echo "MSP dynamic embedded CPython Swift tests failed" >&2
  echo "report=$REPORT" >&2
  exit "$status"
fi

if python3 - "$REPORT" <<'PY'
import json
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(0 if report.get("passed") is True else 1)
PY
then
  echo "MSP dynamic embedded CPython Swift tests passed"
  echo "report=$REPORT"
else
  echo "MSP dynamic embedded CPython Swift tests failed" >&2
  echo "report=$REPORT" >&2
  exit 1
fi
