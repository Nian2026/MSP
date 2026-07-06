import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierAcceptsCleanFixture() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-clean")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )

        let clean = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertEqual(clean.exitCode, 0, clean.stderr)
        let summary = try String(
            contentsOf: rootURL.appendingPathComponent("final-exec-session-gate-report-verification.json"),
            encoding: .utf8
        )
        XCTAssertTrue(summary.contains(#""passed": true"#), summary)
        let summaryObject = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(
            rootURL.appendingPathComponent("final-exec-session-gate-report-verification.json")
        )
        let linuxAlignment = try XCTUnwrap(
            summaryObject["linux_character_oracle_alignment"] as? [String: Any],
            summary
        )
        XCTAssertEqual(
            linuxAlignment["kind"] as? String,
            "linux-character-level-oracle-alignment"
        )
        XCTAssertEqual(linuxAlignment["all_character_oracle_cases_passed"] as? Bool, true)
        XCTAssertEqual(linuxAlignment["compatibility_adjustments_empty"] as? Bool, true)
        XCTAssertEqual(linuxAlignment["total_selected_case_count"] as? Int, 1_162)
        XCTAssertEqual(linuxAlignment["total_passed_case_count"] as? Int, 1_162)
        XCTAssertEqual(linuxAlignment["total_failed_case_count"] as? Int, 0)
        XCTAssertEqual(
            linuxAlignment["oracle_report_keys"] as? [String],
            [
                "core100_noninteractive_oracle_report",
                "debian12_noninteractive_oracle_report",
                "live_noninteractive_linux_vps_oracle_report",
                "debian12_linux_pty_oracle_report"
            ]
        )
    }

    func testFinalGateVerifierRejectsPlaceholderStepLog() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-placeholder-step-log")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try "ok\n".write(
            to: rootURL.appendingPathComponent("swift-build.log"),
            atomically: true,
            encoding: .utf8
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("step log swift-build is only a placeholder ok"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsForgedLinuxCharacterOracleAlignment() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-linux-character-oracle")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        var linuxAlignment = try XCTUnwrap(
            report["linux_character_oracle_alignment"] as? [String: Any]
        )
        linuxAlignment["total_failed_case_count"] = 1
        report["linux_character_oracle_alignment"] = linuxAlignment
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "final gate linux_character_oracle_alignment does not match oracle evidence"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsLinuxCharacterOracleCompatibilityAdjustmentsEvenWhenReported() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-linux-character-adjustment")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let core100URL = rootURL.appendingPathComponent("core100-noninteractive-oracle-report.json")
        var core100 = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(core100URL)
        core100["compatibilityAdjustments"] = ["waived-output-difference"]
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(core100, to: core100URL)

        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        var linuxAlignment = try XCTUnwrap(
            report["linux_character_oracle_alignment"] as? [String: Any]
        )
        linuxAlignment["compatibility_adjustments_empty"] = false
        linuxAlignment["compatibility_adjustments"] = [
            [
                "report": "core100_noninteractive_oracle_report",
                "adjustments": ["waived-output-difference"]
            ]
        ]
        report["linux_character_oracle_alignment"] = linuxAlignment
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "final gate linux_character_oracle_alignment did not prove empty compatibility adjustments"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsReportThatClaimsTotalMSPCompletion() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-total-msp-claim")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        report["completion_scope"] = "msp-open-source-release"
        report["not_final_msp_open_source_release_gate"] = false
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final gate report completion_scope is not exec-session-release-gate"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("final gate report does not mark itself as a non-final MSP open-source release gate"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsEmptyMissingFinalGateClasses() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-empty-missing-final-classes")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        report["missing_final_gate_classes"] = []
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("missing_final_gate_classes does not match final MSP gate blockers"),
            failed.stderr
        )
    }
}
