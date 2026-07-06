#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_EXEC_SESSION_STRESS_GATE_OUT_DIR:-$ROOT_DIR/.build/msp-conformance/exec-session-stress/$STAMP}"
REPORT="$OUT_DIR/exec-session-stress-report.json"
SCRATCH_ROOT="${MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT:-$OUT_DIR/scratch}"
LOG="$OUT_DIR/swift-test.log"
MINIMUM_EXECUTED_TEST_COUNT="${MSP_EXEC_SESSION_STRESS_GATE_MINIMUM_EXECUTED_TEST_COUNT:-15}"

mkdir -p "$OUT_DIR" "$SCRATCH_ROOT"

export MSP_EXEC_SESSION_STRESS_CONCURRENCY="${MSP_EXEC_SESSION_STRESS_CONCURRENCY:-12}"
export MSP_EXEC_SESSION_STRESS_LARGE_OUTPUT_BYTES="${MSP_EXEC_SESSION_STRESS_LARGE_OUTPUT_BYTES:-10485760}"
export MSP_EXEC_SESSION_STRESS_RING_OUTPUT_BYTES="${MSP_EXEC_SESSION_STRESS_RING_OUTPUT_BYTES:-2097152}"
export MSP_EXEC_SESSION_STRESS_STDIN_WRITES="${MSP_EXEC_SESSION_STRESS_STDIN_WRITES:-24}"
export MSP_EXEC_SESSION_STRESS_RESOURCE_ITERATIONS="${MSP_EXEC_SESSION_STRESS_RESOURCE_ITERATIONS:-24}"
export MSP_EXEC_SESSION_STRESS_ALLOWED_FD_GROWTH="${MSP_EXEC_SESSION_STRESS_ALLOWED_FD_GROWTH:-4}"
export MSP_EXEC_SESSION_STRESS_ALLOWED_MEMORY_GROWTH_BYTES="${MSP_EXEC_SESSION_STRESS_ALLOWED_MEMORY_GROWTH_BYTES:-67108864}"
export MSP_EXEC_SESSION_STRESS_ALLOWED_IDLE_CPU_MILLISECONDS="${MSP_EXEC_SESSION_STRESS_ALLOWED_IDLE_CPU_MILLISECONDS:-250}"

SWIFT_FILTER="ModelShellProxyExecSessionStressTests|ModelShellProxyExecSessionPTYStressTests"
set +e
(
  cd "$ROOT_DIR"
  swift test --scratch-path "$SCRATCH_ROOT" --filter "$SWIFT_FILTER"
) >"$LOG" 2>&1
status=$?
set -e

python3 - "$REPORT" "$OUT_DIR" "$SCRATCH_ROOT" "$LOG" "$status" "$SWIFT_FILTER" "$MINIMUM_EXECUTED_TEST_COUNT" <<'PY'
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
minimum_executed_test_count = int(sys.argv[7])

summary_re = re.compile(
    r"Executed\s+([0-9,]+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>[0-9,]+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>[0-9,]+)\s+failures?"
    r"(?:\s+\((?P<unexpected>[0-9,]+)\s+unexpected\))?",
    re.IGNORECASE,
)

def parse_int(value: str | None) -> int:
    return int((value or "0").replace(",", ""))

text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
summaries = list(summary_re.finditer(text))
executed = max((parse_int(match.group(1)) for match in summaries), default=0)
skipped = max((parse_int(match.group("skipped")) for match in summaries), default=0)
failure_count = max((parse_int(match.group("failures")) for match in summaries), default=0)
unexpected_failure_count = max((parse_int(match.group("unexpected")) for match in summaries), default=0)

required_log_fragments = [
    "ModelShellProxyExecSessionStressTests",
    "ModelShellProxyExecSessionPTYStressTests",
]
failures: list[str] = []
if exit_code != 0:
    failures.append(f"swift test exited {exit_code}")
