import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsIncompleteCore100OracleReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-incomplete-core100-oracle")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let core100URL = rootURL.appendingPathComponent("core100-noninteractive-oracle-report.json")
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject([
            "failedCaseCount": 1,
            "failedCaseIDs": ["core100-required-find-basic"],
            "failedLikelyLayerCounts": ["command_output_or_exit_semantics": 1],
            "failures": [["id": "core100-required-find-basic"]],
            "selectedCaseCount": 904,
            "passedCaseCount": 903,
            "selectedCommandCounts": ["find": 1]
        ], to: core100URL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive oracle has failed cases"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive oracle did not pass all 905 fixture cases"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive oracle covers fewer than 100 command buckets"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive oracle missing required command bucket: pwd"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive passedCaseIDs does not contain 905 unique cases"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsCore100OracleMissingRequiredCommandBucket() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-core100-command-bucket")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let core100URL = rootURL.appendingPathComponent("core100-noninteractive-oracle-report.json")
        var core100 = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(core100URL)
        var counts = core100["selectedCommandCounts"] as? [String: Int] ?? [:]
        counts.removeValue(forKey: "xargs")
        core100["selectedCommandCounts"] = counts
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(core100, to: core100URL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive oracle missing required command bucket: xargs"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsCore100OracleMissingRequiredPassedCaseID() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-core100-case-id")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let core100URL = rootURL.appendingPathComponent("core100-noninteractive-oracle-report.json")
        var core100 = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(core100URL)
        let required = "stress-s0-pipeline-basic"
        core100["passedCaseIDs"] = (core100["passedCaseIDs"] as? [String] ?? []).filter { $0 != required }
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(core100, to: core100URL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive passedCaseIDs does not contain 905 unique cases"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Core100 noninteractive oracle missing required passed case id: stress-s0-pipeline-basic"),
            failed.stderr
        )
    }
}
