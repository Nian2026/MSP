from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from msp_pressure_evidence import load_json, require_empty_string_list, string_list

from .artifacts import require_artifact_under_report_root, require_canonical_artifact_path, require_file
from .contract import EXPECTED_FOCUSED_TEST_SUITE_STEPS, EXPECTED_FOCUSED_TEST_SUITES
from .swift_logs import verify_swift_report_log_counts

def _test_class_counts(raw: Any, label: str, failures: list[str]) -> dict[str, int]:
    if not isinstance(raw, list):
        failures.append(f"{label} is missing or not a list")
        return {}
    counts: dict[str, int] = {}
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            failures.append(f"{label} entry {index} is not an object")
            continue
        name = item.get("name")
        if not isinstance(name, str) or not name:
            failures.append(f"{label} entry {index} has no name")
            continue
        if name in counts:
            failures.append(f"{label} duplicates test class: {name}")
        count = item.get("declared_test_count")
        if not isinstance(count, int) or count <= 0:
            failures.append(f"{label} entry {name} declared_test_count is not positive")
            count = 0
        source_files = item.get("source_files")
        if not isinstance(source_files, list) or not all(isinstance(path, str) and path for path in source_files):
            failures.append(f"{label} entry {name} source_files is missing or invalid")
        counts[name] = count
    return counts


def verify_focused_test_suites_ledger(
    path: Path,
    report_root: Path,
    step_logs: dict[str, Any],
    evidence: dict[str, Any],
    failures: list[str],
) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("focused test suites ledger report is not an object")
        return {}
    if report.get("passed") is not True:
        failures.append("focused test suites ledger report did not pass")
    if report.get("gate") != "msp-focused-test-suites-ledger":
        failures.append("focused test suites ledger gate is not msp-focused-test-suites-ledger")
    require_empty_string_list(report.get("failures"), "focused test suites ledger failures", failures)
    if report.get("required_entry_count") != len(EXPECTED_FOCUSED_TEST_SUITE_STEPS):
        failures.append("focused test suites ledger required_entry_count does not match required focused coverage")
    if string_list(
        report.get("required_steps"),
        "focused test suites ledger required_steps",
        failures,
    ) != EXPECTED_FOCUSED_TEST_SUITE_STEPS:
        failures.append("focused test suites ledger required_steps do not match required focused coverage")

    entries = report.get("entries")
    if not isinstance(entries, list):
        failures.append("focused test suites ledger entries is missing or not a list")
        entries = []
    entry_by_step: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            failures.append(f"focused test suites ledger entry {index} is not an object")
            continue
        step = entry.get("step")
        if not isinstance(step, str) or not step:
            failures.append(f"focused test suites ledger entry {index} has no step")
            continue
        if step in entry_by_step:
            failures.append(f"focused test suites ledger duplicates step: {step}")
        entry_by_step[step] = entry

    if list(entry_by_step) != EXPECTED_FOCUSED_TEST_SUITE_STEPS:
        failures.append("focused test suites ledger entries do not cover every required focused step in order")

    for step in EXPECTED_FOCUSED_TEST_SUITE_STEPS:
        expected = EXPECTED_FOCUSED_TEST_SUITES[step]
        entry = entry_by_step.get(step)
        if entry is None:
            failures.append(f"focused test suites ledger missing entry: {step}")
            continue
        for key in ["kind", "package_path", "command", "coverage"]:
            if entry.get(key) != expected.get(key):
                failures.append(f"focused test suites ledger {step} {key} does not match required contract")
        if expected.get("swift_filter") is not None and entry.get("swift_filter") != expected["swift_filter"]:
            failures.append(f"focused test suites ledger {step} swift_filter does not match required contract")
        command = entry.get("command")
        if entry.get("kind") in {"swift-test", "swift-package-test"}:
            if not isinstance(command, list) or "--scratch-path" not in command:
                failures.append(f"focused test suites ledger {step} command does not use final-gate scratch path")
            elif f"$OUT_DIR/swiftpm-scratch/{step}" not in command:
                failures.append(f"focused test suites ledger {step} command scratch path is not step scoped")

        log_path = require_file(entry.get("log"), f"focused test suites ledger {step} log", failures)
        if log_path is not None:
            require_artifact_under_report_root(
                log_path,
                f"focused test suites ledger {step} log",
                report_root,
                failures,
            )
            require_canonical_artifact_path(
                log_path,
                report_root / f"{step}.log",
                f"focused test suites ledger {step} log",
                failures,
            )
            if step_logs.get(step) != str(log_path):
                failures.append(f"focused test suites ledger {step} log does not match final gate step_logs")
            if entry.get("log_exists") is not True:
                failures.append(f"focused test suites ledger {step} log_exists is not true")
            if entry.get("log_nonempty") is not True:
                failures.append(f"focused test suites ledger {step} log_nonempty is not true")

        expected_artifact_key = expected.get("evidence_artifact_key")
        expected_relative_artifact = expected.get("evidence_artifact_relative_path")
        if isinstance(expected_artifact_key, str) and isinstance(expected_relative_artifact, str):
            if entry.get("evidence_artifact_key") != expected_artifact_key:
                failures.append(f"focused test suites ledger {step} evidence_artifact_key does not match required contract")
            if entry.get("evidence_artifact_relative_path") != expected_relative_artifact:
                failures.append(f"focused test suites ledger {step} evidence_artifact_relative_path does not match required contract")
            artifact_path = require_file(
                entry.get("evidence_artifact"),
                f"focused test suites ledger {step} evidence_artifact",
                failures,
            )
            if artifact_path is not None:
                require_artifact_under_report_root(
                    artifact_path,
                    f"focused test suites ledger {step} evidence_artifact",
                    report_root,
                    failures,
                )
                require_canonical_artifact_path(
                    artifact_path,
                    report_root / expected_relative_artifact,
                    f"focused test suites ledger {step} evidence_artifact",
                    failures,
                )
                if evidence.get(expected_artifact_key) != str(artifact_path):
                    failures.append(
                        f"focused test suites ledger {step} evidence_artifact does not match final gate evidence_artifacts"
                    )
            if entry.get("evidence_artifact_exists") is not True:
                failures.append(f"focused test suites ledger {step} evidence_artifact_exists is not true")
        else:
            for forbidden in [
                "evidence_artifact_key",
                "evidence_artifact_relative_path",
                "evidence_artifact",
                "evidence_artifact_exists",
            ]:
                if forbidden in entry:
                    failures.append(f"focused test suites ledger {step} unexpectedly contains {forbidden}")
    return report


