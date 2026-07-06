#!/usr/bin/env python3
"""Write the final-gate focused test-suite ledger."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True


FOCUSED_TEST_SUITES: list[dict[str, Any]] = [
    {
        "step": "exec-command-bridge-tests",
        "kind": "swift-test",
        "package_path": ".",
        "command": ["swift", "test", "--filter", "MSPExecCommandBridgeTests"],
        "swift_filter": "MSPExecCommandBridgeTests",
        "coverage": ["AgentBridge exec_command schema and bridge contract"],
    },
    {
        "step": "pipe-session-contract-tests",
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession",
        ],
        "swift_filter": "ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession",
        "coverage": ["pipe-backed exec session contract"],
    },
    {
        "step": "pty-session-contract-tests",
        "kind": "swift-test",
        "package_path": ".",
        "command": [
            "swift",
            "test",
            "--filter",
            "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY",
        ],
        "swift_filter": "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY",
        "coverage": ["PTY-backed exec session contract"],
    },
    {
        "step": "pty-session-interactive-tests",
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
    {
        "step": "exec-session-stress-gate",
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
    {
        "step": "yielded-session-poll-tests",
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
    {
        "step": "python-vfs-path-semantics-tests",
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
    {
        "step": "python-subprocess-policy-tests",
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
    {
        "step": "python-script-traceback-path-tests",
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
    {
        "step": "external-runner-path-virtualization-tests",
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
    {
        "step": "profile-asset-tests",
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
    {
        "step": "mixed-workspace-lazy-remote-tests",
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
    {
        "step": "workspace-ui-snapshot-consistency-tests",
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
    {
        "step": "photosorter-overlay-view-consistency-tests",
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
    {
        "step": "photosorter-ui-preview-cache-consistency-tests",
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
    {
        "step": "photosorter-ui-thumbnail-cache-consistency-tests",
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
    {
        "step": "open-source-release-dry-run",
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
    {
        "step": "dynamic-embedded-cpython-swift-tests",
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
]


def _step_scratch_path(step: str) -> str:
    return f"$OUT_DIR/swiftpm-scratch/{step}"


def _with_final_gate_scratch_contract(contract: dict[str, Any]) -> dict[str, Any]:
    entry = dict(contract)
    step = str(entry.get("step", ""))
    command = list(entry.get("command", []))
    if command[:2] == ["swift", "test"] and "--scratch-path" not in command:
        insert_index = command.index("--filter") if "--filter" in command else len(command)
        command[insert_index:insert_index] = ["--scratch-path", _step_scratch_path(step)]
        entry["command"] = command
    if step == "exec-session-stress-gate" and command and command[0] == "env":
        scratch_env = "MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT=$OUT_DIR/exec-session-stress/scratch"
        if scratch_env not in command:
            insert_index = command.index("bash") if "bash" in command else len(command)
            command[insert_index:insert_index] = [scratch_env]
            entry["command"] = command
    return entry


FOCUSED_TEST_SUITES = [
    _with_final_gate_scratch_contract(contract)
    for contract in FOCUSED_TEST_SUITES
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Write a structured ledger for every focused final-gate validation entry."
    )
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    out_dir = args.out_dir.resolve()
    failures: list[str] = []
    entries: list[dict[str, Any]] = []

    for contract in FOCUSED_TEST_SUITES:
        step = contract["step"]
        log_path = out_dir / f"{step}.log"
        entry = dict(contract)
        entry["log"] = str(log_path)
        entry["log_exists"] = log_path.is_file()
        entry["log_nonempty"] = log_path.is_file() and log_path.stat().st_size > 0
        if not entry["log_exists"]:
            failures.append(f"missing focused test-suite step log: {step}")
        elif not entry["log_nonempty"]:
            failures.append(f"empty focused test-suite step log: {step}")

        relative_artifact = entry.get("evidence_artifact_relative_path")
        if isinstance(relative_artifact, str):
            artifact_path = out_dir / relative_artifact
            entry["evidence_artifact"] = str(artifact_path)
            entry["evidence_artifact_exists"] = artifact_path.is_file()
            if not artifact_path.is_file():
                failures.append(f"missing focused test-suite evidence artifact for {step}: {relative_artifact}")

        entries.append(entry)

    report = {
        "passed": not failures,
        "gate": "msp-focused-test-suites-ledger",
        "root": str(root),
        "out_dir": str(out_dir),
        "required_entry_count": len(FOCUSED_TEST_SUITES),
        "required_steps": [entry["step"] for entry in FOCUSED_TEST_SUITES],
        "entries": entries,
        "failures": failures,
    }

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if failures:
        print("MSP focused test suites ledger failed")
        print(f"report={args.report}")
        for failure in failures:
            print(failure)
        return 1
    print("MSP focused test suites ledger passed")
    print(f"report={args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
