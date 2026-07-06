import Foundation
import XCTest

extension ModelShellProxyPressureVerifierConformanceTests {
    func testRealModelPressureMatrixVerifierRejectsFixedProviderSmokeNonce() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-fixed-provider-nonce")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            providerSmokeExpectedOutput: "MSP_PROVIDER_OK_deadbeefcafebabe",
            providerSmokeActualOutput: "MSP_PROVIDER_OK_deadbeefcafebabe"
        )

        let fixedProviderNonce = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(fixedProviderNonce.exitCode, 0)
        XCTAssertTrue(
            fixedProviderNonce.stderr.contains("provider_smoke.expected_output uses a fixed placeholder nonce"),
            fixedProviderNonce.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRequiresProviderSmokeCheck() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-provider-smoke")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            providerSmokeChecked: false
        )

        let missingProviderSmoke = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingProviderSmoke.exitCode, 0)
        XCTAssertTrue(
            missingProviderSmoke.stderr.contains("provider_smoke.checked is not true"),
            missingProviderSmoke.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsProviderSmokeOutputMismatch() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-provider-output-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            providerSmokeActualOutput: "MSP_PROVIDER_OK_0000000000000000"
        )

        let mismatchedProviderSmoke = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(mismatchedProviderSmoke.exitCode, 0)
        XCTAssertTrue(
            mismatchedProviderSmoke.stderr.contains("provider_smoke actual output does not match expected output"),
            mismatchedProviderSmoke.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsWrongProviderSmokeModel() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-wrong-provider-model")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            providerSmokeRequestModel: "gpt-4.1"
        )

        let wrongProviderSmokeModel = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(wrongProviderSmokeModel.exitCode, 0)
        XCTAssertTrue(
            wrongProviderSmokeModel.stderr.contains("provider_smoke.request_model is not gpt-5.5"),
            wrongProviderSmokeModel.stderr
        )
        XCTAssertTrue(
            wrongProviderSmokeModel.stderr.contains("provider_smoke request artifact model is not gpt-5.5: gpt-4.1"),
            wrongProviderSmokeModel.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsProviderSmokeRequestNonceMismatch() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-provider-request-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwriteProviderSmokeRequest(
            rootURL: rootURL,
            expectedOutput: "MSP_PROVIDER_OK_1111111111111111"
        )

        let mismatchedProviderSmokeRequest = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(mismatchedProviderSmokeRequest.exitCode, 0)
        XCTAssertTrue(
            mismatchedProviderSmokeRequest.stderr.contains("provider_smoke.expected_output does not match request artifact nonce"),
            mismatchedProviderSmokeRequest.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsProviderSmokeResponseMismatch() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-provider-response-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwriteProviderSmokeResponse(
            rootURL: rootURL,
            outputText: "MSP_PROVIDER_OK_2222222222222222"
        )

        let mismatchedProviderSmokeResponse = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(mismatchedProviderSmokeResponse.exitCode, 0)
        XCTAssertTrue(
            mismatchedProviderSmokeResponse.stderr.contains("provider_smoke.actual_output does not match response artifact text"),
            mismatchedProviderSmokeResponse.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMissingProviderSmokeResponseArtifact() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-provider-artifact")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        let missingProviderSmokeArtifactURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("provider-smoke")
            .appendingPathComponent("provider-smoke-response.json")
        try FileManager.default.removeItem(at: missingProviderSmokeArtifactURL)

        let missingProviderSmokeArtifact = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingProviderSmokeArtifact.exitCode, 0)
        XCTAssertTrue(
            missingProviderSmokeArtifact.stderr.contains("provider_smoke.response artifact does not exist"),
            missingProviderSmokeArtifact.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsNonCanonicalProviderSmokeArtifacts() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-noncanonical-provider-artifacts")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let providerSmokeRootURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("provider-smoke")
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
        var forgedProviderSmokeReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(
            rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("pressure-report.json")
        )
        var forgedProviderSmoke = forgedProviderSmokeReport["provider_smoke"] as? [String: Any] ?? [:]
        forgedProviderSmoke["request"] = "provider-smoke/old-provider-smoke-request.redacted.json"
        forgedProviderSmoke["response"] = "provider-smoke/old-provider-smoke-response.json"
        forgedProviderSmokeReport["provider_smoke"] = forgedProviderSmoke
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(
            forgedProviderSmokeReport,
            to: rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("pressure-report.json")
        )

        let nonCanonicalProviderSmoke = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(nonCanonicalProviderSmoke.exitCode, 0)
        XCTAssertTrue(
            nonCanonicalProviderSmoke.stderr.contains("provider_smoke.request artifact does not match canonical suite path"),
            nonCanonicalProviderSmoke.stderr
        )
        XCTAssertTrue(
            nonCanonicalProviderSmoke.stderr.contains("provider_smoke.response artifact does not match canonical suite path"),
            nonCanonicalProviderSmoke.stderr
        )
    }
}
