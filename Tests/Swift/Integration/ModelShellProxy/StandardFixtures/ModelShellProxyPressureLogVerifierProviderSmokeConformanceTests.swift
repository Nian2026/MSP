import Foundation
import XCTest

final class ModelShellProxyPressureLogVerifierProviderSmokeConformanceTests: ModelShellProxyPressureLogVerifierTestCase {
    func testRealModelPressureVerifierRecordsProviderSmokeEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-provider-smoke")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: cleanLog)
        let providerSmoke = try writeProviderSmokeEvidence(rootURL.appendingPathComponent("provider-smoke"))

        let providerChecked = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: [
                "--require-provider-smoke",
                "--provider-smoke-request", providerSmoke.request.path,
                "--provider-smoke-response", providerSmoke.response.path
            ]
        )

        XCTAssertEqual(providerChecked.exitCode, 0, providerChecked.stderr)
        let providerCheckedReport = try String(
            contentsOf: cleanLog.deletingPathExtension().appendingPathExtension("report.json"),
            encoding: .utf8
        )
        XCTAssertTrue(providerCheckedReport.contains(#""provider_smoke""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""checked": true"#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""request_model": "gpt-5.5""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""request_model_matches_required": true"#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""expected_output": "MSP_PROVIDER_OK_1234567890abcdef""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""actual_output": "MSP_PROVIDER_OK_1234567890abcdef""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""request_artifact_model": "gpt-5.5""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""request_artifact_expected_output": "MSP_PROVIDER_OK_1234567890abcdef""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""response_artifact_id": "resp_"#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""response_artifact_object": "response""#), providerCheckedReport)
        XCTAssertTrue(providerCheckedReport.contains(#""response_artifact_actual_output": "MSP_PROVIDER_OK_1234567890abcdef""#), providerCheckedReport)
    }

    func testRealModelPressureVerifierRejectsProviderSmokeWrongModelAndFixedNonce() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-provider-smoke-model-nonce")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: cleanLog)

        let wrongModelProviderSmoke = try writeProviderSmokeEvidence(
            rootURL.appendingPathComponent("provider-smoke-wrong-model"),
            requestModel: "gpt-4.1"
        )
        let wrongModelProviderChecked = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: [
                "--require-provider-smoke",
                "--provider-smoke-request", wrongModelProviderSmoke.request.path,
                "--provider-smoke-response", wrongModelProviderSmoke.response.path
            ]
        )
        XCTAssertNotEqual(wrongModelProviderChecked.exitCode, 0)
        XCTAssertTrue(
            wrongModelProviderChecked.stderr.contains("provider smoke request model is not gpt-5.5: gpt-4.1"),
            wrongModelProviderChecked.stderr
        )

        let fixedNonceProviderSmoke = try writeProviderSmokeEvidence(
            rootURL.appendingPathComponent("provider-smoke-fixed-nonce"),
            expectedOutput: "MSP_PROVIDER_OK_deadbeefcafebabe",
            actualOutput: "MSP_PROVIDER_OK_deadbeefcafebabe"
        )
        let fixedNonceProviderChecked = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: [
                "--require-provider-smoke",
                "--provider-smoke-request", fixedNonceProviderSmoke.request.path,
                "--provider-smoke-response", fixedNonceProviderSmoke.response.path
            ]
        )
        XCTAssertNotEqual(fixedNonceProviderChecked.exitCode, 0)
        XCTAssertTrue(
            fixedNonceProviderChecked.stderr.contains("provider smoke request uses a fixed placeholder nonce"),
            fixedNonceProviderChecked.stderr
        )
    }

    func testRealModelPressureVerifierRejectsProviderSmokeMismatchShapeAndMissingEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-provider-smoke-mismatch")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: cleanLog)

        let mismatchedProviderSmoke = try writeProviderSmokeEvidence(
            rootURL.appendingPathComponent("provider-smoke-mismatch"),
            actualOutput: "MSP_PROVIDER_OK_0000000000000000"
        )
        let mismatchedProviderChecked = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: [
                "--require-provider-smoke",
                "--provider-smoke-request", mismatchedProviderSmoke.request.path,
                "--provider-smoke-response", mismatchedProviderSmoke.response.path
            ]
        )
        XCTAssertNotEqual(mismatchedProviderChecked.exitCode, 0)
        XCTAssertTrue(
            mismatchedProviderChecked.stderr.contains("provider smoke response text did not match the dynamic expected output"),
            mismatchedProviderChecked.stderr
        )

        let responseShapeProviderSmoke = try writeProviderSmokeEvidence(
            rootURL.appendingPathComponent("provider-smoke-response-shape")
        )
        try writeJSONObject([
            "output_text": "MSP_PROVIDER_OK_1234567890abcdef"
        ], to: responseShapeProviderSmoke.response)
        let invalidResponseShapeProviderChecked = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: [
                "--require-provider-smoke",
                "--provider-smoke-request", responseShapeProviderSmoke.request.path,
                "--provider-smoke-response", responseShapeProviderSmoke.response.path
            ]
        )
        XCTAssertNotEqual(invalidResponseShapeProviderChecked.exitCode, 0)
        XCTAssertTrue(
            invalidResponseShapeProviderChecked.stderr.contains("provider smoke response artifact id is missing or not a string"),
            invalidResponseShapeProviderChecked.stderr
        )
        XCTAssertTrue(
            invalidResponseShapeProviderChecked.stderr.contains("provider smoke response artifact object is not response"),
            invalidResponseShapeProviderChecked.stderr
        )

        let missingProviderSmoke = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: ["--require-provider-smoke"]
        )
        XCTAssertNotEqual(missingProviderSmoke.exitCode, 0)
        XCTAssertTrue(
            missingProviderSmoke.stderr.contains("provider smoke evidence is missing"),
            missingProviderSmoke.stderr
        )
    }
}
