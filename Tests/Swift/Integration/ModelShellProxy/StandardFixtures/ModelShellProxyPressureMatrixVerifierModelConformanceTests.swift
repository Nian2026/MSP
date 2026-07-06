import XCTest

extension ModelShellProxyPressureVerifierConformanceTests {
    func testRealModelPressureMatrixVerifierRejectsWrongMatrixModel() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-wrong-matrix-model")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let wrongModel = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL, model: "gpt-4.1")

        XCTAssertNotEqual(wrongModel.exitCode, 0)
        XCTAssertTrue(
            wrongModel.stderr.contains("pressure matrix model is not gpt-5.5: gpt-4.1"),
            wrongModel.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsWrongMainRequestModel() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-wrong-main-request-model")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            mainRequestModel: "gpt-4.1"
        )

        let wrongMainRequestModel = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(wrongMainRequestModel.exitCode, 0)
        XCTAssertTrue(
            wrongMainRequestModel.stderr.contains("host-backed: model_request_built.models is not exactly [gpt-5.5]"),
            wrongMainRequestModel.stderr
        )
        XCTAssertTrue(
            wrongMainRequestModel.stderr.contains("host-backed: model_request_built.all_match_required is not true"),
            wrongMainRequestModel.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsUndercountedMainRequests() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-undercounted-main-requests")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            modelRequestCount: 1,
            reportedPassed: true
        )

        let undercountedMainRequests = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(undercountedMainRequests.exitCode, 0)
        XCTAssertTrue(
            undercountedMainRequests.stderr.contains(
                "host-backed: model_request_built.count is below expected_count: 1 < 4"
            ),
            undercountedMainRequests.stderr
        )
        XCTAssertTrue(
            undercountedMainRequests.stderr.contains("host-backed: model_request_built.all_match_required is not true"),
            undercountedMainRequests.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsForgedExpectedRequestCount() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-forged-request-count")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            modelRequestCount: 4,
            modelRequestExpectedCount: 1,
            reportedPassed: true
        )

        let forgedExpectedCount = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(forgedExpectedCount.exitCode, 0)
        XCTAssertTrue(
            forgedExpectedCount.stderr.contains(
                "host-backed: model_request_built.expected_count does not match required pressure turn count: 1 != 4"
            ),
            forgedExpectedCount.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsWrongSuiteModel() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-wrong-suite-model")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try writePressureSuiteReport(
            "host-backed",
            rootURL: rootURL,
            passed: true,
            failures: [],
            model: "gpt-4.1",
            reportedModelFailures: [],
            reportedPassed: true
        )

        let wrongSuiteModel = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(wrongSuiteModel.exitCode, 0)
        XCTAssertTrue(
            wrongSuiteModel.stderr.contains("host-backed: suite report model is not gpt-5.5"),
            wrongSuiteModel.stderr
        )
        XCTAssertTrue(
            wrongSuiteModel.stderr.contains("host-backed: suite report model_matches_required is not true"),
            wrongSuiteModel.stderr
        )
    }
}
