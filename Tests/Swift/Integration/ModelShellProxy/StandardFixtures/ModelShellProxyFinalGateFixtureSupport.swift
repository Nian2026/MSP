import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateFixture(
        rootURL: URL,
        matrixLooksLikeLinux: Bool,
        matrixModel: String = requiredModel,
        finalGateModel: String = requiredModel,
        suiteModel: String = requiredModel,
        mainRequestModel: String = requiredModel,
        providerSmokeRequestModel: String = requiredModel,
        providerSmokeExpectedOutput: String? = nil,
        providerSmokeActualOutput: String? = nil,
        modelRequestCount: Int? = nil,
        modelRequestExpectedCount: Int? = nil
    ) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let stepLogs = try writeFinalGateStepLogs(rootURL: rootURL)
        let readexBoundaryURL = try writeFinalGateReadexBoundaryFixture(rootURL: rootURL)
        let execStressURL = try writeFinalGateExecStressFixture(rootURL: rootURL)
        let releaseDryRunURL = try writeFinalGateOpenSourceReleaseDryRunFixture(rootURL: rootURL)
        let dynamicCPythonURL = try writeFinalGateDynamicCPythonFixture(rootURL: rootURL)
        let focusedLedgerURL = try writeFinalGateFocusedLedgerFixture(rootURL: rootURL)
        let fullSwiftURL = try writeFinalGateFullSwiftTestSuiteFixture(rootURL: rootURL)
        let fullAgentBridgeURL = try writeFinalGateAgentBridgeParityMatrixFixture(rootURL: rootURL)

        let preflightURL = rootURL.appendingPathComponent("real-model-pressure-preflight-report.json")
        try writePreflightFixtureReport(to: preflightURL)

        let oracleURLs = try writeFinalGateOracleFixtures(rootURL: rootURL)
        let matrixURLs = try writeFinalGatePressureMatrixFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: matrixLooksLikeLinux,
            matrixModel: matrixModel,
            suiteModel: suiteModel,
            mainRequestModel: mainRequestModel,
            providerSmokeRequestModel: providerSmokeRequestModel,
            providerSmokeExpectedOutput: providerSmokeExpectedOutput,
            providerSmokeActualOutput: providerSmokeActualOutput,
            modelRequestCount: modelRequestCount,
            modelRequestExpectedCount: modelRequestExpectedCount
        )

        try writeJSONObject([
            "passed": true,
            "gate": "msp-final-exec-session-release-gate",
            "completion_scope": "exec-session-release-gate",
            "not_final_msp_open_source_release_gate": true,
            "missing_final_gate_classes": [
                "remote-backed-workspace-conformance",
                "lazy-materialized-workspace-conformance",
                "full-ui-preview-thumbnail-cache-e2e-conformance",
                "readex-migration-compatibility-conformance"
            ],
            "required_model": requiredModel,
            "model": finalGateModel,
            "model_matches_required": finalGateModel == requiredModel,
            "model_failures": finalGateModel == requiredModel ? [] : [
                "final gate model is not \(requiredModel): \(finalGateModel)"
            ],
            "repository_root": rootURL.path,
            "out_dir": rootURL.path,
            "steps": finalGateFixtureSteps,
            "step_logs": stepLogs,
            "required_pressure_suites": pressureSuites,
            "linux_character_oracle_alignment": finalGateLinuxCharacterOracleAlignmentFixture,
            "evidence_artifacts": [
                "real_model_pressure_preflight_report": preflightURL.path,
                "readex_boundary_report": readexBoundaryURL.path,
                "exec_session_stress_report": execStressURL.path,
                "open_source_release_dry_run_report": releaseDryRunURL.path,
                "dynamic_embedded_cpython_swift_tests_report": dynamicCPythonURL.path,
                "focused_test_suites_ledger_report": focusedLedgerURL.path,
                "full_swift_test_suite_report": fullSwiftURL.path,
                "full_agentbridge_parity_matrix_report": fullAgentBridgeURL.path,
                "core100_noninteractive_oracle_report": oracleURLs.core100.path,
                "debian12_noninteractive_oracle_report": oracleURLs.noninteractive.path,
                "live_noninteractive_linux_vps_oracle_report": oracleURLs.liveNoninteractive.path,
                "debian12_linux_pty_oracle_report": oracleURLs.pty.path,
                "real_model_pressure_matrix_report": matrixURLs.matrix.path,
                "real_model_pressure_suite_reports": matrixURLs.suiteReports
            ]
        ], to: rootURL.appendingPathComponent("final-exec-session-gate-report.json"))
    }
}
