import Foundation
import XCTest

final class ModelShellProxyFinalGateVerifierPreflightConformanceTests: XCTestCase {
    func testFinalGateVerifierRejectsMissingPreflightReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-preflight-report")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try FileManager.default.removeItem(
            at: rootURL.appendingPathComponent("real-model-pressure-preflight-report.json")
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("evidence_artifacts.real_model_pressure_preflight_report does not exist"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsFailedPreflightReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-failed-preflight-report")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try """
        {
          "case_count": 1,
          "cases": [
            {
              "exit_code": 0,
              "expected_exit_code": 2,
              "failures": ["expected exit code 2, got 0"],
              "forbidden_stdout_absent": false,
              "label": "final_gate_wrong_model",
              "passed": false,
              "runner_kind": "final-gate",
              "stderr_matched": false
            }
          ],
          "failed_case_count": 1,
          "failures": ["final_gate_wrong_model: expected exit code 2, got 0"],
          "passed": false,
          "passed_case_count": 0,
          "required_model": "gpt-5.5",
          "runner_kinds": ["final-gate"]
        }
        """.write(
            to: rootURL.appendingPathComponent("real-model-pressure-preflight-report.json"),
            atomically: true,
            encoding: .utf8
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("real-model pressure preflight report did not pass"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("real-model pressure preflight failed_case_count is not 0"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMissingPreflightCaseLabelEvenWhenCountMatches() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-preflight-case-label")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let preflightURL = rootURL.appendingPathComponent("real-model-pressure-preflight-report.json")
        var report = try JSONSerialization.jsonObject(with: Data(contentsOf: preflightURL)) as? [String: Any] ?? [:]
        var cases = report["cases"] as? [[String: Any]] ?? []
        cases.removeAll { item in
            item["label"] as? String == "final_gate_wrong_model"
        }
        cases.append(cases[0])
        report["cases"] = cases
        report["case_labels"] = cases.compactMap { $0["label"] as? String }.sorted()
        try JSONSerialization
            .data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: preflightURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("real-model pressure preflight case_labels do not match required coverage"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("real-model pressure preflight cases do not include every required case label"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsPreflightCaseWithWrongRunnerContract() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-preflight-runner-contract")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let preflightURL = rootURL.appendingPathComponent("real-model-pressure-preflight-report.json")
        var report = try JSONSerialization.jsonObject(with: Data(contentsOf: preflightURL)) as? [String: Any] ?? [:]
        var cases = report["cases"] as? [[String: Any]] ?? []
        if let index = cases.firstIndex(where: { $0["label"] as? String == "playground_wrong_model" }) {
            cases[index]["runner_kind"] = "final-gate"
        }
        if let index = cases.firstIndex(where: { $0["label"] as? String == "photosorter_wrong_model" }) {
            cases[index]["runner"] = "Conformance/Scripts/run_final_exec_session_release_gate.sh"
        }
        report["cases"] = cases
        try JSONSerialization
            .data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: preflightURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("runner_kind does not match label contract"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("runner path does not match runner_kind contract"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsPreflightCaseWithWrongWeakeningContract() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-preflight-weakening-contract")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let preflightURL = rootURL.appendingPathComponent("real-model-pressure-preflight-report.json")
        var report = try JSONSerialization.jsonObject(with: Data(contentsOf: preflightURL)) as? [String: Any] ?? [:]
        var cases = report["cases"] as? [[String: Any]] ?? []
        if let index = cases.firstIndex(where: { $0["label"] as? String == "playground_wrong_model" }) {
            cases[index]["override_keys"] = ["MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE"]
        }
        if let index = cases.firstIndex(where: { $0["label"] as? String == "photosorter_provider_prompt" }) {
            cases[index]["expected_stderr"] = "synthetic preflight rejection"
        }
        if let index = cases.firstIndex(where: { $0["label"] as? String == "matrix_provider_nonce" }) {
            cases[index]["forbidden_stdout"] = ["synthetic forbidden startup marker"]
        }
        if let index = cases.firstIndex(where: { $0["label"] as? String == "playground_bad_prompt_contract" }) {
            cases[index]["forbidden_stderr"] = ["synthetic forbidden stderr marker"]
        }
        report["cases"] = cases
        try JSONSerialization
            .data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: preflightURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("override_keys do not match label contract"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("expected_stderr does not match label contract"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("forbidden_stdout does not match label contract"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("forbidden_stderr does not match label contract"),
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
            suiteName: "ModelShellProxyFinalGateVerifierPreflightConformanceTests",
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
