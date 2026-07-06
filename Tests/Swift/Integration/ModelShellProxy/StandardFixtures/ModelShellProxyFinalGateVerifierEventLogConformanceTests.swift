import Foundation
import XCTest

final class ModelShellProxyFinalGateVerifierEventLogConformanceTests: XCTestCase {
    func testFinalGateVerifierRejectsPressureEventLogImplementationDisclosure() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-implementation-disclosure")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLog(
            rootURL: pressureMatrixRootURL(rootURL),
            visibleOutput: """
            debug: ios sandbox path backed by msp runtime using a Materialized backend launcher in a virtual workspace and host-backed workspace with direct-host filesystem plus PhotoKit PHAsset localIdentifier, 照片库后端, 虚拟后端, 宿主路径, and 沙盒路径 in iOS Simulator via simctl app container CoreSimulator

            """
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log scanner found model-visible internal path leaks"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(failed.stderr.contains("plain_virtual_backend_disclosure"), failed.stderr)
        XCTAssertTrue(failed.stderr.contains("plain_host_backend_disclosure"), failed.stderr)
        XCTAssertTrue(failed.stderr.contains("plain_photo_backend_disclosure"), failed.stderr)
    }

    func testFinalGateVerifierRejectsPressureEventLogRuntimeErrorEvenWhenReportIsForgedClean() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-runtime-error-event-log")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try appendRuntimeError(
            rootURL: pressureMatrixRootURL(rootURL),
            suite: "host-backed",
            message: "synthetic runtime failure"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log runtime_error observed: synthetic runtime failure"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsPressureEventLogWithoutToolExecutionEvenWhenReportIsForgedClean() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-no-tool-execution-event-log")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithoutTools(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log did not execute workspace commands"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsCollapsedPressureFinalAnswersEvenWhenReportMatchesEventLog() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-collapsed-final-answers")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithCollapsedFinalAnswers(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log final_answer count 2 is below expected pressure turn count 4"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsSharedSentinelPressureFinalAnswerEvenWhenCountsMatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-shared-sentinel-final-answer")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithSharedSentinelFinalAnswer(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log completion sentinels share one final answer"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsExtraPressureFinalAnswerEvenWhenSentinelsArePresent() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-extra-final-answer")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithExtraFillerFinalAnswer(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log final_answer count 5 is above expected pressure turn count 4"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log completion final_answer has no required sentinel"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsNoisyPressureFeedbackAnswer() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-noisy-feedback-answer")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithNoisyFeedbackAnswer(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure event_log feedback is invalid: feedback answer must be a JSON object"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsUnquotedPressureFeedbackLeak() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-unquoted-feedback-leak")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithUnquotedFeedbackLeak(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "host-backed pressure event_log model reported leaked internal path was not quoted from observed output"
            ),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsUnquotedPressureSuspiciousOutput() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-unquoted-suspicious-output")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithUnquotedSuspiciousOutput(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "host-backed pressure event_log model reported suspicious output was not quoted from observed output"
            ),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsNegativePressureFeedbackWithoutEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-negative-feedback-without-evidence")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithNegativeFeedbackWithoutEvidence(
            rootURL: pressureMatrixRootURL(rootURL)
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains(
                "host-backed pressure event_log model negative Linux feedback did not include suspicious_outputs"
            ),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    private func finalGateVerifierURL() throws -> URL {
        try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("verify_final_exec_session_release_gate_report.py")
    }

    private func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "ModelShellProxyFinalGateVerifierEventLogConformanceTests",
            name: name
        )
    }

    private func removeTemporaryURL(_ url: URL) {
        ModelShellProxyConformanceSupport.removeTemporaryURL(url)
    }

    private func pressureMatrixRootURL(_ rootURL: URL) -> URL {
        rootURL.appendingPathComponent("real-model-pressure-matrix")
    }

    private func runFinalGateVerifier(verifierURL: URL, reportURL: URL) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            verifierURL.path,
            "--report",
            reportURL.path,
            "--required-model",
            ModelShellProxyPressureGateFixtureSupport.requiredModel,
            "--summary-report",
            reportURL.deletingLastPathComponent()
                .appendingPathComponent("final-exec-session-gate-report-verification.json")
                .path
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func appendRuntimeError(rootURL: URL, suite: String, message: String) throws {
        let eventURL = rootURL
            .appendingPathComponent(suite)
            .appendingPathComponent("events.jsonl")
        let event: [String: Any] = [
            "timestamp": ModelShellProxyPressureGateFixtureSupport.syntheticEventTimestamp,
            "event": "runtime_error",
            "fields": [
                "message": message
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let line = String(decoding: data, as: UTF8.self) + "\n"
        let handle = try FileHandle(forWritingTo: eventURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}
