from __future__ import annotations

import re
from typing import Any

from msp_pressure_evidence import REQUIRED_MODEL, REQUIRED_PRESSURE_SUITES

REQUIRED_STEPS = [
    "real-model-pressure-preflight-hardening",
    "readex-boundary-check",
    "swift-build",
    "exec-command-bridge-tests",
    "pipe-session-contract-tests",
    "pty-session-contract-tests",
    "pty-session-interactive-tests",
    "exec-session-stress-gate",
    "yielded-session-poll-tests",
    "python-vfs-path-semantics-tests",
    "python-subprocess-policy-tests",
    "python-script-traceback-path-tests",
    "external-runner-path-virtualization-tests",
    "profile-asset-tests",
    "mixed-workspace-lazy-remote-tests",
    "workspace-ui-snapshot-consistency-tests",
    "photosorter-overlay-view-consistency-tests",
    "photosorter-ui-preview-cache-consistency-tests",
    "photosorter-ui-thumbnail-cache-consistency-tests",
    "open-source-release-dry-run",
    "dynamic-embedded-cpython-swift-tests",
    "focused-test-suites-ledger",
    "full-swift-test-suite",
    "full-agentbridge-parity-matrix",
    "core100-closure",
    "core100-noninteractive-oracle",
    "python-oracle-coverage-accounting",
    "debian12-noninteractive-oracle",
    "live-noninteractive-linux-vps-oracle",
    "debian12-linux-pty-oracle",
    "debian12-linux-pty-report-verify",
    "real-model-simulator-pressure-matrix",
]
EXPECTED_COMPLETION_SCOPE = "exec-session-release-gate"
EXPECTED_MISSING_FINAL_GATE_CLASSES: list[str] = [
    "remote-backed-workspace-conformance",
    "lazy-materialized-workspace-conformance",
    "full-ui-preview-thumbnail-cache-e2e-conformance",
    "readex-migration-compatibility-conformance",
]
SWIFT_TEST_STEPS = {
    "exec-command-bridge-tests",
    "pipe-session-contract-tests",
    "pty-session-contract-tests",
    "pty-session-interactive-tests",
    "yielded-session-poll-tests",
    "python-vfs-path-semantics-tests",
    "python-subprocess-policy-tests",
    "python-script-traceback-path-tests",
    "external-runner-path-virtualization-tests",
    "profile-asset-tests",
    "mixed-workspace-lazy-remote-tests",
    "workspace-ui-snapshot-consistency-tests",
    "photosorter-overlay-view-consistency-tests",
    "photosorter-ui-preview-cache-consistency-tests",
    "photosorter-ui-thumbnail-cache-consistency-tests",
    "core100-noninteractive-oracle",
    "debian12-noninteractive-oracle",
    "debian12-linux-pty-oracle",
}
SWIFTPM_SCRATCH_STEPS = {
    "swift-build",
    *SWIFT_TEST_STEPS,
}
SWIFT_TEST_SUMMARY_RE = re.compile(
    r"Executed\s+([0-9,]+)\s+tests?,\s+with\s+"
    r"(?:(?P<skipped>[0-9,]+)\s+tests?\s+skipped\s+and\s+)?"
    r"(?P<failures>[0-9,]+)\s+failures?"
    r"(?:\s+\((?P<unexpected>[0-9,]+)\s+unexpected\))?",
    re.IGNORECASE,
)
SWIFT_BUILD_COMPLETE_RE = re.compile(
    r"(?:^|\n)(?:Build complete!|Build of target: '[^']+' complete!)(?:\s|\(|$)",
    re.IGNORECASE,
)
REQUIRED_EVIDENCE_KEYS = [
    "real_model_pressure_preflight_report",
    "readex_boundary_report",
    "exec_session_stress_report",
    "open_source_release_dry_run_report",
    "dynamic_embedded_cpython_swift_tests_report",
    "focused_test_suites_ledger_report",
    "full_swift_test_suite_report",
    "full_agentbridge_parity_matrix_report",
    "core100_noninteractive_oracle_report",
    "debian12_noninteractive_oracle_report",
    "live_noninteractive_linux_vps_oracle_report",
    "debian12_linux_pty_oracle_report",
    "real_model_pressure_matrix_report",
    "real_model_pressure_suite_reports",
]
EXPECTED_EVIDENCE_RELATIVE_PATHS = {
    "real_model_pressure_preflight_report": "real-model-pressure-preflight-report.json",
    "readex_boundary_report": "readex-boundary-report.json",
    "exec_session_stress_report": "exec-session-stress/exec-session-stress-report.json",
    "open_source_release_dry_run_report": "open-source-release-dry-run/open-source-release-dry-run-report.json",
    "dynamic_embedded_cpython_swift_tests_report": "dynamic-embedded-cpython-swift-tests/dynamic-embedded-cpython-swift-tests-report.json",
    "focused_test_suites_ledger_report": "focused-test-suites-ledger/focused-test-suites-ledger-report.json",
    "full_swift_test_suite_report": "full-swift-test-suite/full-swift-test-suite-report.json",
    "full_agentbridge_parity_matrix_report": "full-agentbridge-parity-matrix/full-agentbridge-parity-matrix-report.json",
    "core100_noninteractive_oracle_report": "core100-noninteractive-oracle-report.json",
    "debian12_noninteractive_oracle_report": "debian12-noninteractive-oracle-report.json",
    "live_noninteractive_linux_vps_oracle_report": "live-noninteractive-linux-vps-oracle-report.json",
    "debian12_linux_pty_oracle_report": "debian12-linux-pty-oracle-report.json",
    "real_model_pressure_matrix_report": "real-model-pressure-matrix/pressure-matrix-report.json",
}
EXPECTED_FOCUSED_TEST_SUITES: dict[str, dict[str, Any]] = {
    "exec-command-bridge-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": ["swift", "test", "--filter", "MSPExecCommandBridgeTests"],
        "swift_filter": "MSPExecCommandBridgeTests",
        "coverage": ["AgentBridge exec_command schema and bridge contract"],
    },
    "pipe-session-contract-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": ["swift", "test", "--filter", "ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession"],
        "swift_filter": "ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession",
        "coverage": ["pipe-backed exec session contract"],
    },
    "pty-session-contract-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": ["swift", "test", "--filter", "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY"],
        "swift_filter": "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY",
        "coverage": ["PTY-backed exec session contract"],
    },
    "pty-session-interactive-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgeYieldsPTYSessionAndWritesInteractiveStdin",
        ],
        "swift_filter": "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgeYieldsPTYSessionAndWritesInteractiveStdin",
        "coverage": ["interactive PTY stdin continuation"],
    },
    "exec-session-stress-gate": {
        "kind": "gate-script",
        "package_path": ".",
        "command": [
            "env",
            "MSP_EXEC_SESSION_STRESS_GATE_OUT_DIR=$OUT_DIR/exec-session-stress",
            "bash",
            "Conformance/Scripts/run_exec_session_stress_gate.sh",
        ],
        "coverage": [
            "concurrent yielded pipe sessions",
            "PTY high-frequency stdin writes",
            "PTY lifecycle and cleanup pressure",
        ],
        "evidence_artifact_key": "exec_session_stress_report",
        "evidence_artifact_relative_path": "exec-session-stress/exec-session-stress-report.json",
    },
    "yielded-session-poll-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "MSPAgentConversationExecSessionRequestTests/testConversationCanPollYieldedExecSessionWithWriteStdinTool",
        ],
        "swift_filter": "MSPAgentConversationExecSessionRequestTests/testConversationCanPollYieldedExecSessionWithWriteStdinTool",
        "coverage": ["AgentBridge write_stdin polling for yielded sessions"],
    },
    "python-vfs-path-semantics-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual|"
            "MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual|"
            "MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes",
        ],
        "swift_filter": (
            "MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual|"
            "MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual|"
            "MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes"
        ),
        "coverage": [
            "Python VFS tempfile, dir_fd, pathlib, and escape-guard semantics stay virtual",
        ],
    },
    "python-subprocess-policy-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonSubprocessHonorsCommandPackExclusions|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker|"
            "MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonSubprocessHandlesComplexSyntaxAndLongCommands|"
            "MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonOsPopenAndSystemUseControlledShellWithoutPathLeaks|"
            "MSPPythonSubprocessBrokerTests/testRunDelegatesToBaseCommandLineRunnerWithVirtualPolicyContext|"
            "MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt|"
            "MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream|"
            "MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream",
        ],
        "swift_filter": (
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonSubprocessHonorsCommandPackExclusions|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker|"
            "MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker|"
            "MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonSubprocessHandlesComplexSyntaxAndLongCommands|"
            "MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonOsPopenAndSystemUseControlledShellWithoutPathLeaks|"
            "MSPPythonSubprocessBrokerTests/testRunDelegatesToBaseCommandLineRunnerWithVirtualPolicyContext|"
            "MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt|"
            "MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream|"
            "MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream"
        ),
        "coverage": [
            "Python subprocess policy routes through MSP command runner",
            "Python subprocess Popen sessions preserve returned stdout/stderr for non-streaming runners",
            "Python subprocess Popen sessions merge returned stderr into stdout when requested",
            "Python subprocess Popen stdout/stderr pipes are iterable file-like objects across streaming, bytes, memory, and deferred nested-Python paths",
            "Python subprocess Popen pipe objects expose CPython-compatible file-like metadata, readable/writable/seekable/isatty semantics, and context-manager close semantics",
            "Python subprocess Popen communicate caches completed stdout/stderr results across repeated calls, wait-then-communicate, manual-read-before-communicate, and nested-Python paths",
            "Python subprocess Popen exposes CPython-compatible pid, repr, and send_signal lifecycle semantics without leaking MSP internal class names",
            "Python subprocess.run and Popen expose CPython-compatible text-mode behavior and reject conflicting text/universal_newlines arguments",
            "Python subprocess.run and Popen stdout/stderr writable file targets write through the MSP virtual filesystem",
            "Python subprocess.run and Popen reject invalid stream/stdin targets before child execution with CPython-compatible diagnostics",
            "Python subprocess TimeoutExpired exceptions preserve the caller command in cmd without leaking MSP session ids",
            "Python subprocess TimeoutExpired exceptions preserve CPython-compatible partial stdout/stderr bytes for run and communicate timeouts",
            "nested Python subprocess traceback paths stay virtual",
            "nested Python script subprocesses preserve virtual cwd, argv, sys.path[0], and sibling-file access",
            "host-process subprocess shell matrix covers complex syntax, long command lines, os.popen, and os.system",
        ],
    },
    "python-script-traceback-path-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            (
                "MSPPythonHostProcessTracebackTests/testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath|"
                "MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs|"
                "MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete"
            ),
        ],
        "swift_filter": (
            "MSPPythonHostProcessTracebackTests/"
            "testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath|"
            "MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs|"
            "MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete"
        ),
        "coverage": [
            "Python temporary script entrypoint traceback paths stay virtual",
            "encoded file URL output paths stay virtual",
            "split streaming output paths stay virtual",
        ],
    },
    "external-runner-path-virtualization-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths",
        ],
        "swift_filter": (
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths|"
            "MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths"
        ),
        "coverage": [
            "host-process external runner maps virtual absolute path arguments to host paths",
            "host-process external runner maps virtual paths embedded in option values",
            "host-process external runner maps virtual paths carried in environment values to host paths",
            "host-process external runner maps virtual paths carried in environment path lists to host paths",
            "host-process external runner maps virtual file URLs to host file URLs",
            "host-process external runner launch failures keep paths virtual",
            "host-process external runner launch failures do not leak host-only executable paths",
            "host-process external runner output does not leak host-only executable paths or encoded host-only file URLs, and does not duplicate model-visible PATH entries",
            "host-process external runner version output paths stay virtual",
            "host-process external runner environment and stdout/stderr paths stay virtual",
        ],
    },
    "profile-asset-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "ModelShellProxyProfileConformanceTests/testModelWorkspaceExecutionSDKProfileReferencesLiveOracleAssets",
        ],
        "swift_filter": "ModelShellProxyProfileConformanceTests/testModelWorkspaceExecutionSDKProfileReferencesLiveOracleAssets",
        "coverage": ["profile references live oracle and release assets"],
    },
    "mixed-workspace-lazy-remote-tests": {
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            (
                "ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends|"
                "ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead"
            ),
        ],
        "swift_filter": (
            "ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends|"
            "ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead"
        ),
        "coverage": ["mixed workspace host/virtual consistency plus Python subprocess remote/lazy range-read seed"],
    },
    "workspace-ui-snapshot-consistency-tests": {
        "kind": "swift-package-test",
        "package_path": "Examples/iOS/MSPPlaygroundApp",
        "command": [
            "swift",
            "test",
            "--package-path",
            "Examples/iOS/MSPPlaygroundApp",
            "--filter",
            "MSPPlaygroundWorkspaceProfileTests",
        ],
        "swift_filter": "MSPPlaygroundWorkspaceProfileTests",
        "coverage": ["MSPPlaygroundApp workspace UI snapshot consistency"],
    },
    "photosorter-overlay-view-consistency-tests": {
        "kind": "swift-package-test",
        "package_path": "Examples/iOS/PhotoSorter",
        "command": [
            "swift",
            "test",
            "--package-path",
            "Examples/iOS/PhotoSorter",
            "--filter",
            "PhotoLibraryWorkspaceFileSystemPathTests/testPhotoLibraryWorkspaceOverlayKeepsTreeLookupReadPreviewAndRestoreConsistent",
        ],
        "swift_filter": "PhotoLibraryWorkspaceFileSystemPathTests/testPhotoLibraryWorkspaceOverlayKeepsTreeLookupReadPreviewAndRestoreConsistent",
        "coverage": ["PhotoSorter virtual overlay tree lookup, read, preview, and restore consistency"],
    },
    "photosorter-ui-preview-cache-consistency-tests": {
        "kind": "swift-package-test",
        "package_path": "Examples/iOS/PhotoSorter",
        "command": [
            "swift",
            "test",
            "--package-path",
            "Examples/iOS/PhotoSorter",
            "--filter",
            "MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges",
        ],
        "swift_filter": "MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges",
        "coverage": ["PhotoSorter UI preview cache invalidates when the workspace view version changes"],
    },
    "photosorter-ui-thumbnail-cache-consistency-tests": {
        "kind": "swift-package-test",
        "package_path": "Examples/iOS/PhotoSorter",
        "command": [
            "swift",
            "test",
            "--package-path",
            "Examples/iOS/PhotoSorter",
            "--filter",
            "MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion",
        ],
        "swift_filter": "MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion",
        "coverage": ["PhotoSorter UI thumbnail cache keys include the workspace view version"],
    },
    "open-source-release-dry-run": {
        "kind": "gate-script",
        "package_path": ".",
        "command": [
            "python3",
            "Conformance/Scripts/run_open_source_release_dry_run.py",
            "--out-dir",
            "$OUT_DIR/open-source-release-dry-run",
            "--report",
            "$OUT_DIR/open-source-release-dry-run/open-source-release-dry-run-report.json",
        ],
        "coverage": [
            "copied publishable release tree",
            "open-source example boundary gate on copied tree",
            "open-source hygiene gate on copied tree",
            "example chat renderer vendor/license hygiene gate on copied tree",
            "open-source license/notice gate on copied tree",
            "PhotoSorter default package/local FastVLM boundary gate on copied tree",
            "public MSPPlaygroundApp and PhotoSorter SwiftPM tests on copied tree",
        ],
        "evidence_artifact_key": "open_source_release_dry_run_report",
        "evidence_artifact_relative_path": "open-source-release-dry-run/open-source-release-dry-run-report.json",
    },
    "dynamic-embedded-cpython-swift-tests": {
        "kind": "gate-script",
        "package_path": ".",
        "command": [
            "env",
            "MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_OUT_DIR=$OUT_DIR/dynamic-embedded-cpython-swift-tests",
            "bash",
            "Conformance/Scripts/run_dynamic_embedded_cpython_swift_tests.sh",
        ],
        "coverage": ["dynamic embedded CPython workspace, subprocess, and pressure tests"],
        "evidence_artifact_key": "dynamic_embedded_cpython_swift_tests_report",
        "evidence_artifact_relative_path": "dynamic-embedded-cpython-swift-tests/dynamic-embedded-cpython-swift-tests-report.json",
    },
}


def _focused_step_scratch_path(step: str) -> str:
    return f"$OUT_DIR/swiftpm-scratch/{step}"


def _with_final_gate_scratch_contract(step: str, contract: dict[str, Any]) -> dict[str, Any]:
    entry = dict(contract)
    command = list(entry.get("command", []))
    if command[:2] == ["swift", "test"] and "--scratch-path" not in command:
        insert_index = command.index("--filter") if "--filter" in command else len(command)
        command[insert_index:insert_index] = ["--scratch-path", _focused_step_scratch_path(step)]
        entry["command"] = command
    if step == "exec-session-stress-gate" and command and command[0] == "env":
        scratch_env = "MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT=$OUT_DIR/exec-session-stress/scratch"
        if scratch_env not in command:
            insert_index = command.index("bash") if "bash" in command else len(command)
            command[insert_index:insert_index] = [scratch_env]
            entry["command"] = command
    return entry


EXPECTED_FOCUSED_TEST_SUITES = {
    step: _with_final_gate_scratch_contract(step, contract)
    for step, contract in EXPECTED_FOCUSED_TEST_SUITES.items()
}
EXPECTED_FOCUSED_TEST_SUITE_STEPS = list(EXPECTED_FOCUSED_TEST_SUITES)
