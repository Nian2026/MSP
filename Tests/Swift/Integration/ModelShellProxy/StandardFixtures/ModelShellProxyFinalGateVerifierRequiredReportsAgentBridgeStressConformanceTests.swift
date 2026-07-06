import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsSkippedFullAgentBridgeParityMatrixReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-skipped-agentbridge-matrix")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let agentBridgeURL = rootURL
            .appendingPathComponent("full-agentbridge-parity-matrix")
            .appendingPathComponent("full-agentbridge-parity-matrix-report.json")
        var agentBridge = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(agentBridgeURL)
        agentBridge["passed"] = true
        agentBridge["skipped_test_count"] = 1
        agentBridge["failures"] = []
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(agentBridge, to: agentBridgeURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("full AgentBridge parity matrix skipped_test_count is not 0"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsForgedFullAgentBridgeParityMatrixDiscoveryMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-agentbridge-discovery")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let agentBridgeURL = rootURL
            .appendingPathComponent("full-agentbridge-parity-matrix")
            .appendingPathComponent("full-agentbridge-parity-matrix-report.json")
        var agentBridge = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(agentBridgeURL)
        agentBridge["passed"] = true
        agentBridge["swift_filter"] = "MSPGoalCapabilityTests"
        let scratchRoot = agentBridge["scratch_root"] as? String ?? rootURL
            .appendingPathComponent("full-agentbridge-parity-matrix")
            .appendingPathComponent("scratch")
            .path
        agentBridge["command"] = [
            "swift",
            "test",
            "--scratch-path",
            scratchRoot,
            "--filter",
            "MSPGoalCapabilityTests"
        ]
        agentBridge["test_class_count"] = 1
        agentBridge["test_classes"] = [
            [
                "name": "MSPGoalCapabilityTests",
                "declared_test_count": 207,
                "source_files": ["Tests/Swift/Unit/MSPAgentBridge/MSPGoalCapabilityTests.swift"]
            ]
        ]
        agentBridge["failures"] = []
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(agentBridge, to: agentBridgeURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("full AgentBridge parity matrix swift_filter does not match discovery test_filter"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("full AgentBridge parity matrix test_classes do not match discovery"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsFullAgentBridgeParityMatrixWithoutScratchPath() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-agentbridge-missing-scratch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let agentBridgeURL = rootURL
            .appendingPathComponent("full-agentbridge-parity-matrix")
            .appendingPathComponent("full-agentbridge-parity-matrix-report.json")
        var agentBridge = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(agentBridgeURL)
        let swiftFilter = agentBridge["swift_filter"] as? String ?? "MSPGoalCapabilityTests"
        agentBridge["command"] = ["swift", "test", "--filter", swiftFilter]
        agentBridge.removeValue(forKey: "scratch_root")
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(agentBridge, to: agentBridgeURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("full AgentBridge parity matrix command does not use final-gate scratch path"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("full AgentBridge parity matrix scratch_root is missing or not a path string"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsExecSessionStressWithoutScratchPath() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-exec-stress-missing-scratch")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let execStressURL = rootURL
            .appendingPathComponent("exec-session-stress")
            .appendingPathComponent("exec-session-stress-report.json")
        var execStress = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(execStressURL)
        let swiftFilter = execStress["swift_filter"] as? String ?? "ModelShellProxyExecSessionStressTests|ModelShellProxyExecSessionPTYStressTests"
        execStress["command"] = ["swift", "test", "--filter", swiftFilter]
        execStress.removeValue(forKey: "scratch_root")
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(execStress, to: execStressURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("exec-session stress command does not use final-gate scratch path"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("exec-session stress scratch_root is missing or not a path string"),
            failed.stderr
        )
    }
}
