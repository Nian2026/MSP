import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsSkippedDynamicEmbeddedCPythonSwiftTests() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-skipped-dynamic-cpython")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dynamicURL = rootURL
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests")
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests-report.json")
        var dynamic = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dynamicURL)
        dynamic["passed"] = true
        dynamic["skipped_test_count"] = 13
        dynamic["executed_test_count"] = 13
        dynamic["failures"] = []
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dynamic, to: dynamicURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("dynamic embedded CPython skipped_test_count is not 0"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsTooLowDynamicEmbeddedCPythonMinimum() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-low-dynamic-cpython-minimum")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dynamicURL = rootURL
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests")
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests-report.json")
        var dynamic = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dynamicURL)
        dynamic["minimum_dynamic_test_count"] = 15
        dynamic["executed_test_count"] = 20
        dynamic["skipped_test_count"] = 0
        dynamic["failure_count"] = 0
        dynamic["unexpected_failure_count"] = 0
        dynamic["failures"] = []
        dynamic["passed"] = true
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dynamic, to: dynamicURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("dynamic embedded CPython minimum_dynamic_test_count is below 20"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsDynamicEmbeddedCPythonSwiftLogCountMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-dynamic-cpython-log-count-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )

        let logURL = rootURL
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests")
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests.log")
        try """
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
        Test Suite 'Selected tests' passed.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: logURL, atomically: true, encoding: .utf8)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("dynamic embedded CPython Swift tests log executed 0 Swift tests"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "dynamic embedded CPython Swift tests Swift log executed_test_count does not match report: 0 != 22"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMissingDynamicEmbeddedCPythonRequiredTestCase() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-dynamic-cpython-test-case")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dynamicURL = rootURL
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests")
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests-report.json")
        var dynamic = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dynamicURL)
        let required = "MSPCPythonEngineSubprocessTests/testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable"
        dynamic["executed_test_names"] = (dynamic["executed_test_names"] as? [String] ?? []).filter { $0 != required }
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dynamic, to: dynamicURL)

        let logURL = dynamicURL.deletingLastPathComponent()
            .appendingPathComponent("dynamic-embedded-cpython-swift-tests.log")
        let logText = try String(contentsOf: logURL, encoding: .utf8)
            .replacingOccurrences(
                of: "Test Case '-[MSPPythonEmbeddedRuntimeTests.MSPCPythonEngineSubprocessTests testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable]' passed (0.001 seconds).\n",
                with: ""
            )
        try logText.write(to: logURL, atomically: true, encoding: .utf8)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("dynamic embedded CPython executed_test_names missing required test case"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("dynamic embedded CPython Swift tests log does not mention required test case"),
            failed.stderr
        )
    }
}
