import Foundation
import XCTest

final class ModelShellProxyFinalGateVerifierProviderSmokeConformanceTests: XCTestCase {
    func testFinalGateVerifierRejectsFixedProviderSmokeNonce() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-fixed-provider-nonce")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            providerSmokeExpectedOutput: "MSP_PROVIDER_OK_deadbeefcafebabe",
            providerSmokeActualOutput: "MSP_PROVIDER_OK_deadbeefcafebabe"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.expected_output uses a fixed placeholder nonce"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsProviderSmokeRequestWithWrongModel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-wrong-provider-smoke-model")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true,
            providerSmokeRequestModel: "gpt-4.1"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.request_model is not gpt-5.5"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke request artifact model is not gpt-5.5: gpt-4.1"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsProviderSmokeRequestNonceMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-provider-smoke-request-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixRootURL = rootURL.appendingPathComponent("real-model-pressure-matrix")
        try ModelShellProxyPressureGateFixtureSupport.overwriteProviderSmokeRequest(
            rootURL: matrixRootURL,
            expectedOutput: "MSP_PROVIDER_OK_1111111111111111"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.expected_output does not match request artifact nonce"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsProviderSmokeResponseArtifactMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-provider-smoke-response-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let matrixRootURL = rootURL.appendingPathComponent("real-model-pressure-matrix")
        try ModelShellProxyPressureGateFixtureSupport.overwriteProviderSmokeResponse(
            rootURL: matrixRootURL,
            outputText: "MSP_PROVIDER_OK_2222222222222222"
        )

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.actual_output does not match response artifact text"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsProviderSmokeResponseWithoutResponsesIdentity() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-provider-smoke-response-shape")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let responseURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
            .appendingPathComponent("provider-smoke")
            .appendingPathComponent("provider-smoke-response.json")
        var response = try JSONSerialization
            .jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any] ?? [:]
        response.removeValue(forKey: "id")
        response.removeValue(forKey: "object")
        try JSONSerialization
            .data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            .write(to: responseURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke response artifact id is missing or not a string"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke response artifact object is not response"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsProviderSmokeReportMissingArtifactDerivedFields() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-provider-smoke-missing-derived-fields")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let reportURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        var report = try JSONSerialization
            .jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any] ?? [:]
        var providerSmoke = report["provider_smoke"] as? [String: Any] ?? [:]
        for key in [
            "request_artifact_model",
            "request_artifact_expected_output",
            "response_artifact_id",
            "response_artifact_object",
            "response_artifact_actual_output"
        ] {
            providerSmoke.removeValue(forKey: key)
        }
        report["provider_smoke"] = providerSmoke
        try JSONSerialization
            .data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.request_artifact_model does not match request artifact model"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.response_artifact_id does not match response artifact id"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.response_artifact_actual_output does not match response artifact text"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("pressure matrix host-backed passed does not match suite report evidence"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsProviderSmokeArtifactsOutsideSuiteDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-provider-smoke-outside-suite")
        let outsideURL = makeTemporaryURL("final-gate-verifier-provider-smoke-outside-suite-source")
        defer {
            removeTemporaryURL(rootURL)
            removeTemporaryURL(outsideURL)
        }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let suiteRootURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
        let providerSmokeRootURL = suiteRootURL.appendingPathComponent("provider-smoke")
        let outsideRequestURL = outsideURL.appendingPathComponent("provider-smoke-request.redacted.json")
        let outsideResponseURL = outsideURL.appendingPathComponent("provider-smoke-response.json")
        try FileManager.default.copyItem(
            at: providerSmokeRootURL.appendingPathComponent("provider-smoke-request.redacted.json"),
            to: outsideRequestURL
        )
        try FileManager.default.copyItem(
            at: providerSmokeRootURL.appendingPathComponent("provider-smoke-response.json"),
            to: outsideResponseURL
        )

        let reportURL = suiteRootURL.appendingPathComponent("pressure-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        var providerSmoke = report["provider_smoke"] as? [String: Any] ?? [:]
        providerSmoke["request"] = outsideRequestURL.path
        providerSmoke["response"] = outsideResponseURL.path
        report["provider_smoke"] = providerSmoke
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.request artifact is outside suite report directory"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.response artifact is outside suite report directory"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsNonCanonicalProviderSmokeArtifactsInsideSuiteDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-provider-smoke-non-canonical")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let suiteRootURL = rootURL
            .appendingPathComponent("real-model-pressure-matrix")
            .appendingPathComponent("host-backed")
        let providerSmokeRootURL = suiteRootURL.appendingPathComponent("provider-smoke")
        let forgedRequestURL = providerSmokeRootURL.appendingPathComponent("old-provider-smoke-request.redacted.json")
        let forgedResponseURL = providerSmokeRootURL.appendingPathComponent("old-provider-smoke-response.json")
        try FileManager.default.copyItem(
            at: providerSmokeRootURL.appendingPathComponent("provider-smoke-request.redacted.json"),
            to: forgedRequestURL
        )
        try FileManager.default.copyItem(
            at: providerSmokeRootURL.appendingPathComponent("provider-smoke-response.json"),
            to: forgedResponseURL
        )

        let reportURL = suiteRootURL.appendingPathComponent("pressure-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        var providerSmoke = report["provider_smoke"] as? [String: Any] ?? [:]
        providerSmoke["request"] = "provider-smoke/old-provider-smoke-request.redacted.json"
        providerSmoke["response"] = "provider-smoke/old-provider-smoke-response.json"
        report["provider_smoke"] = providerSmoke
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: reportURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.request artifact does not match canonical suite path"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("host-backed pressure provider_smoke.response artifact does not match canonical suite path"),
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
            suiteName: "ModelShellProxyFinalGateVerifierProviderSmokeConformanceTests",
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
