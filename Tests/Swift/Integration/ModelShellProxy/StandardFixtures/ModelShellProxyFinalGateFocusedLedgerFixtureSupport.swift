import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateFocusedLedgerFixture(rootURL: URL) throws -> URL {
        let reportURL = rootURL
            .appendingPathComponent("focused-test-suites-ledger")
            .appendingPathComponent("focused-test-suites-ledger-report.json")
        let entries = finalGateFocusedTestSuitesLedgerEntries(rootURL: rootURL)
        try writeJSONObject([
            "passed": true,
            "gate": "msp-focused-test-suites-ledger",
            "root": try ModelShellProxyConformanceSupport.packageRoot().path,
            "out_dir": rootURL.path,
            "required_entry_count": entries.count,
            "required_steps": entries.compactMap { $0["step"] },
            "entries": entries,
            "failures": []
        ], to: reportURL)
        return reportURL
    }

    static func finalGateFocusedTestSuitesLedgerEntries(rootURL: URL) -> [[String: Any]] {
        let contracts: [[String: Any]] = [
            [
                "step": "exec-command-bridge-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": ["swift", "test", "--filter", "MSPExecCommandBridgeTests"],
                "swift_filter": "MSPExecCommandBridgeTests",
                "coverage": ["AgentBridge exec_command schema and bridge contract"]
            ],
            [
                "step": "pipe-session-contract-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession"
                ],
                "swift_filter": "ModelShellProxyPOSIXCommandSmokeTests/testExecCommandPipeSession",
                "coverage": ["pipe-backed exec session contract"]
            ],
            [
                "step": "pty-session-contract-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY"
                ],
                "swift_filter": "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgePTY",
                "coverage": ["PTY-backed exec session contract"]
            ],
            [
                "step": "pty-session-interactive-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgeYieldsPTYSessionAndWritesInteractiveStdin"
                ],
                "swift_filter": "ModelShellProxyExecCommandPipelineTests/testExecCommandBridgeYieldsPTYSessionAndWritesInteractiveStdin",
                "coverage": ["interactive PTY stdin continuation"]
            ],
            [
                "step": "exec-session-stress-gate",
                "kind": "gate-script",
                "package_path": ".",
                "command": [
                    "env",
                    "MSP_EXEC_SESSION_STRESS_GATE_OUT_DIR=$OUT_DIR/exec-session-stress",
                    "bash",
                    "Conformance/Scripts/run_exec_session_stress_gate.sh"
                ],
                "coverage": [
                    "concurrent yielded pipe sessions",
                    "PTY high-frequency stdin writes",
                    "PTY lifecycle and cleanup pressure"
                ],
                "evidence_artifact_key": "exec_session_stress_report",
                "evidence_artifact_relative_path": "exec-session-stress/exec-session-stress-report.json"
            ],
            [
                "step": "yielded-session-poll-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "MSPAgentConversationExecSessionRequestTests/testConversationCanPollYieldedExecSessionWithWriteStdinTool"
                ],
                "swift_filter": "MSPAgentConversationExecSessionRequestTests/testConversationCanPollYieldedExecSessionWithWriteStdinTool",
                "coverage": ["AgentBridge write_stdin polling for yielded sessions"]
            ],
            [
                "step": "python-vfs-path-semantics-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual|MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual|MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes"
                ],
                "swift_filter": "MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual|MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual|MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes",
                "coverage": [
                    "Python VFS tempfile, dir_fd, pathlib, and escape-guard semantics stay virtual"
                ]
            ],
            [
                "step": "python-subprocess-policy-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "MSPPythonHostProcessSubprocessTests/testHostProcessPythonSubprocessHonorsCommandPackExclusions|MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual|MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonSubprocessHandlesComplexSyntaxAndLongCommands|MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonOsPopenAndSystemUseControlledShellWithoutPathLeaks|MSPPythonSubprocessBrokerTests/testRunDelegatesToBaseCommandLineRunnerWithVirtualPolicyContext|MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt|MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream|MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream"
                ],
                "swift_filter": "MSPPythonHostProcessSubprocessTests/testHostProcessPythonSubprocessHonorsCommandPackExclusions|MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual|MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker|MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonSubprocessHandlesComplexSyntaxAndLongCommands|MSPPythonHostProcessSubprocessShellMatrixTests/testHostProcessPythonOsPopenAndSystemUseControlledShellWithoutPathLeaks|MSPPythonSubprocessBrokerTests/testRunDelegatesToBaseCommandLineRunnerWithVirtualPolicyContext|MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt|MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream|MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream",
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
                    "host-process subprocess shell matrix covers complex syntax, long command lines, os.popen, and os.system"
                ]
            ],
            [
                "step": "python-script-traceback-path-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "MSPPythonHostProcessTracebackTests/testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath|MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs|MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete"
                ],
                "swift_filter": "MSPPythonHostProcessTracebackTests/testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath|MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs|MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete",
                "coverage": [
                    "Python temporary script entrypoint traceback paths stay virtual",
                    "encoded file URL output paths stay virtual",
                    "split streaming output paths stay virtual"
                ]
            ],
            [
                "step": "external-runner-path-virtualization-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs|MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual|MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths|MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput|MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths"
                ],
                "swift_filter": "MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs|MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual|MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths|MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput|MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths|MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths",
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
                    "host-process external runner environment and stdout/stderr paths stay virtual"
                ]
            ],
            [
                "step": "profile-asset-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "ModelShellProxyProfileConformanceTests/testModelWorkspaceExecutionSDKProfileReferencesLiveOracleAssets"
                ],
                "swift_filter": "ModelShellProxyProfileConformanceTests/testModelWorkspaceExecutionSDKProfileReferencesLiveOracleAssets",
                "coverage": ["profile references live oracle and release assets"]
            ],
            [
                "step": "mixed-workspace-lazy-remote-tests",
                "kind": "swift-test",
                "package_path": ".",
                "command": [
                    "swift",
                    "test",
                    "--filter",
                    "ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends|ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead"
                ],
                "swift_filter": "ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends|ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead",
                "coverage": ["mixed workspace host/virtual consistency plus Python subprocess remote/lazy range-read seed"]
            ],
            [
                "step": "workspace-ui-snapshot-consistency-tests",
                "kind": "swift-package-test",
                "package_path": "Examples/iOS/MSPPlaygroundApp",
                "command": [
                    "swift",
                    "test",
                    "--package-path",
                    "Examples/iOS/MSPPlaygroundApp",
                    "--filter",
                    "MSPPlaygroundWorkspaceProfileTests"
                ],
                "swift_filter": "MSPPlaygroundWorkspaceProfileTests",
                "coverage": ["MSPPlaygroundApp workspace UI snapshot consistency"]
            ],
            [
                "step": "photosorter-overlay-view-consistency-tests",
                "kind": "swift-package-test",
                "package_path": "Examples/iOS/PhotoSorter",
                "command": [
                    "swift",
                    "test",
                    "--package-path",
                    "Examples/iOS/PhotoSorter",
                    "--filter",
                    "PhotoLibraryWorkspaceFileSystemPathTests/testPhotoLibraryWorkspaceOverlayKeepsTreeLookupReadPreviewAndRestoreConsistent"
                ],
                "swift_filter": "PhotoLibraryWorkspaceFileSystemPathTests/testPhotoLibraryWorkspaceOverlayKeepsTreeLookupReadPreviewAndRestoreConsistent",
                "coverage": [
                    "PhotoSorter virtual overlay tree lookup, read, preview, and restore consistency"
                ]
            ],
            [
                "step": "photosorter-ui-preview-cache-consistency-tests",
                "kind": "swift-package-test",
                "package_path": "Examples/iOS/PhotoSorter",
                "command": [
                    "swift",
                    "test",
                    "--package-path",
                    "Examples/iOS/PhotoSorter",
                    "--filter",
                    "MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges"
                ],
                "swift_filter": "MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges",
                "coverage": [
                    "PhotoSorter UI preview cache invalidates when the workspace view version changes"
                ]
            ],
            [
                "step": "photosorter-ui-thumbnail-cache-consistency-tests",
                "kind": "swift-package-test",
                "package_path": "Examples/iOS/PhotoSorter",
                "command": [
                    "swift",
                    "test",
                    "--package-path",
                    "Examples/iOS/PhotoSorter",
                    "--filter",
                    "MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion"
                ],
                "swift_filter": "MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion",
                "coverage": [
                    "PhotoSorter UI thumbnail cache keys include the workspace view version"
                ]
            ],
            [
                "step": "open-source-release-dry-run",
                "kind": "gate-script",
                "package_path": ".",
                "command": [
                    "python3",
                    "Conformance/Scripts/run_open_source_release_dry_run.py",
                    "--out-dir",
                    "$OUT_DIR/open-source-release-dry-run",
                    "--report",
                    "$OUT_DIR/open-source-release-dry-run/open-source-release-dry-run-report.json"
                ],
                "coverage": [
                    "copied publishable release tree",
                    "open-source example boundary gate on copied tree",
                    "open-source hygiene gate on copied tree",
                    "example chat renderer vendor/license hygiene gate on copied tree",
                    "open-source license/notice gate on copied tree",
                    "PhotoSorter default package/local FastVLM boundary gate on copied tree",
                    "public MSPPlaygroundApp and PhotoSorter SwiftPM tests on copied tree"
                ],
                "evidence_artifact_key": "open_source_release_dry_run_report",
                "evidence_artifact_relative_path": "open-source-release-dry-run/open-source-release-dry-run-report.json"
            ],
            [
                "step": "dynamic-embedded-cpython-swift-tests",
                "kind": "gate-script",
                "package_path": ".",
                "command": [
                    "env",
                    "MSP_DYNAMIC_EMBEDDED_CPYTHON_SWIFT_TESTS_OUT_DIR=$OUT_DIR/dynamic-embedded-cpython-swift-tests",
                    "bash",
                    "Conformance/Scripts/run_dynamic_embedded_cpython_swift_tests.sh"
                ],
                "coverage": ["dynamic embedded CPython workspace, subprocess, and pressure tests"],
                "evidence_artifact_key": "dynamic_embedded_cpython_swift_tests_report",
                "evidence_artifact_relative_path": "dynamic-embedded-cpython-swift-tests/dynamic-embedded-cpython-swift-tests-report.json"
            ]
        ]

        return contracts.map { contract in
            var entry = contract
            guard let step = contract["step"] as? String else {
                return entry
            }
            entry = finalGateFocusedLedgerEntryWithScratchContract(entry, step: step)
            entry["log"] = rootURL.appendingPathComponent("\(step).log").path
            entry["log_exists"] = true
            entry["log_nonempty"] = true
            if let relativePath = contract["evidence_artifact_relative_path"] as? String {
                entry["evidence_artifact"] = rootURL.appendingPathComponent(relativePath).path
                entry["evidence_artifact_exists"] = true
            }
            return entry
        }
    }

    private static func finalGateFocusedLedgerEntryWithScratchContract(
        _ contract: [String: Any],
        step: String
    ) -> [String: Any] {
        var entry = contract
        guard var command = contract["command"] as? [String] else {
            return entry
        }
        if Array(command.prefix(2)) == ["swift", "test"], !command.contains("--scratch-path") {
            let insertIndex = command.firstIndex(of: "--filter") ?? command.count
            command.insert("$OUT_DIR/swiftpm-scratch/\(step)", at: insertIndex)
            command.insert("--scratch-path", at: insertIndex)
            entry["command"] = command
        }
        if step == "exec-session-stress-gate",
           command.first == "env",
           !command.contains("MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT=$OUT_DIR/exec-session-stress/scratch") {
            let insertIndex = command.firstIndex(of: "bash") ?? command.count
            command.insert("MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT=$OUT_DIR/exec-session-stress/scratch", at: insertIndex)
            entry["command"] = command
        }
        return entry
    }
}
