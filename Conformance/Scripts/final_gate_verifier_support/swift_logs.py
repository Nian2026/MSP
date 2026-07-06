from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .artifacts import load_json_from_text
from .contract import (
    SWIFT_BUILD_COMPLETE_RE,
    SWIFT_TEST_STEPS,
    SWIFT_TEST_SUMMARY_RE,
    SWIFTPM_SCRATCH_STEPS,
)

def parse_int(value: str) -> int:
    return int(value.replace(",", ""))


UNAVAILABLE_GATE_MARKER_RE = re.compile(
    r"^(?!.*\b(?:Compiling|Emitting|Linking|Applying|Test Case|Test Suite)\b)"
    r"(?=.*\bunavailable\b)"
    r"(?=.*\b(?:required|gate|oracle|runner|runtime|suite|backend)\b).*$",
    re.IGNORECASE | re.MULTILINE,
)


def swift_test_summaries(name: str, text: str, failures: list[str]) -> list[dict[str, int]]:
    summaries = list(SWIFT_TEST_SUMMARY_RE.finditer(text))
    if not summaries:
        failures.append(f"{name} log does not contain a Swift test execution summary")
        return []

    parsed: list[dict[str, int]] = []
    for match in summaries:
        parsed.append({
            "executed": parse_int(match.group(1)),
            "skipped": parse_int(match.group("skipped") or "0"),
            "failures": parse_int(match.group("failures")),
            "unexpected": parse_int(match.group("unexpected") or "0"),
        })
    return parsed


def verify_swift_test_log(step: str, text: str, failures: list[str]) -> None:
    for summary in swift_test_summaries(step, text, failures):
        if summary["executed"] <= 0:
            failures.append(f"{step} log executed 0 Swift tests")
        if summary["skipped"] > 0:
            failures.append(f"{step} log has {summary['skipped']} skipped Swift tests")
        if summary["failures"] > 0:
            failures.append(f"{step} log has {summary['failures']} Swift test failures")
        if summary["unexpected"] > 0:
            failures.append(f"{step} log has {summary['unexpected']} unexpected Swift test failures")


def verify_swift_report_log_counts(
    report_name: str,
    report: dict[str, Any],
    log_text: str,
    failures: list[str],
) -> None:
    summaries = swift_test_summaries(report_name, log_text, failures)
    if not summaries:
        return
    for summary in summaries:
        if summary["executed"] <= 0:
            failures.append(f"{report_name} log executed 0 Swift tests")
        if summary["skipped"] > 0:
            failures.append(f"{report_name} log has {summary['skipped']} skipped Swift tests")
        if summary["failures"] > 0:
            failures.append(f"{report_name} log has {summary['failures']} Swift test failures")
        if summary["unexpected"] > 0:
            failures.append(f"{report_name} log has {summary['unexpected']} unexpected Swift test failures")

    max_summary = max(summaries, key=lambda summary: summary["executed"])
    for report_key, summary_key in [
        ("executed_test_count", "executed"),
        ("skipped_test_count", "skipped"),
        ("failure_count", "failures"),
        ("unexpected_failure_count", "unexpected"),
    ]:
        reported = report.get(report_key)
        if isinstance(reported, int) and reported != max_summary[summary_key]:
            failures.append(
                f"{report_name} Swift log {report_key} does not match report: "
                f"{max_summary[summary_key]} != {reported}"
            )


def verify_step_log(step: str, path: Path, failures: list[str]) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    stripped = text.strip()
    if not stripped:
        failures.append(f"step log {step} is empty")
        return
    if stripped == "ok":
        failures.append(f"step log {step} is only a placeholder ok")
        return
    if UNAVAILABLE_GATE_MARKER_RE.search(text):
        failures.append(f"{step} log contains unavailable gate marker")
    if "skipped" in text.lower():
        failures.append(f"{step} log contains skipped gate marker")
    if step in SWIFTPM_SCRATCH_STEPS:
        if "--scratch-path" not in text:
            failures.append(f"{step} log command does not use final-gate scratch path")
        if f"swiftpm-scratch/{step}" not in text:
            failures.append(f"{step} log command scratch path is not step scoped")
    if step == "swift-build":
        if not SWIFT_BUILD_COMPLETE_RE.search(text):
            failures.append("swift-build log does not show Swift build completion")
        return
    if step in SWIFT_TEST_STEPS:
        verify_swift_test_log(step, text, failures)
        return
    if step == "core100-closure":
        report = load_json_from_text(text, "core100-closure log", failures)
        if report.get("failure_count") != 0:
            failures.append("core100-closure log failure_count is not 0")
        if report.get("required_command_count") != 100:
            failures.append("core100-closure log required_command_count is not 100")
        return
    if step == "python-oracle-coverage-accounting":
        report = load_json_from_text(text, "python-oracle-coverage-accounting log", failures)
        if report.get("pty_runtime_gate_status") != "executable-by-debian12-pty-oracle":
            failures.append("python oracle coverage log does not prove PTY runtime gate status")
        return
    expected_fragments = {
        "real-model-pressure-preflight-hardening": "real-model pressure preflight checks passed",
        "readex-boundary-check": "MSP Readex boundary verified",
        "exec-session-stress-gate": "MSP exec session stress gate passed",
        "open-source-release-dry-run": "MSP open-source release dry-run passed",
        "dynamic-embedded-cpython-swift-tests": "MSP dynamic embedded CPython Swift tests passed",
        "focused-test-suites-ledger": "MSP focused test suites ledger passed",
        "full-swift-test-suite": "MSP full Swift test suite passed",
        "full-agentbridge-parity-matrix": "MSP full AgentBridge parity matrix passed",
        "debian12-noninteractive-oracle": "passed",
        "live-noninteractive-linux-vps-oracle": "Live noninteractive Linux VPS oracle passed",
        "debian12-linux-pty-report-verify": "verified",
        "real-model-simulator-pressure-matrix": "real-model pressure matrix passed",
    }
    expected = expected_fragments.get(step)
    if expected and expected not in text:
        failures.append(f"{step} log does not contain expected success marker: {expected}")
    if step == "real-model-pressure-preflight-hardening" and not stripped.endswith(expected_fragments[step]):
        failures.append(f"{step} log does not end with expected success marker: {expected_fragments[step]}")