def verify_full_swift_test_suite(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("full Swift test suite report is not an object")
        return {}
    if report.get("passed") is not True:
        failures.append("full Swift test suite report did not pass")
    if report.get("gate") != "msp-full-swift-test-suite":
        failures.append("full Swift test suite gate is not msp-full-swift-test-suite")
    require_empty_string_list(report.get("failures"), "full Swift test suite failures", failures)
    if report.get("package_path") != ".":
        failures.append("full Swift test suite package_path is not root package")
    if report.get("unfiltered") is not True:
        failures.append("full Swift test suite unfiltered flag is not true")
    if report.get("swift_filter") not in ("", None):
        failures.append("full Swift test suite swift_filter is not empty")

    command = report.get("command")
    if not isinstance(command, list) or command[:2] != ["swift", "test"] or "--filter" in command:
        failures.append("full Swift test suite command is not unfiltered swift test")
    if not isinstance(command, list) or "--scratch-path" not in command:
        failures.append("full Swift test suite command does not use final-gate scratch path")

    minimum = report.get("minimum_executed_test_count")
    executed = report.get("executed_test_count")
    if not isinstance(minimum, int) or minimum < 850:
        failures.append("full Swift test suite minimum_executed_test_count is below 850")
        minimum = 850
    if not isinstance(executed, int) or executed < minimum:
        failures.append("full Swift test suite executed_test_count is below required minimum")
    if report.get("skipped_test_count") != 0:
        failures.append("full Swift test suite skipped_test_count is not 0")
    skipped_reasons = report.get("skipped_reasons")
    if not isinstance(skipped_reasons, list) or skipped_reasons:
        failures.append("full Swift test suite skipped_reasons is missing or non-empty")
    if report.get("failure_count") != 0:
        failures.append("full Swift test suite failure_count is not 0")
    if report.get("unexpected_failure_count") != 0:
        failures.append("full Swift test suite unexpected_failure_count is not 0")

    required_fragments = string_list(
        report.get("required_log_fragments"),
        "full Swift test suite required_log_fragments",
        failures,
    )
    for required in [
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
    ]:
        if required not in required_fragments:
            failures.append(f"full Swift test suite required_log_fragments missing: {required}")

    environment = report.get("environment_contract")
    if not isinstance(environment, dict):
        failures.append("full Swift test suite environment_contract is missing or not an object")
        environment = {}
    for key in [
        "MSP_RUN_CORE100_ORACLE",
        "MSP_RUN_DEBIAN12_ORACLE",
        "MSP_RUN_DEBIAN12_PTY_ORACLE",
        "MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON",
        "MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX",
    ]:
        if environment.get(key) != "1":
            failures.append(f"full Swift test suite environment {key} is not 1")
    if environment.get("MSP_DEBIAN12_PTY_ORACLE_BACKEND") != "linux-external":
        failures.append("full Swift test suite environment did not require linux-external PTY oracle backend")
    for key in [
        "MSP_CPYTHON_LIBRARY_PATH",
        "MSP_CODEX_APPLY_PATCH_DYLIB",
        "MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE",
        "MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE",
    ]:
        value = environment.get(key)
        if not isinstance(value, str) or not value:
            failures.append(f"full Swift test suite environment {key} is missing")
        elif not Path(value).exists():
            failures.append(f"full Swift test suite environment {key} does not exist: {value}")

    log_path = require_file(report.get("log"), "full Swift test suite log", failures)
    if log_path is not None:
        report_root = path.resolve().parent
        try:
            log_path.resolve().relative_to(report_root)
        except ValueError:
            failures.append("full Swift test suite log is outside report directory")
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        if not log_text.strip():
            failures.append("full Swift test suite log is empty")
        if "Test skipped -" in log_text:
            failures.append("full Swift test suite log contains skipped test marker")
        verify_swift_report_log_counts("full Swift test suite", report, log_text, failures)
        for required in required_fragments:
            if required not in log_text:
                failures.append(f"full Swift test suite log does not mention required coverage: {required}")
    return report


def verify_full_agentbridge_parity_matrix(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("full AgentBridge parity matrix report is not an object")
        return {}
    if report.get("passed") is not True:
        failures.append("full AgentBridge parity matrix report did not pass")
    if report.get("gate") != "msp-full-agentbridge-parity-matrix":
        failures.append("full AgentBridge parity matrix gate is not msp-full-agentbridge-parity-matrix")
    require_empty_string_list(report.get("failures"), "full AgentBridge parity matrix failures", failures)
    if report.get("package_path") != ".":
        failures.append("full AgentBridge parity matrix package_path is not root package")
    if report.get("test_root") != "Tests/Swift/Unit/MSPAgentBridge":
        failures.append("full AgentBridge parity matrix test_root is not the AgentBridge unit test root")

    command = report.get("command")
    if not isinstance(command, list) or command[:2] != ["swift", "test"]:
        failures.append("full AgentBridge parity matrix command is not filtered swift test")
        command = []
    if "--scratch-path" not in command:
        failures.append("full AgentBridge parity matrix command does not use final-gate scratch path")
    if "--filter" not in command:
        failures.append("full AgentBridge parity matrix command is not filtered swift test")
    if not isinstance(report.get("swift_filter"), str) or not report.get("swift_filter"):
        failures.append("full AgentBridge parity matrix swift_filter is missing")
    elif command:
        try:
            filter_index = command.index("--filter")
            if filter_index + 1 >= len(command) or command[filter_index + 1] != report.get("swift_filter"):
                failures.append("full AgentBridge parity matrix command filter does not match swift_filter")
        except ValueError:
            pass

    report_root = path.resolve().parent
    scratch_root = report.get("scratch_root")
    if not isinstance(scratch_root, str) or not scratch_root:
        failures.append("full AgentBridge parity matrix scratch_root is missing or not a path string")
    else:
        scratch_path = Path(scratch_root)
        if not scratch_path.is_dir():
            failures.append(f"full AgentBridge parity matrix scratch_root does not exist: {scratch_root}")
        try:
            scratch_path.resolve().relative_to(report_root)
        except ValueError:
            failures.append("full AgentBridge parity matrix scratch_root is outside report directory")
        if command and "--scratch-path" in command:
            scratch_index = command.index("--scratch-path")
            if scratch_index + 1 >= len(command):
                failures.append("full AgentBridge parity matrix command scratch path is missing")
            elif not isinstance(command[scratch_index + 1], str):
                failures.append("full AgentBridge parity matrix command scratch path is not a string")
            elif Path(command[scratch_index + 1]).resolve() != scratch_path.resolve():
                failures.append("full AgentBridge parity matrix command scratch path does not match scratch_root")

    minimum = report.get("minimum_executed_test_count")
    declared = report.get("declared_test_count")
    executed = report.get("executed_test_count")
    if not isinstance(minimum, int) or minimum < 180:
        failures.append("full AgentBridge parity matrix minimum_executed_test_count is below 180")
        minimum = 180
    if not isinstance(declared, int) or declared < minimum:
        failures.append("full AgentBridge parity matrix declared_test_count is below required minimum")
    if not isinstance(executed, int) or executed < minimum:
        failures.append("full AgentBridge parity matrix executed_test_count is below required minimum")
    if isinstance(declared, int) and isinstance(executed, int) and executed < declared:
        failures.append("full AgentBridge parity matrix executed_test_count is below declared_test_count")
    if report.get("skipped_test_count") != 0:
        failures.append("full AgentBridge parity matrix skipped_test_count is not 0")
    if report.get("failure_count") != 0:
        failures.append("full AgentBridge parity matrix failure_count is not 0")
    if report.get("unexpected_failure_count") != 0:
        failures.append("full AgentBridge parity matrix unexpected_failure_count is not 0")

    expected_buckets = [
        "exec-command-session-contract",
        "responses-streaming-and-tool-calls",
        "apply-patch-tool",
        "conversation-request-history",
        "interrupt-and-turn-interrupt",
        "compaction-local-auto-remote-replay",
        "goal-capability",
        "turn-steer-capability",
    ]
    buckets = string_list(
        report.get("required_capability_buckets"),
        "full AgentBridge parity matrix required_capability_buckets",
        failures,
    )
    if buckets != expected_buckets:
        failures.append("full AgentBridge parity matrix required_capability_buckets do not match contract")
    bucket_reports = report.get("capability_buckets")
    if not isinstance(bucket_reports, dict):
        failures.append("full AgentBridge parity matrix capability_buckets is missing or not an object")
        bucket_reports = {}
    test_class_counts = _test_class_counts(
        report.get("test_classes"),
        "full AgentBridge parity matrix test_classes",
        failures,
    )
    if isinstance(report.get("test_class_count"), int) and report.get("test_class_count") != len(test_class_counts):
        failures.append("full AgentBridge parity matrix test_class_count does not match test_classes")
    if isinstance(declared, int) and declared != sum(test_class_counts.values()):
        failures.append("full AgentBridge parity matrix declared_test_count does not match test_classes")
    swift_filter = report.get("swift_filter")
    if isinstance(swift_filter, str) and test_class_counts:
        if swift_filter.split("|") != list(test_class_counts):
            failures.append("full AgentBridge parity matrix swift_filter does not match test_classes")
    for bucket in expected_buckets:
        item = bucket_reports.get(bucket)
        if not isinstance(item, dict):
            failures.append(f"full AgentBridge parity matrix capability bucket is missing: {bucket}")
            continue
        if item.get("present") is not True:
            failures.append(f"full AgentBridge parity matrix capability bucket is not present: {bucket}")
        missing = item.get("missing_classes")
        if not isinstance(missing, list) or missing:
            failures.append(f"full AgentBridge parity matrix capability bucket missing_classes is not empty: {bucket}")
        if not isinstance(item.get("classes"), list) or not item.get("classes"):
            failures.append(f"full AgentBridge parity matrix capability bucket has no classes: {bucket}")
            classes: list[str] = []
        else:
            classes = [name for name in item.get("classes", []) if isinstance(name, str)]
            if len(classes) != len(item.get("classes", [])):
                failures.append(f"full AgentBridge parity matrix capability bucket has invalid class names: {bucket}")
        for name in classes:
            if name not in test_class_counts:
                failures.append(f"full AgentBridge parity matrix capability bucket references unknown test class: {bucket}/{name}")
        if not isinstance(item.get("coverage"), list) or not item.get("coverage"):
            failures.append(f"full AgentBridge parity matrix capability bucket has no coverage labels: {bucket}")
        bucket_declared = item.get("declared_test_count")
        if not isinstance(bucket_declared, int) or bucket_declared <= 0:
            failures.append(f"full AgentBridge parity matrix capability bucket has no declared tests: {bucket}")
        elif bucket_declared != sum(test_class_counts.get(name, 0) for name in classes):
            failures.append(f"full AgentBridge parity matrix capability bucket declared_test_count does not match classes: {bucket}")

    environment = report.get("environment_contract")
    if not isinstance(environment, dict):
        failures.append("full AgentBridge parity matrix environment_contract is missing or not an object")
        environment = {}
    dylib = environment.get("MSP_CODEX_APPLY_PATCH_DYLIB")
    if not isinstance(dylib, str) or not dylib:
        failures.append("full AgentBridge parity matrix environment MSP_CODEX_APPLY_PATCH_DYLIB is missing")
    elif not Path(dylib).exists():
        failures.append(f"full AgentBridge parity matrix environment MSP_CODEX_APPLY_PATCH_DYLIB does not exist: {dylib}")

    artifact_paths: dict[str, Path] = {}
    for key, label in [
        ("discovery", "full AgentBridge parity matrix discovery"),
        ("swift_log", "full AgentBridge parity matrix Swift log"),
        ("source_currentness_log", "full AgentBridge parity matrix source-currentness log"),
    ]:
        artifact = require_file(report.get(key), label, failures)
        if artifact is not None:
            require_artifact_under_report_root(artifact, label, report_root, failures)
            artifact_paths[key] = artifact

    discovery_path = artifact_paths.get("discovery")
    if discovery_path is not None:
        discovery = load_json(discovery_path)
        if not isinstance(discovery, dict):
            failures.append("full AgentBridge parity matrix discovery is not an object")
        else:
            require_empty_string_list(
                discovery.get("failures"),
                "full AgentBridge parity matrix discovery failures",
                failures,
            )
            if discovery.get("test_root") != report.get("test_root"):
                failures.append("full AgentBridge parity matrix discovery test_root does not match report")
            if discovery.get("declared_test_count") != declared:
                failures.append("full AgentBridge parity matrix discovery declared_test_count does not match report")
            if discovery.get("test_class_count") != report.get("test_class_count"):
                failures.append("full AgentBridge parity matrix discovery test_class_count does not match report")
            if discovery.get("test_filter") != report.get("swift_filter"):
                failures.append("full AgentBridge parity matrix swift_filter does not match discovery test_filter")
            if discovery.get("required_capability_buckets") != buckets:
                failures.append("full AgentBridge parity matrix required_capability_buckets do not match discovery")
            if discovery.get("capability_buckets") != report.get("capability_buckets"):
                failures.append("full AgentBridge parity matrix capability_buckets do not match discovery")
            if discovery.get("test_classes") != report.get("test_classes"):
                failures.append("full AgentBridge parity matrix test_classes do not match discovery")

    swift_log_path = artifact_paths.get("swift_log")
    if swift_log_path is not None:
        text = swift_log_path.read_text(encoding="utf-8", errors="replace")
        if not text.strip():
            failures.append("full AgentBridge parity matrix Swift log is empty")
        if "Test skipped -" in text or " skipped " in text:
            failures.append("full AgentBridge parity matrix Swift log contains skipped test marker")
        verify_swift_report_log_counts("full AgentBridge parity matrix", report, text, failures)
        for required in [
            "MSPApplyPatchToolTests",
            "MSPExecCommandBridgeTests",
            "MSPResponsesStreamingModelClientTests",
            "MSPGoalCapabilityTests",
            "MSPTurnSteerCapabilityTests",
        ]:
            if required not in text:
                failures.append(f"full AgentBridge parity matrix Swift log does not mention required coverage: {required}")
        for required in test_class_counts:
            if required not in text:
                failures.append(f"full AgentBridge parity matrix Swift log does not mention discovered test class: {required}")

    source = report.get("source_currentness")
    if not isinstance(source, dict):
        failures.append("full AgentBridge parity matrix source_currentness is missing or not an object")
        source = {}
    if source.get("passed") is not True:
        failures.append("full AgentBridge parity matrix source_currentness did not pass")
    if source.get("exit_code") != 0:
        failures.append("full AgentBridge parity matrix source_currentness exit_code is not 0")
    for key in ["pinned_commit", "origin_head"]:
        value = source.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
            failures.append(f"full AgentBridge parity matrix source_currentness {key} is not a commit hash")
    for key in ["codex_paths", "storage_evidence_paths"]:
        value = source.get(key)
        if not isinstance(value, int) or value <= 0:
            failures.append(f"full AgentBridge parity matrix source_currentness {key} is not positive")

    source_log_path = artifact_paths.get("source_currentness_log")
    if source_log_path is not None:
        source_log = source_log_path.read_text(encoding="utf-8", errors="replace")
        if "OK Codex compaction currentness" not in source_log:
            failures.append("full AgentBridge parity matrix source-currentness log did not report OK")
    return report
