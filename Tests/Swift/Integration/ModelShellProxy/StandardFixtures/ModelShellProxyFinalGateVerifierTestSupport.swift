import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func finalGateVerifierURL() throws -> URL {
        try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("verify_final_exec_session_release_gate_report.py")
    }

    func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "ModelShellProxyFinalGateVerifierConformanceTests",
            name: name
        )
    }

    func removeTemporaryURL(_ url: URL) {
        ModelShellProxyConformanceSupport.removeTemporaryURL(url)
    }

    func runFinalGateVerifier(verifierURL: URL, reportURL: URL) throws -> ProcessResult {
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