if not text.strip():
    failures.append("Swift test log is empty")
if not summaries:
    failures.append("Swift test log does not contain an execution summary")
if executed < minimum_executed_test_count:
    failures.append(
        f"exec-session stress Swift tests executed {executed}, below required minimum {minimum_executed_test_count}"
    )
if skipped > 0:
    failures.append(f"exec-session stress Swift tests skipped {skipped} tests")
if failure_count > 0:
    failures.append(f"exec-session stress Swift tests reported {failure_count} failures")
if unexpected_failure_count > 0:
    failures.append(f"exec-session stress Swift tests reported {unexpected_failure_count} unexpected failures")
for fragment in required_log_fragments:
    if fragment not in text:
        failures.append(f"Swift test log does not mention required exec-session stress coverage: {fragment}")

report = {
    "passed": not failures,
    "gate": "msp-exec-session-stress-gate",
    "out_dir": str(out_dir),
    "scratch_root": str(scratch_root),
    "log": str(log_path),
    "command": ["swift", "test", "--scratch-path", str(scratch_root), "--filter", swift_filter],
    "exit_code": exit_code,
    "swift_filter": swift_filter,
    "swift_filters": swift_filter.split("|"),
    "minimum_executed_test_count": minimum_executed_test_count,
    "executed_test_count": executed,
    "skipped_test_count": skipped,
    "failure_count": failure_count,
    "unexpected_failure_count": unexpected_failure_count,
    "required_log_fragments": required_log_fragments,
    "stress": {
        "concurrency": int(os.environ["MSP_EXEC_SESSION_STRESS_CONCURRENCY"]),
        "large_output_bytes": int(os.environ["MSP_EXEC_SESSION_STRESS_LARGE_OUTPUT_BYTES"]),
        "ring_output_bytes": int(os.environ["MSP_EXEC_SESSION_STRESS_RING_OUTPUT_BYTES"]),
        "retained_output_bytes": int(os.environ.get("MSP_EXEC_SESSION_OUTPUT_MAX_BYTES", "1048576")),
        "stdin_writes": int(os.environ["MSP_EXEC_SESSION_STRESS_STDIN_WRITES"]),
        "resource_iterations": int(os.environ["MSP_EXEC_SESSION_STRESS_RESOURCE_ITERATIONS"]),
        "allowed_fd_growth": int(os.environ["MSP_EXEC_SESSION_STRESS_ALLOWED_FD_GROWTH"]),
        "allowed_memory_growth_bytes": int(os.environ["MSP_EXEC_SESSION_STRESS_ALLOWED_MEMORY_GROWTH_BYTES"]),
        "allowed_idle_cpu_milliseconds": int(os.environ["MSP_EXEC_SESSION_STRESS_ALLOWED_IDLE_CPU_MILLISECONDS"]),
    },
    "coverage": [
        "concurrent yielded pipe sessions",
        "silent long-running pipe session with empty write_stdin poll",
        "app lifecycle background/foreground gap preserves running pipe session state",
        "app lifecycle background/foreground gap preserves running PTY session state",
        "PTY 10MB+ output",
        "PTY retained-output cap/ring truncation preserves later reads",
        "PTY high-frequency stdin writes",
        "PTY terminate process group and inactive-session cleanup",
        "PTY repeated-session fd leak budget",
        "PTY repeated-session resident memory growth budget",
        "PTY post-cleanup idle CPU budget",
    ],
    "failures": failures,
}
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if [[ "$status" != "0" ]]; then
  echo "MSP exec session stress gate failed" >&2
  echo "report=$REPORT" >&2
  echo "log=$LOG" >&2
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
  echo "MSP exec session stress gate passed"
  echo "report=$REPORT"
  echo "log=$LOG"
else
  echo "MSP exec session stress gate failed" >&2
  echo "report=$REPORT" >&2
  echo "log=$LOG" >&2
  exit 1
fi
