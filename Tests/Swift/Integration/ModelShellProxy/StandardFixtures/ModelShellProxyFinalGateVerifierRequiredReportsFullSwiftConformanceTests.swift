import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsSkippedFullSwiftTestSuiteReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-skipped-full-swift-suite")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let fullSwiftURL = rootURL
            .appendingPathComponent("full-swift-test-suite")
            .appendingPathComponent("full-swift-test-suite-report.json")
        var fullSwift = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(fullSwiftURL)
        fullSwift["passed"] = true
        fullSwift["skipped_test_count"] = 2
        fullSwift["skipped_reasons"] = ["Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython engine test."]
        fullSwift["failures"] = []
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(fullSwift, to: fullSwiftURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("full Swift test suite skipped_test_count is not 0"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("full Swift test suite skipped_reasons is missing or non-empty"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMissingReleaseGateSourceGuardInFullSwiftSuiteReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-release-gate-source-guard")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let fullSwiftURL = rootURL
            .appendingPathComponent("full-swift-test-suite")
            .appendingPathComponent("full-swift-test-suite-report.json")
        var fullSwift = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(fullSwiftURL)
        var requiredFragments = fullSwift["required_log_fragments"] as? [String] ?? []
        requiredFragments.removeAll { $0 == "ModelShellProxyReleaseGateVerifierSourceGuardTests" }
        fullSwift["required_log_fragments"] = requiredFragments
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(fullSwift, to: fullSwiftURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "full Swift test suite required_log_fragments missing: ModelShellProxyReleaseGateVerifierSourceGuardTests"
            ),
            failed.stderr
        )
    }
}
