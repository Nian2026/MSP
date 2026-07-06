#!/usr/bin/env bash
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${MSP_FULL_AGENTBRIDGE_PARITY_MATRIX_OUT_DIR:-$ROOT_DIR/.build/msp-conformance/full-agentbridge-parity-matrix/$STAMP}"
REPORT="$OUT_DIR/full-agentbridge-parity-matrix-report.json"
DISCOVERY="$OUT_DIR/agentbridge-test-discovery.json"
SWIFT_LOG="$OUT_DIR/full-agentbridge-parity-matrix-swift.log"
SOURCE_CURRENTNESS_LOG="$OUT_DIR/agentbridge-compaction-source-currentness.log"
SCRATCH_ROOT="${MSP_FULL_AGENTBRIDGE_PARITY_MATRIX_SCRATCH_ROOT:-$OUT_DIR/scratch}"
MINIMUM_TEST_COUNT="${MSP_FULL_AGENTBRIDGE_PARITY_MINIMUM_TEST_COUNT:-180}"

usage() {
  cat <<USAGE
Usage:
  $0

Runs the full MSPAgentBridge parity matrix as final-gate evidence. The matrix
discovers current AgentBridge XCTest classes under Tests/Swift/Unit/MSPAgentBridge,
runs them together, verifies the required capability buckets, and records the
Codex compaction source-currentness check.

Environment:
  MSP_FULL_AGENTBRIDGE_PARITY_MATRIX_OUT_DIR   output root
  MSP_FULL_AGENTBRIDGE_PARITY_MATRIX_SCRATCH_ROOT
                                                SwiftPM scratch root
  MSP_FULL_AGENTBRIDGE_PARITY_MINIMUM_TEST_COUNT
                                                minimum executed Swift tests
  MSP_CODEX_APPLY_PATCH_DYLIB                  optional if the default vendored dylib exists
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$OUT_DIR" "$SCRATCH_ROOT"

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
  echo "MSP_CODEX_APPLY_PATCH_DYLIB is required for the full AgentBridge parity matrix." >&2
  echo "Expected default dylib: $DEFAULT_APPLY_PATCH_DYLIB" >&2
  exit 2
fi

python3 - "$ROOT_DIR" "$DISCOVERY" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
discovery_path = Path(sys.argv[2]).resolve()
test_root = root / "Tests/Swift/Unit/MSPAgentBridge"

required_capability_buckets: dict[str, dict[str, object]] = {
    "exec-command-session-contract": {
        "classes": [
            "MSPExecCommandBridgeTests",
            "MSPAgentConversationExecSessionRequestTests",
        ],
        "coverage": [
            "exec_command and write_stdin schemas",
            "Codex-style yield timing",
            "model-visible shell output envelope",
            "yielded session polling",
        ],
    },
    "responses-streaming-and-tool-calls": {
        "classes": [
            "MSPResponsesStreamingModelClientTests",
            "MSPAgentConversationToolOutputTests",
        ],
        "coverage": [
            "Responses stream deltas",
            "function and custom tool calls",
            "tool output encoding",
            "provider error parsing",
        ],
    },
    "apply-patch-tool": {
        "classes": ["MSPApplyPatchToolTests"],
        "coverage": [
            "Codex apply_patch freeform tool",
            "patch success and failure envelopes",
        ],
    },
    "conversation-request-history": {
        "classes": [
            "MSPAgentConversationRequestHistoryTests",
            "MSPAgentConversationRequestMetadataTests",
        ],
        "coverage": [
            "request transcript history",
            "native metadata scrubbing",
            "conversation request ordering",
        ],
    },
    "interrupt-and-turn-interrupt": {
        "classes": [
            "MSPAgentConversationInterruptTests",
            "MSPAgentConversationInterruptRequestTests",
            "MSPTurnInterruptCapabilityTests",
        ],
        "coverage": [
            "conversation interruption",
            "interrupt during tool execution",
            "turn interrupt capability",
        ],
    },
    "compaction-local-auto-remote-replay": {
        "classes": [
            "MSPAgentConversationCompactionRequestTests",
            "MSPAgentConversationAutoCompactionRequestTests",
            "MSPAgentConversationPendingInputCompactionTests",
            "MSPAgentConversationRemoteCompactionTests",
            "MSPAgentToolLoopPendingInputCompactionTests",
            "MSPChatCompactionPackageStoreTests",
            "MSPCompactionHistoryRewriterTests",
        ],
        "coverage": [
            "manual compaction",
            "pre-turn and mid-turn auto compaction",
            "pending input compaction",
            "remote compaction",
            "replacement history and checkpoint replay",
            "chat compaction package storage",
        ],
    },
    "goal-capability": {
        "classes": ["MSPGoalCapabilityTests"],
        "coverage": [
            "goal lifecycle",
            "model goal tools",
            "token and usage accounting",
            "goal chat mapping",
        ],
    },
    "turn-steer-capability": {
        "classes": [
            "MSPTurnSteerCapabilityTests",
            "MSPTurnSteerTimingTests",
            "MSPTurnSteerValidationTests",
        ],
        "coverage": [
            "turn steering declaration",
            "active-turn validation",
            "timing and interruption interactions",
        ],
    },
}

class_files: dict[str, set[str]] = {}
declared_tests: dict[str, int] = {}

for path in sorted(test_root.glob("*.swift")):
    text = path.read_text(encoding="utf-8", errors="replace")
    test_count = len(re.findall(r"\bfunc\s+test\w+\s*\(", text))
    if test_count == 0:
        continue
    rel = str(path.relative_to(root))
    class_matches = list(re.finditer(r"\b(?:final\s+)?class\s+(\w+Tests)\s*:\s*[\w.]+", text))
    extension_matches = list(re.finditer(r"\bextension\s+(\w+Tests)\s*\{", text))
    if class_matches:
        name = class_matches[0].group(1)
    elif extension_matches:
        name = extension_matches[0].group(1)
    else:
        raise SystemExit(f"could not associate test functions with a test class: {rel}")
    class_files.setdefault(name, set()).add(rel)
    declared_tests[name] = declared_tests.get(name, 0) + test_count

test_classes = [
    {
        "name": name,
        "declared_test_count": declared_tests[name],
        "source_files": sorted(class_files[name]),
    }
    for name in sorted(declared_tests)
]

class_names = [item["name"] for item in test_classes]
class_name_set = set(class_names)
bucket_reports: dict[str, dict[str, object]] = {}
failures: list[str] = []
for bucket, spec in required_capability_buckets.items():
    required_classes = list(spec["classes"])  # type: ignore[index]
    missing = [name for name in required_classes if name not in class_name_set]
    if missing:
        failures.append(f"capability bucket {bucket} is missing test class(es): {', '.join(missing)}")
    bucket_reports[bucket] = {
        "classes": required_classes,
        "coverage": list(spec["coverage"]),  # type: ignore[index]
        "missing_classes": missing,
        "present": not missing,
        "declared_test_count": sum(declared_tests.get(name, 0) for name in required_classes),
    }

discovery = {
    "test_root": str(test_root.relative_to(root)),
    "test_class_count": len(test_classes),
    "declared_test_count": sum(declared_tests.values()),
    "test_filter": "|".join(class_names),
    "test_classes": test_classes,
    "required_capability_buckets": list(required_capability_buckets),
    "capability_buckets": bucket_reports,
    "failures": failures,
}
discovery_path.write_text(
    json.dumps(discovery, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

TEST_FILTER="$(python3 - "$DISCOVERY" <<'PY'
import json
import sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["test_filter"])
PY
)"

echo "== full AgentBridge parity matrix =="
swift test \
  --scratch-path "$SCRATCH_ROOT" \
  --filter "$TEST_FILTER" \
  >"$SWIFT_LOG" 2>&1
swift_exit=$?

SOURCE_CURRENTNESS_SCRIPT="$ROOT_DIR/Conformance/Scripts/verify_agentbridge_compaction_source_currentness.sh"
if [[ -x "$SOURCE_CURRENTNESS_SCRIPT" || -f "$SOURCE_CURRENTNESS_SCRIPT" ]]; then
  bash "$SOURCE_CURRENTNESS_SCRIPT" >"$SOURCE_CURRENTNESS_LOG" 2>&1
  source_currentness_exit=$?
else
  echo "missing source-currentness script: $SOURCE_CURRENTNESS_SCRIPT" >"$SOURCE_CURRENTNESS_LOG"
  source_currentness_exit=127
fi

python3 - "$REPORT" "$OUT_DIR" "$SCRATCH_ROOT" "$DISCOVERY" "$SWIFT_LOG" "$swift_exit" "$SOURCE_CURRENTNESS_LOG" "$source_currentness_exit" "$MINIMUM_TEST_COUNT" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

report_path = Path(sys.argv[1]).resolve()
out_dir = Path(sys.argv[2]).resolve()
scratch_root = Path(sys.argv[3]).resolve()
discovery_path = Path(sys.argv[4]).resolve()
swift_log_path = Path(sys.argv[5]).resolve()
swift_exit = int(sys.argv[6])
source_currentness_log_path = Path(sys.argv[7]).resolve()
source_currentness_exit = int(sys.argv[8])
minimum_test_count = int(sys.argv[9])

summary_re = re.compile(
    r"Executed\s+([0-9,]+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>[0-9,]+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>[0-9,]+)\s+failures?"
    r"(?:\s+\((?P<unexpected>[0-9,]+)\s+unexpected\))?",
    re.IGNORECASE,
)
field_re = re.compile(r"^(?P<key>[a-z_]+)=(?P<value>.+)$")

def parse_int(value: str | None) -> int:
    return int((value or "0").replace(",", ""))

discovery = json.loads(discovery_path.read_text(encoding="utf-8"))
swift_log = swift_log_path.read_text(encoding="utf-8", errors="replace") if swift_log_path.is_file() else ""
source_log = (
    source_currentness_log_path.read_text(encoding="utf-8", errors="replace")
    if source_currentness_log_path.is_file()
    else ""
)

summaries = list(summary_re.finditer(swift_log))
executed = max((parse_int(match.group(1)) for match in summaries), default=0)
skipped = max((parse_int(match.group("skipped")) for match in summaries), default=0)
failure_count = max((parse_int(match.group("failures")) for match in summaries), default=0)
unexpected_failure_count = max((parse_int(match.group("unexpected")) for match in summaries), default=0)
test_class_names = [item["name"] for item in discovery.get("test_classes", [])]

source_fields = {}
for line in source_log.splitlines():
    match = field_re.match(line.strip())
    if match:
        source_fields[match.group("key")] = match.group("value")

failures: list[str] = []
failures.extend(discovery.get("failures") or [])
if swift_exit != 0:
    failures.append(f"swift test exited {swift_exit}")
if not swift_log.strip():
    failures.append("AgentBridge Swift test log is empty")
if not summaries:
    failures.append("AgentBridge Swift test log does not contain an execution summary")
if executed < minimum_test_count:
    failures.append(f"AgentBridge executed {executed} tests, below required minimum {minimum_test_count}")
declared_test_count = discovery.get("declared_test_count")
if not isinstance(declared_test_count, int) or declared_test_count < minimum_test_count:
    failures.append("AgentBridge declared_test_count is below required minimum")
elif executed < declared_test_count:
    failures.append(f"AgentBridge executed {executed} tests, below declared source count {declared_test_count}")
if skipped > 0:
    failures.append(f"AgentBridge Swift matrix skipped {skipped} tests")
if failure_count > 0:
    failures.append(f"AgentBridge Swift matrix reported {failure_count} failures")
if unexpected_failure_count > 0:
    failures.append(f"AgentBridge Swift matrix reported {unexpected_failure_count} unexpected failures")
for name in test_class_names:
    if name not in swift_log:
        failures.append(f"AgentBridge Swift log does not mention required test class: {name}")

required_buckets = discovery.get("required_capability_buckets")
bucket_reports = discovery.get("capability_buckets")
if not isinstance(required_buckets, list) or len(required_buckets) < 8:
    failures.append("AgentBridge required_capability_buckets is missing or too small")
if not isinstance(bucket_reports, dict):
    failures.append("AgentBridge capability_buckets is missing or not an object")
else:
    for bucket in required_buckets if isinstance(required_buckets, list) else []:
        item = bucket_reports.get(bucket)
        if not isinstance(item, dict):
            failures.append(f"AgentBridge capability bucket is missing: {bucket}")
            continue
        if item.get("present") is not True:
            failures.append(f"AgentBridge capability bucket is not fully present: {bucket}")
        if not isinstance(item.get("coverage"), list) or not item.get("coverage"):
            failures.append(f"AgentBridge capability bucket has no coverage labels: {bucket}")
        if not isinstance(item.get("declared_test_count"), int) or item.get("declared_test_count") <= 0:
            failures.append(f"AgentBridge capability bucket has no declared tests: {bucket}")

if source_currentness_exit != 0:
    failures.append(f"AgentBridge compaction source-currentness exited {source_currentness_exit}")
if "OK Codex compaction currentness" not in source_log:
    failures.append("AgentBridge compaction source-currentness did not report OK")
for key in ["pinned_commit", "origin_head", "codex_paths", "storage_evidence_paths"]:
    if not source_fields.get(key):
        failures.append(f"AgentBridge compaction source-currentness missing {key}")
for key in ["codex_paths", "storage_evidence_paths"]:
    value = source_fields.get(key)
    if value is not None:
        try:
            if int(value) <= 0:
                failures.append(f"AgentBridge compaction source-currentness {key} is not positive")
        except ValueError:
            failures.append(f"AgentBridge compaction source-currentness {key} is not an integer")

report = {
    "passed": not failures,
    "gate": "msp-full-agentbridge-parity-matrix",
    "package_path": ".",
    "command": [
        "swift",
        "test",
        "--scratch-path",
        str(scratch_root),
        "--filter",
        discovery.get("test_filter", ""),
    ],
    "swift_filter": discovery.get("test_filter", ""),
    "out_dir": str(out_dir),
    "scratch_root": str(scratch_root),
    "discovery": str(discovery_path),
    "swift_log": str(swift_log_path),
    "source_currentness_log": str(source_currentness_log_path),
    "minimum_executed_test_count": minimum_test_count,
    "test_root": discovery.get("test_root"),
    "test_class_count": discovery.get("test_class_count"),
    "declared_test_count": declared_test_count,
    "executed_test_count": executed,
    "skipped_test_count": skipped,
    "failure_count": failure_count,
    "unexpected_failure_count": unexpected_failure_count,
    "environment_contract": {
        "MSP_CODEX_APPLY_PATCH_DYLIB": os.environ.get("MSP_CODEX_APPLY_PATCH_DYLIB", ""),
    },
    "required_capability_buckets": required_buckets,
    "capability_buckets": bucket_reports,
    "test_classes": discovery.get("test_classes"),
    "source_currentness": {
        "script": "Conformance/Scripts/verify_agentbridge_compaction_source_currentness.sh",
        "exit_code": source_currentness_exit,
        "passed": source_currentness_exit == 0 and "OK Codex compaction currentness" in source_log,
        "pinned_commit": source_fields.get("pinned_commit", ""),
        "origin_head": source_fields.get("origin_head", ""),
        "codex_paths": int(source_fields["codex_paths"]) if source_fields.get("codex_paths", "").isdigit() else None,
        "storage_evidence_paths": (
            int(source_fields["storage_evidence_paths"])
            if source_fields.get("storage_evidence_paths", "").isdigit()
            else None
        ),
    },
    "failures": failures,
}
report_path.write_text(
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

if python3 - "$REPORT" <<'PY'
import json
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(0 if report.get("passed") is True else 1)
PY
then
  echo "MSP full AgentBridge parity matrix passed"
  echo "report=$REPORT"
else
  echo "MSP full AgentBridge parity matrix failed" >&2
  echo "report=$REPORT" >&2
  exit 1
fi
