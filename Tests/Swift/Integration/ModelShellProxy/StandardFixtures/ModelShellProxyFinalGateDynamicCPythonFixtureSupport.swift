import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateDynamicCPythonFixture(rootURL: URL) throws -> URL {
        let reportURL = rootURL
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests")
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests-report.json")
        let logURL = reportURL.deletingLastPathComponent()
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests.log")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        Test Suite 'MSPCPythonEngineWorkspaceTests' passed.
        Test Case '-[MSPPythonEmbeddedRuntimeTests.MSPCPythonEngineWorkspaceTests testCPythonEngineDefaultsVirtualTextFilesToUTF8WhenLibraryIsAvailable]' passed (0.001 seconds).
        Test Suite 'MSPCPythonEngineSubprocessTests' passed.
        Test Case '-[MSPPythonEmbeddedRuntimeTests.MSPCPythonEngineSubprocessTests testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable]' passed (0.001 seconds).
        Test Case '-[MSPPythonEmbeddedRuntimeTests.MSPCPythonEngineSubprocessTests testCPythonEngineSubprocessTextModeDoesNotSurfaceSurrogateOutputWhenLibraryIsAvailable]' passed (0.001 seconds).
        Test Case '-[MSPPythonEmbeddedRuntimeTests.MSPCPythonEngineSubprocessTests testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable]' passed (0.001 seconds).
        Test Suite 'MSPCPythonEngineControlledSubprocessMatrixTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessCommunicationTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessFileTargetTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessStreamingTests' passed.
        Test Suite 'MSPCPythonEngineControlledSubprocessSignalTests' passed.
        Test Suite 'MSPCPythonEngineSubprocessLifecycleTests' passed.
        Test Suite 'MSPCPythonEngineSubprocessPressureMatrixTests' passed.
        Test Case '-[MSPPythonEmbeddedRuntimeTests.MSPCPythonEngineSubprocessPressureMatrixTests testCPythonEngineSubprocessPopenOsPopenSystemPressureMatrixWhenLibraryIsAvailable]' passed (0.001 seconds).
        Test Suite 'MSPCPythonEnginePressureTests' passed.
        Test Suite 'Selected tests' passed.
        \t Executed 22 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: logURL, atomically: true, encoding: .utf8)
        try writeJSONObject([
            "passed": true,
            "gate": "msp-dynamic-embedded-cpython-swift-tests",
            "swift_filter": "MSPCPythonEngineWorkspaceTests|MSPCPythonEngineSubprocessTests|MSPCPythonEngineControlledSubprocessMatrixTests|MSPCPythonEngineControlledSubprocessCommunicationTests|MSPCPythonEngineControlledSubprocessFileTargetTests|MSPCPythonEngineControlledSubprocessStreamingTests|MSPCPythonEngineControlledSubprocessSignalTests|MSPCPythonEngineSubprocessLifecycleTests|MSPCPythonEngineSubprocessPressureMatrixTests|MSPCPythonEnginePressureTests",
            "minimum_dynamic_test_count": 20,
            "required_test_classes": [
                "MSPCPythonEngineWorkspaceTests",
                "MSPCPythonEngineSubprocessTests",
                "MSPCPythonEngineControlledSubprocessMatrixTests",
                "MSPCPythonEngineControlledSubprocessCommunicationTests",
                "MSPCPythonEngineControlledSubprocessFileTargetTests",
                "MSPCPythonEngineControlledSubprocessStreamingTests",
                "MSPCPythonEngineControlledSubprocessSignalTests",
                "MSPCPythonEngineSubprocessLifecycleTests",
                "MSPCPythonEngineSubprocessPressureMatrixTests",
                "MSPCPythonEnginePressureTests"
            ],
            "required_test_cases": [
                "MSPCPythonEngineWorkspaceTestsBytesAndMetadata/testCPythonEngineDefaultsVirtualTextFilesToUTF8WhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDoesNotSurfaceSurrogateOutputWhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessPressureMatrixTests/testCPythonEngineSubprocessPopenOsPopenSystemPressureMatrixWhenLibraryIsAvailable"
            ],
            "executed_test_names": [
                "MSPCPythonEngineWorkspaceTestsBytesAndMetadata/testCPythonEngineDefaultsVirtualTextFilesToUTF8WhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDoesNotSurfaceSurrogateOutputWhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable",
                "MSPCPythonEngineSubprocessPressureMatrixTests/testCPythonEngineSubprocessPopenOsPopenSystemPressureMatrixWhenLibraryIsAvailable"
            ],
            "out_dir": reportURL.deletingLastPathComponent().path,
            "scratch_root": reportURL.deletingLastPathComponent().appendingPathComponent("scratch").path,
            "log": logURL.path,
            "exit_code": 0,
            "executed_test_count": 22,
            "skipped_test_count": 0,
            "failure_count": 0,
            "unexpected_failure_count": 0,
            "cpython_library_path": "/fixture/Python.framework/Python",
            "cpython_home": "/fixture/Python.framework/Versions/Current",
            "failures": []
        ], to: reportURL)
        return reportURL
    }
}
