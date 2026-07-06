from __future__ import annotations

from pathlib import Path
from typing import Any

from msp_pressure_evidence import load_json, require_empty_string_list, string_list

from .artifacts import require_artifact_under_report_root, require_file
from .readex_boundary import (
    FORBIDDEN_EXTERNAL_READEX_MARKERS,
    READ_ONLY_SNAPSHOT_DIRS,
    SCRIPT_SCAN_ROOTS,
    verify_readex_boundary_root,
)
from .swift_logs import verify_swift_report_log_counts

EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_SCHEMA_VERSION = 1
EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_FILE_SET_RULE = (
    "git ls-files -co --exclude-standard -z, existing files and symlinks only"
)
EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_CONTRACT = [
    "copy current publishable Git worktree surface into a temporary release tree",
    "run open-source gates inside the copied release tree",
    "run default SwiftPM tests for MSPPlaygroundApp and PhotoSorter inside the copied release tree",
    "do not treat source-tree-only results as publishable release evidence",
]
EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_REQUIRED_CHECKS = [
    {
        "check_id": "open-source-example-boundary",
        "kind": "gate-script",
        "description": "copied tree only contains the public iOS examples and their allowed dependencies",
    },
    {
        "check_id": "open-source-hygiene",
        "kind": "gate-script",
        "description": "copied tree contains no release-blocking local artifacts or private validation output",
    },
    {
        "check_id": "example-chat-renderer-vendor-hygiene",
        "kind": "gate-script",
        "description": "copied tree example transcript renderer vendor assets have manifests, bounded symlinks, and third-party license evidence",
    },
    {
        "check_id": "open-source-license-notice",
        "kind": "gate-script",
        "description": "copied tree has root license/notice files and public third-party license evidence",
    },
    {
        "check_id": "photosorter-default-package-boundary",
        "kind": "gate-script",
        "description": "copied tree PhotoSorter default package excludes local FastVLM sources, model weights, and MLX package products",
    },
    {
        "check_id": "swift-test-MSPPlaygroundApp",
        "kind": "swiftpm-test",
        "package_path": "Examples/iOS/MSPPlaygroundApp",
        "description": "default SwiftPM test for the public MSPPlaygroundApp example package",
    },
    {
        "check_id": "swift-test-PhotoSorter",
        "kind": "swiftpm-test",
        "package_path": "Examples/iOS/PhotoSorter",
        "description": "default SwiftPM test for the public PhotoSorter example package",
    },
]
EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_REQUIRED_EXAMPLES = [
    {
        "name": "MSPPlaygroundApp",
        "package_path": "Examples/iOS/MSPPlaygroundApp",
        "required_command": "swift test",
    },
    {
        "name": "PhotoSorter",
        "package_path": "Examples/iOS/PhotoSorter",
        "required_command": "swift test",
    },
]
EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_COVERAGE = [
    "copied publishable release tree",
    "open-source example boundary gate on copied tree",
    "open-source hygiene gate on copied tree",
    "example chat renderer vendor/license hygiene gate on copied tree",
    "open-source license/notice gate on copied tree",
    "PhotoSorter default package/local FastVLM boundary gate on copied tree",
    "public MSPPlaygroundApp and PhotoSorter SwiftPM tests on copied tree",
]

