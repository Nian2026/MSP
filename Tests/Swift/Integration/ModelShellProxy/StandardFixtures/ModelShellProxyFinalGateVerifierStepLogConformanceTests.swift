import Foundation
import XCTest

final class ModelShellProxyFinalGateVerifierStepLogConformanceTests: XCTestCase {
    func testFinalGateVerifierRejectsMixedZeroAndPositiveSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' passed.
            \t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds
            Test Suite 'Selected tests' passed.
            \t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log executed 0 Swift tests"
        )
    }

    func testFinalGateVerifierRejectsZeroTestSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' passed.
            \t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log executed 0 Swift tests"
        )
    }

    func testFinalGateVerifierRejectsSkippedSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' passed.
            \t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log has 1 skipped Swift tests"
        )
    }

    func testFinalGateVerifierRejectsGenericSkippedMarkerInSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' passed.
            \t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds
            required oracle skipped by environment

            """,
            expectedFailure: "exec-command-bridge-tests log contains skipped gate marker"
        )
    }

    func testFinalGateVerifierRejectsFailedSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' failed.
            \t Executed 1 test, with 1 failure (1 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log has 1 Swift test failures"
        )
    }

    func testFinalGateVerifierRejectsUnexpectedSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' failed.
            \t Executed 1 test, with 0 failures (1 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log has 1 unexpected Swift test failures"
        )
    }

    func testFinalGateVerifierRejectsUnavailableSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            Test Suite 'Selected tests' passed.
            \t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds
            Required PTY oracle unavailable on this runner.

            """,
            expectedFailure: "exec-command-bridge-tests log contains unavailable gate marker"
        )
    }

    func testFinalGateVerifierRejectsSwiftStepLogWithoutScratchPath() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            command: swift test --filter MSPExecCommandBridgeTests

            Test Suite 'Selected tests' passed.
            \t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log command does not use final-gate scratch path"
        )
    }

    func testFinalGateVerifierRejectsSwiftStepLogWithSharedScratchPath() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "exec-command-bridge-tests",
            logText: """
            command: swift test --scratch-path /tmp/final-gate/shared-swiftpm-scratch --filter MSPExecCommandBridgeTests

            Test Suite 'Selected tests' passed.
            \t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds

            """,
            expectedFailure: "exec-command-bridge-tests log command scratch path is not step scoped"
        )
    }

    func testFinalGateVerifierRejectsUnavailableNonSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "readex-boundary-check",
            logText: """
            Readex boundary check passed
            required oracle unavailable

            """,
            expectedFailure: "readex-boundary-check log contains unavailable gate marker"
        )
    }

    func testFinalGateVerifierRejectsSkippedNonSwiftStepLog() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "readex-boundary-check",
            logText: """
            Readex boundary check passed
            required oracle skipped

            """,
            expectedFailure: "readex-boundary-check log contains skipped gate marker"
        )
    }

    func testFinalGateVerifierRejectsPreflightMarkerNotAtEnd() throws {
        try assertFinalGateVerifierRejectsStepLog(
            step: "real-model-pressure-preflight-hardening",
            logText: """
            real-model pressure preflight checks passed
            extra output after marker

            """,
            expectedFailure: "real-model-pressure-preflight-hardening log does not end with expected success marker"
        )
    }

    private func assertFinalGateVerifierRejectsStepLog(
        step: String,
        logText: String,
        expectedFailure: String,
        line: UInt = #line
    ) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-step-log-\(UUID().uuidString)")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try logText.write(
            to: rootURL.appendingPathComponent("\(step).log"),
            atomically: true,
            encoding: .utf8
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0, line: line)
        XCTAssertTrue(failed.stderr.contains(expectedFailure), failed.stderr, line: line)
    }

    private func finalGateVerifierURL() throws -> URL {
        try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("verify_final_exec_session_release_gate_report.py")
    }

    private func makeTemporaryURL(_ name: String) -> URL {
        ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "ModelShellProxyFinalGateVerifierStepLogConformanceTests",
            name: name
        )
    }

    private func removeTemporaryURL(_ url: URL) {
        ModelShellProxyConformanceSupport.removeTemporaryURL(url)
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
}
