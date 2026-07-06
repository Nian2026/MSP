import Foundation

struct FinalGatePressureMatrixFixtureURLs {
    let matrix: URL
    let suiteReports: [String: String]
}

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGatePressureMatrixFixture(
        rootURL: URL,
        matrixLooksLikeLinux: Bool,
        matrixModel: String,
        suiteModel: String,
        mainRequestModel: String,
        providerSmokeRequestModel: String,
        providerSmokeExpectedOutput: String?,
        providerSmokeActualOutput: String?,
        modelRequestCount: Int?,
        modelRequestExpectedCount: Int?
    ) throws -> FinalGatePressureMatrixFixtureURLs {
        let matrixRootURL = rootURL.appendingPathComponent("real-model-pressure-matrix")
        for suite in pressureSuites {
            try writePressureSuiteReport(
                suite,
                rootURL: matrixRootURL,
                passed: true,
                failures: [],
                providerSmokeExpectedOutput: providerSmokeExpectedOutput,
                providerSmokeActualOutput: providerSmokeActualOutput,
                model: suiteModel,
                mainRequestModel: mainRequestModel,
                providerSmokeRequestModel: providerSmokeRequestModel,
                modelRequestCount: modelRequestCount,
                modelRequestExpectedCount: modelRequestExpectedCount
            )
        }

        let matrixURL = matrixRootURL.appendingPathComponent("pressure-matrix-report.json")
        var matrixSuites: [String: Any] = [:]
        for suite in pressureSuites {
            let suiteURL = matrixRootURL
                .appendingPathComponent(suite)
                .appendingPathComponent("pressure-report.json")
            let suiteReport = try readJSONObject(suiteURL)
            var feedback = suiteReport["feedback"] as? [String: Any] ?? [:]
            feedback["looks_like_regular_linux"] = suite == "host-backed" ? matrixLooksLikeLinux : true
            feedback["can_distinguish_from_regular_linux"] = false
            feedback["suspicious_outputs"] = []
            feedback["leaked_internal_paths"] = []
            matrixSuites[suite] = [
                "name": suite,
                "report": suiteURL.path,
                "passed": suiteReport["passed"] ?? true,
                "failures": suiteReport["failures"] ?? [],
                "required_model": suiteReport["required_model"] ?? requiredModel,
                "model": suiteReport["model"] ?? requiredModel,
                "model_matches_required": suiteReport["model_matches_required"] ?? true,
                "model_failures": suiteReport["model_failures"] ?? [],
                "model_request_built": suiteReport["model_request_built"] ?? [:],
                "event_log": suiteReport["event_log"] ?? "events.jsonl",
                "required_final_sentinels": suiteReport["required_final_sentinels"] ?? [],
                "required_final_sentinel_answer_indices": suiteReport["required_final_sentinel_answer_indices"] ?? [:],
                "final_answer_count": suiteReport["final_answer_count"] ?? 0,
                "tool_started_count": suiteReport["tool_started_count"] ?? 0,
                "tool_completed_count": suiteReport["tool_completed_count"] ?? 0,
                "scanner_leaks": suiteReport["scanner_leaks"] ?? [],
                "prompt_contract": suiteReport["prompt_contract"] ?? [:],
                "prompt_delivery": suiteReport["prompt_delivery"] ?? [:],
                "provider_smoke": suiteReport["provider_smoke"] ?? [:],
                "feedback": feedback,
                "exec_session_contract": suiteReport["exec_session_contract"] ?? [:],
                "model_response_provenance": suiteReport["model_response_provenance"] ?? [:]
            ]
        }
        try writeJSONObject([
            "required_model": requiredModel,
            "model": matrixModel,
            "model_matches_required": matrixModel == requiredModel,
            "model_failures": matrixModel == requiredModel ? [] : [
                "pressure matrix model is not \(requiredModel): \(matrixModel)"
            ],
            "required_suites": pressureSuites,
            "all_required_suites_present": true,
            "missing_suites": [],
            "matrix_passed": true,
            "suite_count": pressureSuites.count,
            "suites": matrixSuites
        ], to: matrixURL)

        let suiteReportPaths = Dictionary(uniqueKeysWithValues: pressureSuites.map { suite in
            (
                suite,
                matrixRootURL
                    .appendingPathComponent(suite)
                    .appendingPathComponent("pressure-report.json")
                    .path
            )
        })
        return FinalGatePressureMatrixFixtureURLs(matrix: matrixURL, suiteReports: suiteReportPaths)
    }
}
