import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsIncompleteFocusedTestSuitesLedger() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-incomplete-focused-ledger")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let ledgerURL = rootURL
            .appendingPathComponent("focused-test-suites-ledger")
            .appendingPathComponent("focused-test-suites-ledger-report.json")
        var ledger = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(ledgerURL)
        var entries = ledger["entries"] as? [[String: Any]] ?? []
        entries.removeAll {
            $0["step"] as? String == "python-subprocess-policy-tests"
        }
        ledger["entries"] = entries
        ledger["failures"] = []
        ledger["passed"] = true
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(ledger, to: ledgerURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("focused test suites ledger entries do not cover every required focused step in order"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("focused test suites ledger missing entry: python-subprocess-policy-tests"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsFocusedLedgerSwiftCommandWithoutScratchPath() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-focused-ledger-missing-scratch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let ledgerURL = rootURL
            .appendingPathComponent("focused-test-suites-ledger")
            .appendingPathComponent("focused-test-suites-ledger-report.json")
        var ledger = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(ledgerURL)
        var entries = ledger["entries"] as? [[String: Any]] ?? []
        if let index = entries.firstIndex(where: { $0["step"] as? String == "exec-command-bridge-tests" }) {
            entries[index]["command"] = ["swift", "test", "--filter", "MSPExecCommandBridgeTests"]
        }
        ledger["entries"] = entries
        ledger["failures"] = []
        ledger["passed"] = true
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(ledger, to: ledgerURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("focused test suites ledger exec-command-bridge-tests command does not match required contract"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("focused test suites ledger exec-command-bridge-tests command does not use final-gate scratch path"),
            failed.stderr
        )
    }
}
