import Foundation
import XCTest

final class ModelShellProxyFinalGateVerifierSwiftLogConformanceTests: XCTestCase {
    func testFinalGateVerifierRejectsFullSwiftLogExecutedCountMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-full-swift-log-count-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )

        let fullSwiftLogURL = rootURL
            .appendingPathComponent("full-swift-test-suite")
            .appendingPathComponent("full-swift-test-suite.log")
        try """
        Test Suite 'MSPApplyPatchToolTests' passed.
        Test Suite 'MSPPythonHostProcessSubprocessShellMatrixTests' passed.
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
        Test Suite 'ModelShellProxyCore100OracleConformanceTests' passed.
        Test Suite 'ModelShellProxyDebian12OracleConformanceTests' passed.
        Test Suite 'ModelShellProxyDebian12PTYOracleConformanceTests' passed.
        Test Suite 'ModelShellProxyFinalGateVerifierConformanceTests' passed.
        Test Suite 'ModelShellProxyReleaseGateAuxiliarySourceGuardTests' passed.
        Test Suite 'ModelShellProxyReleaseGateConformanceTests' passed.
        Test Suite 'ModelShellProxyReleaseGatePreflightConformanceTests' passed.
        Test Suite 'ModelShellProxyReleaseGateVerifierSourceGuardTests' passed.
        Test Suite 'Selected tests' passed.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: fullSwiftLogURL, atomically: true, encoding: .utf8)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("full Swift test suite log executed 0 Swift tests"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "full Swift test suite Swift log executed_test_count does not match report: 0 != 857"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsFullAgentBridgeLogExecutedCountMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-agentbridge-log-count-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )

        let agentBridgeLogURL = rootURL
            .appendingPathComponent("full-agentbridge-parity-matrix")
            .appendingPathComponent("full-agentbridge-parity-matrix-swift.log")
        try """
        Test Suite 'MSPApplyPatchToolTests' passed.
        Test Suite 'MSPExecCommandBridgeTests' passed.
        Test Suite 'MSPResponsesStreamingModelClientTests' passed.
        Test Suite 'MSPGoalCapabilityTests' passed.
        Test Suite 'MSPTurnSteerCapabilityTests' passed.
        Test Suite 'Selected tests' passed.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: agentBridgeLogURL, atomically: true, encoding: .utf8)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("full AgentBridge parity matrix log executed 0 Swift tests"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "full AgentBridge parity matrix Swift log executed_test_count does not match report: 0 != 207"
            ),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsExecSessionStressLogExecutedCountMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-exec-stress-log-count-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )

        let execStressLogURL = rootURL
            .appendingPathComponent("exec-session-stress")
            .appendingPathComponent("swift-test.log")
        try """
        Test Suite 'ModelShellProxyExecSessionStressTests' passed.
        Test Suite 'ModelShellProxyExecSessionPTYStressTests' passed.
        Test Suite 'Selected tests' passed.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: execStressLogURL, atomically: true, encoding: .utf8)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("exec-session stress log executed 0 Swift tests"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains(
                "exec-session stress Swift log executed_test_count does not match report: 0 != 15"
            ),
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
            suiteName: "ModelShellProxyFinalGateVerifierSwiftLogConformanceTests",
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
