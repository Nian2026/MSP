import Foundation
import XCTest

final class ModelShellProxyFinalGateVerifierMatrixConformanceTests: XCTestCase {
    func testFinalGateVerifierRejectsForgedMatrixEvidenceFields() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-matrix-evidence-fields")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("pressure-matrix-report.json")
        var matrix = try JSONSerialization
            .jsonObject(with: Data(contentsOf: matrixURL)) as? [String: Any] ?? [:]
        var suites = matrix["suites"] as? [String: Any] ?? [:]
        var host = suites["host-backed"] as? [String: Any] ?? [:]
        host["final_answer_count"] = 999
        host["tool_started_count"] = 999
        host["required_final_sentinel_answer_indices"] = [
            "PRESSURE_TASK_DONE": [99]
        ]
        var modelRequestBuilt = host["model_request_built"] as? [String: Any] ?? [:]
        var requestLayers = modelRequestBuilt["request_layers"] as? [String] ?? []
        requestLayers.append("runtime_provider")
        modelRequestBuilt["request_layers"] = requestLayers
        host["model_request_built"] = modelRequestBuilt
        var feedback = host["feedback"] as? [String: Any] ?? [:]
        feedback["notes"] = "forged matrix feedback notes"
        host["feedback"] = feedback
        var promptContract = host["prompt_contract"] as? [String: Any] ?? [:]
        promptContract["sha256"] = String(repeating: "f", count: 64)
        host["prompt_contract"] = promptContract
        var promptDelivery = host["prompt_delivery"] as? [String: Any] ?? [:]
        promptDelivery["prompt_sha256s"] = [String(repeating: "f", count: 64)]
        host["prompt_delivery"] = promptDelivery
        var responseProvenance = host["model_response_provenance"] as? [String: Any] ?? [:]
        responseProvenance["final_answer_response_ids"] = ["resp_forged_matrix"]
        responseProvenance["final_answer_model_request_refs"] = ["run_forged_matrix:1"]
        host["model_response_provenance"] = responseProvenance
        suites["host-backed"] = host
        var execSession = suites["exec-session"] as? [String: Any] ?? [:]
        var contract = execSession["exec_session_contract"] as? [String: Any] ?? [:]
        contract["pty_exec_count"] = 999
        execSession["exec_session_contract"] = contract
        suites["exec-session"] = execSession
        matrix["suites"] = suites
        try JSONSerialization
            .data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys])
            .write(to: matrixURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed final_answer_count does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed tool_started_count does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed required_final_sentinel_answer_indices does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed model_request_built.request_layers does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed feedback.notes does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed prompt_contract.sha256 does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed prompt_delivery.prompt_sha256s does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed model_response_provenance.final_answer_response_ids does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed model_response_provenance.final_answer_model_request_refs does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix exec-session exec_session_contract does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMissingMatrixEvidenceFields() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-matrix-evidence-fields")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("pressure-matrix-report.json")
        var matrix = try JSONSerialization
            .jsonObject(with: Data(contentsOf: matrixURL)) as? [String: Any] ?? [:]
        var suites = matrix["suites"] as? [String: Any] ?? [:]
        var host = suites["host-backed"] as? [String: Any] ?? [:]
        host.removeValue(forKey: "final_answer_count")
        host.removeValue(forKey: "tool_started_count")
        host.removeValue(forKey: "required_final_sentinel_answer_indices")
        host.removeValue(forKey: "prompt_contract")
        host.removeValue(forKey: "prompt_delivery")
        host.removeValue(forKey: "model_response_provenance")
        suites["host-backed"] = host
        var execSession = suites["exec-session"] as? [String: Any] ?? [:]
        execSession.removeValue(forKey: "exec_session_contract")
        suites["exec-session"] = execSession
        matrix["suites"] = suites
        try JSONSerialization
            .data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys])
            .write(to: matrixURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed final_answer_count does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed tool_started_count does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed required_final_sentinel_answer_indices does not match suite report evidence"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed prompt_contract is missing or not an object"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed prompt_delivery is missing or not an object"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed model_response_provenance is missing or not an object"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix exec-session exec_session_contract does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsExtraMatrixSuiteKeys() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-extra-matrix-suite-keys")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("pressure-matrix-report.json")
        var matrix = try JSONSerialization
            .jsonObject(with: Data(contentsOf: matrixURL)) as? [String: Any] ?? [:]
        var suites = matrix["suites"] as? [String: Any] ?? [:]
        suites["stale-suite"] = [
            "name": "stale-suite",
            "report": rootURL
                .appendingPathComponent("real-model-pressure-matrix")
                .appendingPathComponent("stale-suite")
                .appendingPathComponent("pressure-report.json")
                .path,
            "passed": true,
            "failures": []
        ]
        matrix["suites"] = suites
        try JSONSerialization
            .data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys])
            .write(to: matrixURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix suites keys do not match required pressure suites"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsInconsistentMatrixSelfDescription() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-inconsistent-matrix-self-description")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("pressure-matrix-report.json")
        var matrix = try JSONSerialization
            .jsonObject(with: Data(contentsOf: matrixURL)) as? [String: Any] ?? [:]
        matrix["missing_suites"] = ["host-backed"]
        var suites = matrix["suites"] as? [String: Any] ?? [:]
        var host = suites["host-backed"] as? [String: Any] ?? [:]
        host["name"] = "stale-host-backed"
        suites["host-backed"] = host
        matrix["suites"] = suites
        try JSONSerialization
            .data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys])
            .write(to: matrixURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix missing_suites is not empty: host-backed"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed name does not match suite id"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsMissingMatrixProviderSmokeDerivedFields() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-matrix-provider-smoke-derived-fields")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("pressure-matrix-report.json")
        var matrix = try JSONSerialization
            .jsonObject(with: Data(contentsOf: matrixURL)) as? [String: Any] ?? [:]
        var suites = matrix["suites"] as? [String: Any] ?? [:]
        var host = suites["host-backed"] as? [String: Any] ?? [:]
        var providerSmoke = host["provider_smoke"] as? [String: Any] ?? [:]
        for key in [
            "request_artifact_model",
            "request_artifact_expected_output",
            "response_artifact_id",
            "response_artifact_object",
            "response_artifact_actual_output"
        ] {
            providerSmoke.removeValue(forKey: key)
        }
        host["provider_smoke"] = providerSmoke
        suites["host-backed"] = host
        matrix["suites"] = suites
        try JSONSerialization
            .data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys])
            .write(to: matrixURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed provider_smoke.request_artifact_model is not gpt-5.5"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed provider_smoke.response_artifact_id does not match suite report evidence"),
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
            suiteName: "ModelShellProxyFinalGateVerifierMatrixConformanceTests",
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
