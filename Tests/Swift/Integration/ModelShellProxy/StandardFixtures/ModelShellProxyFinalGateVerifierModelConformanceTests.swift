import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsMatrixFeedbackThatDoesNotLookLikeLinux() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: false
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed model feedback does not say it looks like regular Linux"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMatrixReportWithWrongModel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-matrix-model")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            matrixModel: "gpt-4.1"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix model is not gpt-5.5"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix model_matches_required is not true"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsFinalGateReportWithWrongModel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-final-model")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            finalGateModel: "gpt-4.1"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final gate model is not gpt-5.5"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("final gate model_matches_required is not true"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsSuiteReportWithWrongModel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-suite-model")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            suiteModel: "gpt-4.1"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure suite report model is not gpt-5.5"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure suite report model_matches_required is not true"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMainPressureRequestWithWrongModel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-main-request-model")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            mainRequestModel: "gpt-4.1"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure model_request_built.models is not exactly [gpt-5.5]"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure model_request_built.all_match_required is not true"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsUndercountedMainPressureRequests() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-undercounted-main-requests")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            modelRequestCount: 1
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure model_request_built.count is below expected_count: 1 < 4"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed model_request_built.count is below expected_count: 1 < 4"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsForgedMainPressureExpectedCount() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-main-request-expected-count")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            modelRequestCount: 4,
            modelRequestExpectedCount: 1
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "host-backed pressure model_request_built.expected_count does not match required pressure turn count: 1 != 4"
            ),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "pressure matrix host-backed model_request_built.expected_count does not match required pressure turn count: 1 != 4"
            ),
            failed.stderr
        )
    }
}
