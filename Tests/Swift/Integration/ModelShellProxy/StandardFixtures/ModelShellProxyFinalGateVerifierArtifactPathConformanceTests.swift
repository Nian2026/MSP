import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsMissingPressureEventLog() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-pressure-event-log")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try FileManager.default.removeItem(
            at: rootURL
                .appendingPathComponent("real-model-pressure-matrix")
                .appendingPathComponent("host-backed")
                .appendingPathComponent("events.jsonl")
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log artifact does not exist")
                || failed.stderr.contains("pressure matrix host-backed"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsPressureEventLogOutsideSuiteDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-event-log-outside-suite")
        let outsideURL = makeTemporaryURL("final-gate-verifier-event-log-outside-suite-source")
        defer {
            removeTemporaryURL(rootURL)
            removeTemporaryURL(outsideURL)
        }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let outsideEventLogURL = outsideURL.appendingPathComponent("events.jsonl")
        try FileManager.default.copyItem(
            at: rootURL
                .appendingPathComponent("real-model-pressure-matrix")
                .appendingPathComponent("host-backed")
                .appendingPathComponent("events.jsonl"),
            to: outsideEventLogURL
        )
        let suiteReportURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        var suiteReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(suiteReportURL)
        suiteReport["event_log"] = outsideEventLogURL.path
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(suiteReport, to: suiteReportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log artifact is outside suite report directory"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsNonCanonicalPressureEventLogInsideSuiteDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-event-log-non-canonical")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let suiteRootURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
        let forgedEventLogURL = suiteRootURL.appendingPathComponent("old-events.jsonl")
        try FileManager.default.copyItem(
            at: suiteRootURL.appendingPathComponent("events.jsonl"),
            to: forgedEventLogURL
        )
        let suiteReportURL = suiteRootURL.appendingPathComponent("pressure-report.json")
        var suiteReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(suiteReportURL)
        suiteReport["event_log"] = "old-events.jsonl"
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(suiteReport, to: suiteReportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log artifact does not match canonical suite path"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsArtifactsOutsideReportDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-outside-artifacts")
        let outsideURL = makeTemporaryURL("final-gate-verifier-outside-artifact-source")
        defer {
            removeTemporaryURL(rootURL)
            removeTemporaryURL(outsideURL)
        }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let outsidePreflightURL = outsideURL.appendingPathComponent("real-model-pressure-preflight-report.json")
        let outsideSwiftBuildLogURL = outsideURL.appendingPathComponent("swift-build.log")
        try FileManager.default.copyItem(
            at: rootURL.appendingPathComponent("real-model-pressure-preflight-report.json"),
            to: outsidePreflightURL
        )
        try FileManager.default.copyItem(
            at: rootURL.appendingPathComponent("swift-build.log"),
            to: outsideSwiftBuildLogURL
        )

        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        var stepLogs = report["step_logs"] as? [String: String] ?? [:]
        stepLogs["swift-build"] = outsideSwiftBuildLogURL.path
        report["step_logs"] = stepLogs
        var evidence = report["evidence_artifacts"] as? [String: Any] ?? [:]
        evidence["real_model_pressure_preflight_report"] = outsidePreflightURL.path
        report["evidence_artifacts"] = evidence
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("step_logs.swift-build is outside final gate report directory"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "evidence_artifacts.real_model_pressure_preflight_report is outside final gate report directory"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsNonCanonicalArtifactsInsideReportDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-non-canonical-artifacts")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )

        let forgedSwiftBuildLogURL = rootURL.appendingPathComponent("forged-swift-build.log")
        let forgedPreflightURL = rootURL.appendingPathComponent("forged-real-model-pressure-preflight-report.json")
        let forgedSuiteReportURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
            .appendingPathComponent("forged-pressure-report.json")
        try FileManager.default.copyItem(
            at: rootURL.appendingPathComponent("swift-build.log"),
            to: forgedSwiftBuildLogURL
        )
        try FileManager.default.copyItem(
            at: rootURL.appendingPathComponent("real-model-pressure-preflight-report.json"),
            to: forgedPreflightURL
        )
        try FileManager.default.copyItem(
            at: rootURL
                .appendingPathComponent("real-model-pressure-matrix")
                .appendingPathComponent("host-backed")
                .appendingPathComponent("pressure-report.json"),
            to: forgedSuiteReportURL
        )

        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        var stepLogs = report["step_logs"] as? [String: String] ?? [:]
        stepLogs["swift-build"] = forgedSwiftBuildLogURL.path
        report["step_logs"] = stepLogs
        var evidence = report["evidence_artifacts"] as? [String: Any] ?? [:]
        evidence["real_model_pressure_preflight_report"] = forgedPreflightURL.path
        var suiteReports = evidence["real_model_pressure_suite_reports"] as? [String: String] ?? [:]
        suiteReports["host-backed"] = forgedSuiteReportURL.path
        evidence["real_model_pressure_suite_reports"] = suiteReports
        report["evidence_artifacts"] = evidence
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("step_logs.swift-build does not match final gate canonical path"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "evidence_artifacts.real_model_pressure_preflight_report does not match final gate canonical path"
            ),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "evidence_artifacts.real_model_pressure_suite_reports.host-backed does not match final gate canonical path"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsForgedReportDirectoryAndExtraEvidenceKeys() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-report-directory")
        let outsideURL = makeTemporaryURL("final-gate-verifier-forged-report-directory-outside")
        defer {
            removeTemporaryURL(rootURL)
            removeTemporaryURL(outsideURL)
        }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)

        let reportURL = rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        report["out_dir"] = outsideURL.path
        var stepLogs = report["step_logs"] as? [String: String] ?? [:]
        stepLogs["old-green-step"] = rootURL.appendingPathComponent("swift-build.log").path
        report["step_logs"] = stepLogs
        var evidence = report["evidence_artifacts"] as? [String: Any] ?? [:]
        evidence["old_green_evidence"] = rootURL.appendingPathComponent("readex-boundary-report.json").path
        report["evidence_artifacts"] = evidence
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: reportURL
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final gate out_dir does not match report directory"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("step_logs keys do not match required steps"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("evidence_artifacts keys do not match required evidence"),
            failed.stderr
        )
    }
}