REQUIRED_DYNAMIC_EMBEDDED_CPYTHON_TEST_CLASSES = [
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

REQUIRED_DYNAMIC_EMBEDDED_CPYTHON_TEST_CASES = [
    "MSPCPythonEngineWorkspaceTestsBytesAndMetadata/testCPythonEngineDefaultsVirtualTextFilesToUTF8WhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDoesNotSurfaceSurrogateOutputWhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable",
    "MSPCPythonEngineSubprocessPressureMatrixTests/testCPythonEngineSubprocessPopenOsPopenSystemPressureMatrixWhenLibraryIsAvailable",
]

def verify_exec_session_stress(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("exec-session stress report is not an object")
        return {}
    report_root = path.resolve().parent
    if report.get("passed") is not True:
        failures.append("exec-session stress report did not pass")
    if report.get("gate") != "msp-exec-session-stress-gate":
        failures.append("exec-session stress report gate is not msp-exec-session-stress-gate")
    require_empty_string_list(report.get("failures"), "exec-session stress failures", failures)
    swift_filters = string_list(report.get("swift_filters"), "exec-session stress swift_filters", failures)
    if not swift_filters and isinstance(report.get("swift_filter"), str):
        swift_filters = [part for part in report["swift_filter"].split("|") if part]
    for required_filter in [
        "ModelShellProxyExecSessionStressTests",
        "ModelShellProxyExecSessionPTYStressTests",
    ]:
        if required_filter not in swift_filters:
            failures.append(f"exec-session stress swift_filters missing: {required_filter}")
    command = report.get("command")
    if not isinstance(command, list) or command[:2] != ["swift", "test"]:
        failures.append("exec-session stress command is not filtered swift test")
        command = []
    if "--scratch-path" not in command:
        failures.append("exec-session stress command does not use final-gate scratch path")
    if "--filter" not in command:
        failures.append("exec-session stress command is not filtered swift test")
    swift_filter = report.get("swift_filter")
    if not isinstance(swift_filter, str) or not swift_filter:
        failures.append("exec-session stress swift_filter is missing")
    elif command:
        try:
            filter_index = command.index("--filter")
            if filter_index + 1 >= len(command) or command[filter_index + 1] != swift_filter:
                failures.append("exec-session stress command filter does not match swift_filter")
        except ValueError:
            pass
    scratch_root = report.get("scratch_root")
    scratch_path: Path | None = None
    if not isinstance(scratch_root, str) or not scratch_root:
        failures.append("exec-session stress scratch_root is missing or not a path string")
    else:
        scratch_path = Path(scratch_root)
        if not scratch_path.is_dir():
            failures.append(f"exec-session stress scratch_root does not exist: {scratch_root}")
        try:
            scratch_path.resolve().relative_to(report_root)
        except ValueError:
            failures.append("exec-session stress scratch_root is outside report directory")
        if command and "--scratch-path" in command:
            scratch_index = command.index("--scratch-path")
            if scratch_index + 1 >= len(command):
                failures.append("exec-session stress command scratch path is missing")
            elif not isinstance(command[scratch_index + 1], str):
                failures.append("exec-session stress command scratch path is not a string")
            elif Path(command[scratch_index + 1]).resolve() != scratch_path.resolve():
                failures.append("exec-session stress command scratch path does not match scratch_root")
    if report.get("exit_code") != 0:
        failures.append("exec-session stress exit_code is not 0")
    minimum = report.get("minimum_executed_test_count")
    executed = report.get("executed_test_count")
    if not isinstance(minimum, int) or minimum < 15:
        failures.append("exec-session stress minimum_executed_test_count is below 15")
        minimum = 15
    if not isinstance(executed, int) or executed < minimum:
        failures.append("exec-session stress executed_test_count is below required minimum")
    if report.get("skipped_test_count") != 0:
        failures.append("exec-session stress skipped_test_count is not 0")
    if report.get("failure_count") != 0:
        failures.append("exec-session stress failure_count is not 0")
    if report.get("unexpected_failure_count") != 0:
        failures.append("exec-session stress unexpected_failure_count is not 0")
    stress = report.get("stress")
    if not isinstance(stress, dict):
        failures.append("exec-session stress report stress block is missing")
        stress = {}
    minimums = {
        "concurrency": 12,
        "large_output_bytes": 10_485_760,
        "stdin_writes": 24,
        "resource_iterations": 24,
    }
    for key, minimum in minimums.items():
        value = stress.get(key)
        if not isinstance(value, int) or value < minimum:
            failures.append(f"exec-session stress {key} is below required minimum {minimum}")
    coverage = string_list(report.get("coverage"), "exec-session stress coverage", failures)
    for required in [
        "concurrent yielded pipe sessions",
        "PTY high-frequency stdin writes",
        "PTY repeated-session fd leak budget",
        "PTY post-cleanup idle CPU budget",
    ]:
        if required not in coverage:
            failures.append(f"exec-session stress coverage missing: {required}")
    log_path = require_file(report.get("log"), "exec-session stress Swift log", failures)
    if log_path is not None:
        require_artifact_under_report_root(
            log_path,
            "exec-session stress Swift log",
            report_root,
            failures,
        )
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        if not log_text.strip():
            failures.append("exec-session stress Swift log is empty")
        if "Test skipped -" in log_text or " skipped " in log_text:
            failures.append("exec-session stress Swift log contains skipped test marker")
        verify_swift_report_log_counts("exec-session stress", report, log_text, failures)
        for required in [
            "ModelShellProxyExecSessionStressTests",
            "ModelShellProxyExecSessionPTYStressTests",
        ]:
            if required not in log_text:
                failures.append(f"exec-session stress Swift log does not mention required coverage: {required}")
    return report


def verify_readex_boundary(
    path: Path,
    failures: list[str],
    expected_repository_root: Path | None = None,
) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("Readex boundary report is not an object")
        return {}
    if report.get("passed") is not True:
        failures.append("Readex boundary report did not pass")
    require_empty_string_list(report.get("failures"), "Readex boundary failures", failures)
    if report.get("read_only_snapshot_dirs") != READ_ONLY_SNAPSHOT_DIRS:
        failures.append("Readex boundary report does not cover both Readex snapshots")
    dirty_status = report.get("dirty_snapshot_status")
    if not isinstance(dirty_status, list) or dirty_status:
        failures.append("Readex boundary dirty_snapshot_status is missing or non-empty")
    if report.get("forbidden_external_readex_markers") != FORBIDDEN_EXTERNAL_READEX_MARKERS:
        failures.append("Readex boundary forbidden marker contract does not match verifier")
    if report.get("script_scan_roots") != SCRIPT_SCAN_ROOTS:
        failures.append("Readex boundary script_scan_roots does not match verifier")
    scanned_count = report.get("scanned_script_count")
    if not isinstance(scanned_count, int) or scanned_count <= 0:
        failures.append("Readex boundary did not scan release scripts")
    scanned_scripts = report.get("scanned_scripts")
    if not isinstance(scanned_scripts, list) or any(not isinstance(item, str) for item in scanned_scripts):
        failures.append("Readex boundary scanned_scripts is missing or not a string array")
    elif isinstance(scanned_count, int) and scanned_count != len(scanned_scripts):
        failures.append("Readex boundary scanned_script_count does not match scanned_scripts")
    root_raw = report.get("root")
    root: Path | None = None
    if not isinstance(root_raw, str) or not root_raw:
        failures.append("Readex boundary root is missing or not a path string")
    else:
        root = Path(root_raw).expanduser().resolve()
    if expected_repository_root is not None:
        expected_root = expected_repository_root.expanduser().resolve()
        if root is None or root != expected_root:
            failures.append("Readex boundary report root does not match final gate repository_root")
        else:
            recomputed = verify_readex_boundary_root(root)
            if recomputed.get("passed") is not True:
                failures.append("Readex boundary current repository scan did not pass")
            for key in [
                "passed",
                "failures",
                "read_only_snapshot_dirs",
                "dirty_snapshot_status",
                "forbidden_external_readex_markers",
                "script_scan_roots",
                "scanned_script_count",
                "scanned_scripts",
            ]:
                if report.get(key) != recomputed.get(key):
                    failures.append(
                        f"Readex boundary report {key} does not match current repository scan"
                    )
    return report


def verify_open_source_release_dry_run(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    report_root = path.resolve().parent
    if not isinstance(report, dict):
        failures.append("open-source release dry-run report is not an object")
        return {}
    if report.get("schema_version") != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_SCHEMA_VERSION:
        failures.append("open-source release dry-run schema_version does not match verifier contract")
    if report.get("passed") is not True:
        failures.append("open-source release dry-run report did not pass")
    if report.get("gate") != "msp-open-source-release-dry-run":
        failures.append("open-source release dry-run gate is not msp-open-source-release-dry-run")
    require_empty_string_list(report.get("failures"), "open-source release dry-run failures", failures)
    if report.get("release_candidate_contract") != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_CONTRACT:
        failures.append("open-source release dry-run release_candidate_contract does not match verifier contract")
    if report.get("publishable_file_set_rule") != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_FILE_SET_RULE:
        failures.append("open-source release dry-run publishable_file_set_rule does not match verifier contract")
    if report.get("file_set_rule") != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_FILE_SET_RULE:
        failures.append("open-source release dry-run file_set_rule does not match verifier contract")
    if report.get("required_checks") != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_REQUIRED_CHECKS:
        failures.append("open-source release dry-run required_checks do not match required coverage")
    if report.get("required_examples") != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_REQUIRED_EXAMPLES:
        failures.append("open-source release dry-run required_examples do not match required public examples")
    coverage = string_list(report.get("coverage"), "open-source release dry-run coverage", failures)
    if coverage != EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_COVERAGE:
        failures.append("open-source release dry-run coverage does not match required coverage")

    publish_root = report.get("publish_root")
    if not isinstance(publish_root, str) or not publish_root:
        failures.append("open-source release dry-run publish_root is missing or not a string")
    else:
        publish_root_path = Path(publish_root)
        if not publish_root_path.is_dir():
            failures.append("open-source release dry-run publish_root does not exist")
        try:
            publish_root_path.resolve().relative_to(report_root)
        except ValueError:
            failures.append("open-source release dry-run publish_root is outside report directory")

    copy_summary = report.get("copy_summary")
    if not isinstance(copy_summary, dict):
        failures.append("open-source release dry-run copy_summary is missing or not an object")
        copy_summary = {}
    for key in ["candidate_path_count", "copied_file_count"]:
        value = copy_summary.get(key)
        if not isinstance(value, int) or value <= 0:
            failures.append(f"open-source release dry-run {key} is not positive")
    symlink_count = copy_summary.get("copied_symlink_count")
    if not isinstance(symlink_count, int) or symlink_count < 0:
        failures.append("open-source release dry-run copied_symlink_count is not non-negative")
    skipped_paths = copy_summary.get("skipped_paths")
    if not isinstance(skipped_paths, list) or skipped_paths:
        failures.append("open-source release dry-run skipped_paths is missing or non-empty")

    release_tree_checks = report.get("release_tree_checks")
    if not isinstance(release_tree_checks, dict):
        failures.append("open-source release dry-run release_tree_checks is missing or not an object")
        release_tree_checks = {}
    for key in ["path_findings", "symlink_findings", "post_test_generated_path_findings"]:
        findings = release_tree_checks.get(key)
        if not isinstance(findings, list) or findings:
            failures.append(f"open-source release dry-run {key} is missing or non-empty")
    removed_paths = release_tree_checks.get("post_test_removed_paths")
    if not isinstance(removed_paths, list) or any(
        not isinstance(item, str) for item in removed_paths
    ):
        failures.append("open-source release dry-run post_test_removed_paths is missing or not a string list")

    commands = report.get("commands")
    if not isinstance(commands, list):
        failures.append("open-source release dry-run commands is missing or not a list")
        commands = []
    seen_boundary = False
    seen_hygiene = False
    seen_renderer_vendor_hygiene = False
    seen_license_notice = False
    seen_photosorter_package_boundary = False
    seen_check_ids: set[str] = set()
    seen_swift_tests: set[str] = set()
    required_swift_packages = {
        "Examples/iOS/MSPPlaygroundApp",
        "Examples/iOS/PhotoSorter",
    }
    for index, command_report in enumerate(commands):
        if not isinstance(command_report, dict):
            failures.append(f"open-source release dry-run command {index} is not an object")
            continue
        command = command_report.get("command")
        if not isinstance(command, list) or any(not isinstance(item, str) for item in command):
            failures.append(f"open-source release dry-run command {index} command is not a string list")
            command = []
        check_id = command_report.get("check_id")
        if not isinstance(check_id, str) or not check_id:
            failures.append(f"open-source release dry-run command {index} check_id is missing")
        else:
            seen_check_ids.add(check_id)
        command_text = " ".join(command)
        if "check_open_source_example_boundary.py" in command_text:
            seen_boundary = True
        if "check_open_source_hygiene.py" in command_text:
            seen_hygiene = True
        if "check_example_chat_renderer_vendor_hygiene.py" in command_text:
            seen_renderer_vendor_hygiene = True
        if "check_open_source_license_notice.py" in command_text:
            seen_license_notice = True
        if "check_photosorter_default_package_boundary.py" in command_text:
            seen_photosorter_package_boundary = True
        if command[:2] == ["swift", "test"]:
            for package in required_swift_packages:
                if package in command_text:
                    seen_swift_tests.add(package)
                    if command_report.get("package_path") != package:
                        failures.append(
                            f"open-source release dry-run command {index} package_path does not match SwiftPM command"
                        )
            executed = command_report.get("executed_test_count")
            if not isinstance(executed, int) or executed <= 0:
                failures.append(f"open-source release dry-run swift command {index} executed_test_count is not positive")
            skipped = command_report.get("skipped_test_count")
            if not isinstance(skipped, int) or skipped < 0:
                failures.append(f"open-source release dry-run swift command {index} skipped_test_count is not non-negative")
            if command_report.get("failure_count") != 0:
                failures.append(f"open-source release dry-run swift command {index} failure_count is not 0")
            if command_report.get("unexpected_failure_count") != 0:
                failures.append(f"open-source release dry-run swift command {index} unexpected_failure_count is not 0")
        if command_report.get("exit_code") != 0:
            failures.append(f"open-source release dry-run command {index} did not exit 0")
        if command_report.get("passed") is not True:
            failures.append(f"open-source release dry-run command {index} passed flag is not true")
        log_path = require_file(
            command_report.get("log"),
            f"open-source release dry-run command {index} log",
            failures,
        )
        if log_path is not None:
            try:
                log_path.resolve().relative_to(report_root)
            except ValueError:
                failures.append(f"open-source release dry-run command {index} log is outside report directory")
            if not log_path.read_text(encoding="utf-8", errors="replace").strip():
                failures.append(f"open-source release dry-run command {index} log is empty")
        evidence_report = command_report.get("evidence_report")
        if isinstance(evidence_report, str) and evidence_report:
            evidence_report_path = require_file(
                evidence_report,
                f"open-source release dry-run command {index} evidence_report",
                failures,
            )
            if evidence_report_path is not None:
                try:
                    evidence_report_path.resolve().relative_to(report_root)
                except ValueError:
                    failures.append(
                        f"open-source release dry-run command {index} evidence_report is outside report directory"
                    )

    if not seen_boundary:
        failures.append("open-source release dry-run did not run the example boundary gate")
    if not seen_hygiene:
        failures.append("open-source release dry-run did not run the hygiene gate")
    if not seen_renderer_vendor_hygiene:
        failures.append("open-source release dry-run did not run the example chat renderer vendor hygiene gate")
    if not seen_license_notice:
        failures.append("open-source release dry-run did not run the license/notice gate")
    if not seen_photosorter_package_boundary:
        failures.append("open-source release dry-run did not run the PhotoSorter default package boundary gate")
    if seen_swift_tests != required_swift_packages:
        failures.append("open-source release dry-run commands do not cover every required copied-tree SwiftPM test")
    expected_check_ids = {
        item["check_id"] for item in EXPECTED_OPEN_SOURCE_RELEASE_DRY_RUN_REQUIRED_CHECKS
    }
    if seen_check_ids != expected_check_ids:
        failures.append("open-source release dry-run command check_ids do not cover every required check")
    return report


def verify_dynamic_embedded_cpython_swift_tests(path: Path, failures: list[str]) -> dict[str, Any]:
    report = load_json(path)
    if not isinstance(report, dict):
        failures.append("dynamic embedded CPython Swift tests report is not an object")
        return {}
    if report.get("passed") is not True:
        failures.append("dynamic embedded CPython Swift tests report did not pass")
    if report.get("gate") != "msp-dynamic-embedded-cpython-swift-tests":
        failures.append("dynamic embedded CPython Swift tests gate is not msp-dynamic-embedded-cpython-swift-tests")
    require_empty_string_list(report.get("failures"), "dynamic embedded CPython Swift tests failures", failures)

    required_classes = string_list(
        report.get("required_test_classes"),
        "dynamic embedded CPython required_test_classes",
        failures,
    )
    if required_classes != REQUIRED_DYNAMIC_EMBEDDED_CPYTHON_TEST_CLASSES:
        failures.append("dynamic embedded CPython required_test_classes does not match required coverage")
    swift_filter = report.get("swift_filter")
    if not isinstance(swift_filter, str) or not all(name in swift_filter for name in required_classes):
        failures.append("dynamic embedded CPython swift_filter does not include every required class")

    required_test_cases = string_list(
        report.get("required_test_cases"),
        "dynamic embedded CPython required_test_cases",
        failures,
    )
    if required_test_cases != REQUIRED_DYNAMIC_EMBEDDED_CPYTHON_TEST_CASES:
        failures.append("dynamic embedded CPython required_test_cases does not match required coverage")
    executed_test_names = string_list(
        report.get("executed_test_names"),
        "dynamic embedded CPython executed_test_names",
        failures,
    )
    for required in REQUIRED_DYNAMIC_EMBEDDED_CPYTHON_TEST_CASES:
        if required not in executed_test_names:
            failures.append(f"dynamic embedded CPython executed_test_names missing required test case: {required}")

    executed = report.get("executed_test_count")
    minimum = report.get("minimum_dynamic_test_count")
    if not isinstance(minimum, int) or minimum < 20:
        failures.append("dynamic embedded CPython minimum_dynamic_test_count is below 20")
        minimum = 20
    if not isinstance(executed, int) or executed < minimum:
        failures.append("dynamic embedded CPython executed_test_count is below required minimum")
    if report.get("skipped_test_count") != 0:
        failures.append("dynamic embedded CPython skipped_test_count is not 0")
    if report.get("failure_count") != 0:
        failures.append("dynamic embedded CPython failure_count is not 0")
    if report.get("unexpected_failure_count") != 0:
        failures.append("dynamic embedded CPython unexpected_failure_count is not 0")
    if not isinstance(report.get("cpython_library_path"), str) or not report.get("cpython_library_path"):
        failures.append("dynamic embedded CPython report does not record cpython_library_path")

    log_path = require_file(report.get("log"), "dynamic embedded CPython Swift tests log", failures)
    if log_path is not None:
        report_root = path.resolve().parent
        try:
            log_path.resolve().relative_to(report_root)
        except ValueError:
            failures.append("dynamic embedded CPython Swift tests log is outside report directory")
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        if not log_text.strip():
            failures.append("dynamic embedded CPython Swift tests log is empty")
        if "skipped" in log_text.lower():
            failures.append("dynamic embedded CPython Swift tests log contains skipped marker")
        verify_swift_report_log_counts("dynamic embedded CPython Swift tests", report, log_text, failures)
        for required in required_classes:
            if required not in log_text:
                failures.append(f"dynamic embedded CPython Swift tests log does not mention {required}")
        for required in REQUIRED_DYNAMIC_EMBEDDED_CPYTHON_TEST_CASES:
            _, test_method = required.split("/", 1)
            if test_method not in log_text:
                failures.append(f"dynamic embedded CPython Swift tests log does not mention required test case: {required}")
    return report
