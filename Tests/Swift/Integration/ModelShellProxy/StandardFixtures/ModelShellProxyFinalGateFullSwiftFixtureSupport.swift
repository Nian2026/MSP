import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateFullSwiftTestSuiteFixture(rootURL: URL) throws -> URL {
        let fixturePaths = try writeFinalGateFullSwiftTestSuiteEnvironmentFixture(rootURL: rootURL)
        let reportURL = rootURL
            .appendingPathComponent("full-swift-test-suite")
            .appendingPathComponent("full-swift-test-suite-report.json")
        let logURL = reportURL.deletingLastPathComponent()
            .appendingPathComponent("full-swift-test-suite.log")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let requiredFragments = [
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
            "ModelShellProxyReleaseGateVerifierSourceGuardTests"
        ]
        try """
        Test Suite 'MSPApplyPatchToolTests' passed.
        Test Suite 'MSPPythonHostProcessSubprocessShellMatrixTests' passed.
        Test Suite 'MSPCPythonEngineWorkspaceTests' passed.
        Test Suite 'MSPCPythonEngineSubprocessTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessMatrixTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessCommunicationTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessFileTargetTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessStreamingTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessSignalTests' passed.
        Test Suite 'MSPCPythonEngineSubprocessLifecycleTests' passed.
        Test Suite 'MSPCPythonEngineSubprocessPressureMatrixTests' passed.
        Test Suite 'MSPCPythonEnginePressureTests' passed.
        Test Suite 'ModelShellProxyCore100OracleConformanceTests' passed.
        Test Suite 'ModelShellProxyDebian12OracleConformanceTests' passed.
        Test Suite 'ModelShellProxyDebian12PTYOracleConformanceTests' passed.
        Test Suite 'ModelShellProxyFinalGateVerifierConformanceTests' passed.
        Test Suite 'ModelShellProxyReleaseGateAuxiliarySourceGuardTests' passed.
        Test Suite 'ModelShellProxyReleaseGateConformanceTests' passed.
        Test Suite 'ModelShellProxyReleaseGatePreflightConformanceTests' passed.
        Test Suite 'ModelShellProxyReleaseGateVerifierSourceGuardTests' passed.
        Test Suite 'Selected tests' passed.
        \t Executed 857 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: logURL, atomically: true, encoding: .utf8)
        try writeJSONObject([
            "passed": true,
            "gate": "msp-full-swift-test-suite",
            "package_path": ".",
            "command": [
                "swift",
                "test",
                "--scratch-path",
                reportURL.deletingLastPathComponent().appendingPathComponent("scratch").path
            ],
            "unfiltered": true,
            "swift_filter": "",
            "minimum_executed_test_count": 850,
            "required_log_fragments": requiredFragments,
            "out_dir": reportURL.deletingLastPathComponent().path,
            "scratch_root": reportURL.deletingLastPathComponent().appendingPathComponent("scratch").path,
            "log": logURL.path,
            "exit_code": 0,
            "executed_test_count": 857,
            "skipped_test_count": 0,
            "skipped_reasons": [],
            "failure_count": 0,
            "unexpected_failure_count": 0,
            "environment_contract": [
                "MSP_RUN_CORE100_ORACLE": "1",
                "MSP_RUN_DEBIAN12_ORACLE": "1",
                "MSP_RUN_DEBIAN12_PTY_ORACLE": "1",
                "MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON": "1",
                "MSP_DEBIAN12_PTY_ORACLE_BACKEND": "linux-external",
                "MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX": "1",
                "MSP_CPYTHON_LIBRARY_PATH": fixturePaths.cpythonLibrary.path,
                "MSP_CPYTHON_HOME": fixturePaths.cpythonHome.path,
                "MSP_CODEX_APPLY_PATCH_DYLIB": fixturePaths.applyPatchDylib.path,
                "MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE": fixturePaths.pythonExecutable.path,
                "MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE": fixturePaths.nodeExecutable.path
            ],
            "failures": []
        ], to: reportURL)
        return reportURL
    }

    static func writeFinalGateFullSwiftTestSuiteEnvironmentFixture(rootURL: URL) throws -> (
        cpythonLibrary: URL,
        cpythonHome: URL,
        applyPatchDylib: URL,
        pythonExecutable: URL,
        nodeExecutable: URL
    ) {
        let environmentURL = rootURL.appendingPathComponent("full-swift-test-suite-env")
        let cpythonFrameworkURL = environmentURL.appendingPathComponent("Python.framework")
        let cpythonHomeURL = cpythonFrameworkURL
            .appendingPathComponent("Versions")
            .appendingPathComponent("Current")
        let cpythonLibraryURL = cpythonFrameworkURL.appendingPathComponent("Python")
        let applyPatchDylibURL = environmentURL.appendingPathComponent("libmsp_codex_apply_patch_bridge.dylib")
        let pythonExecutableURL = environmentURL.appendingPathComponent("python3")
        let nodeExecutableURL = environmentURL.appendingPathComponent("node")

        try FileManager.default.createDirectory(at: cpythonHomeURL, withIntermediateDirectories: true)
        try "fixture cpython\n".write(to: cpythonLibraryURL, atomically: true, encoding: .utf8)
        try "fixture apply_patch dylib\n".write(to: applyPatchDylibURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: pythonExecutableURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: nodeExecutableURL, atomically: true, encoding: .utf8)

        return (
            cpythonLibrary: cpythonLibraryURL,
            cpythonHome: cpythonHomeURL,
            applyPatchDylib: applyPatchDylibURL,
            pythonExecutable: pythonExecutableURL,
            nodeExecutable: nodeExecutableURL
        )
    }
}
