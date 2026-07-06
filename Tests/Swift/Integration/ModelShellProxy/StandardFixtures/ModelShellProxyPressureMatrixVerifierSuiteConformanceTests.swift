import Foundation
import XCTest

extension ModelShellProxyPressureVerifierConformanceTests {
    func testRealModelPressureMatrixVerifierHonorsSuiteReportedFailures() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier")
        defer { removeTemporaryURL(rootURL) }

        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let clean = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)
        XCTAssertEqual(clean.exitCode, 0, clean.stderr)

        try writePressureSuiteReport(
            "mixed-backend",
            rootURL: rootURL,
            passed: false,
            failures: ["synthetic owner-layer failure"]
        )
        let failed = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("suite report passed flag is not true"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("synthetic owner-layer failure"),
            failed.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsDuplicateSuiteArgument() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-duplicate-suite")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let canonicalHostSuiteReportURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        let duplicateSuiteArgument = try runMatrixVerifier(
            verifierURL: verifierURL,
            rootURL: rootURL,
            suiteOverrides: ["host-backed": canonicalHostSuiteReportURL],
            extraSuiteArguments: [("host-backed", canonicalHostSuiteReportURL)]
        )

        XCTAssertNotEqual(duplicateSuiteArgument.exitCode, 0)
        XCTAssertTrue(
            duplicateSuiteArgument.stderr.contains("duplicate pressure suite(s): host-backed"),
            duplicateSuiteArgument.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsNonCanonicalSuiteReportPath() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-noncanonical-suite")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let forgedSuiteReportURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("forged-pressure-report.json")
        try FileManager.default.copyItem(
            at: rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("pressure-report.json"),
            to: forgedSuiteReportURL
        )

        let nonCanonicalSuiteReport = try runMatrixVerifier(
            verifierURL: verifierURL,
            rootURL: rootURL,
            suiteOverrides: ["host-backed": forgedSuiteReportURL]
        )

        XCTAssertNotEqual(nonCanonicalSuiteReport.exitCode, 0)
        XCTAssertTrue(
            nonCanonicalSuiteReport.stderr.contains(
                "suite path does not match canonical matrix root path: host-backed"
            ),
            nonCanonicalSuiteReport.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMissingSuiteStatusFields() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-suite-status")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.removeFields(
            ["passed", "failures"],
            fromSuiteReport: "host-backed",
            rootURL: rootURL
        )

        let missingSuiteStatus = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingSuiteStatus.exitCode, 0)
        XCTAssertTrue(
            missingSuiteStatus.stderr.contains("host-backed: suite report passed flag is not true"),
            missingSuiteStatus.stderr
        )
        XCTAssertTrue(
            missingSuiteStatus.stderr.contains("host-backed: suite report failures is not a string array"),
            missingSuiteStatus.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMissingModelRequestLayerEvidence() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-request-layers")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let hostReportURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        var hostReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(hostReportURL)
        var modelRequestBuilt = hostReport["model_request_built"] as? [String: Any] ?? [:]
        modelRequestBuilt.removeValue(forKey: "request_layers")
        hostReport["model_request_built"] = modelRequestBuilt
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(hostReport, to: hostReportURL)

        let missingRequestLayers = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingRequestLayers.exitCode, 0)
        XCTAssertTrue(
            missingRequestLayers.stderr.contains("host-backed: model_request_built.request_layers does not cover required pressure turn count"),
            missingRequestLayers.stderr
        )
        XCTAssertTrue(
            missingRequestLayers.stderr.contains("host-backed: model_request_built does not match event_log evidence"),
            missingRequestLayers.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMissingPromptContractEvidence() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-prompt-contract")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.removeFields(
            ["prompt_contract"],
            fromSuiteReport: "host-backed",
            rootURL: rootURL
        )

        let missingPromptContract = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingPromptContract.exitCode, 0)
        XCTAssertTrue(
            missingPromptContract.stderr.contains("host-backed: pressure matrix host-backed prompt_contract is missing or not an object"),
            missingPromptContract.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsForgedPromptContractEvidence() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-forged-prompt-contract")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let hostReportURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        var hostReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(hostReportURL)
        var promptContract = hostReport["prompt_contract"] as? [String: Any] ?? [:]
        promptContract["path"] = "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/old-prompts.json"
        promptContract["sha256"] = String(repeating: "0", count: 64)
        hostReport["prompt_contract"] = promptContract
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(hostReport, to: hostReportURL)

        let forgedPromptContract = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(forgedPromptContract.exitCode, 0)
        XCTAssertTrue(
            forgedPromptContract.stderr.contains("host-backed: pressure matrix host-backed prompt_contract.path does not match canonical prompt file"),
            forgedPromptContract.stderr
        )
        XCTAssertTrue(
            forgedPromptContract.stderr.contains("host-backed: pressure matrix host-backed prompt_contract.sha256 does not match canonical prompt file"),
            forgedPromptContract.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMissingPromptDeliveryEvidence() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-prompt-delivery")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.removeFields(
            ["prompt_delivery"],
            fromSuiteReport: "host-backed",
            rootURL: rootURL
        )

        let missingPromptDelivery = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingPromptDelivery.exitCode, 0)
        XCTAssertTrue(
            missingPromptDelivery.stderr.contains("host-backed: pressure matrix host-backed prompt_delivery is missing or not an object"),
            missingPromptDelivery.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsForgedPromptDeliveryEvidence() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-forged-prompt-delivery")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let hostReportURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        var hostReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(hostReportURL)
        var promptDelivery = hostReport["prompt_delivery"] as? [String: Any] ?? [:]
        promptDelivery["path"] = "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/old-prompts.json"
        promptDelivery["prompt_sha256s"] = [String(repeating: "0", count: 64)]
        promptDelivery["model_request_last_user_input_sha256s"] = [String(repeating: "0", count: 64)]
        let originalFinalAnswerHashes = promptDelivery["final_answer_request_last_user_input_sha256s"] as? [String] ?? []
        promptDelivery["final_answer_request_last_user_input_sha256s"] = Array(
            repeating: String(repeating: "0", count: 64),
            count: originalFinalAnswerHashes.count
        )
        hostReport["prompt_delivery"] = promptDelivery
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(hostReport, to: hostReportURL)

        let forgedPromptDelivery = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(forgedPromptDelivery.exitCode, 0)
        XCTAssertTrue(
            forgedPromptDelivery.stderr.contains("host-backed: pressure matrix host-backed prompt_delivery.path does not match canonical prompt file"),
            forgedPromptDelivery.stderr
        )
        XCTAssertTrue(
            forgedPromptDelivery.stderr.contains("host-backed: pressure matrix host-backed prompt_delivery.prompt_sha256s does not match canonical prompt file"),
            forgedPromptDelivery.stderr
        )
        XCTAssertTrue(
            forgedPromptDelivery.stderr.contains("host-backed: pressure matrix host-backed prompt_delivery.model_request_last_user_input_sha256s do not match canonical prompt order"),
            forgedPromptDelivery.stderr
        )
        XCTAssertTrue(
            forgedPromptDelivery.stderr.contains("host-backed: pressure matrix host-backed prompt_delivery.final_answer_request_last_user_input_sha256s do not match canonical prompt order"),
            forgedPromptDelivery.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsForgedModelResponseProvenanceTextHashes() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-forged-model-response-text-hashes")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let hostReportURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("pressure-report.json")
        var hostReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(hostReportURL)
        var provenance = hostReport["model_response_provenance"] as? [String: Any] ?? [:]
        let originalHashes = provenance["final_answer_text_sha256s"] as? [String] ?? []
        provenance["final_answer_text_sha256s"] = Array(
            repeating: String(repeating: "0", count: 64),
            count: originalHashes.count
        )
        hostReport["model_response_provenance"] = provenance
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(hostReport, to: hostReportURL)

        let forgedProvenance = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(forgedProvenance.exitCode, 0)
        XCTAssertTrue(
            forgedProvenance.stderr.contains("host-backed: model_response_provenance.final_answer_text_sha256s does not match event_log evidence"),
            forgedProvenance.stderr
        )
    }
}
