import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static let finalGateFixtureSteps = [
        "real-model-pressure-preflight-hardening",
        "readex-boundary-check",
        "swift-build",
        "exec-command-bridge-tests",
        "pipe-session-contract-tests",
        "pty-session-contract-tests",
        "pty-session-interactive-tests",
        "exec-session-stress-gate",
        "yielded-session-poll-tests",
        "python-vfs-path-semantics-tests",
        "python-subprocess-policy-tests",
        "python-script-traceback-path-tests",
        "external-runner-path-virtualization-tests",
        "profile-asset-tests",
        "mixed-workspace-lazy-remote-tests",
        "workspace-ui-snapshot-consistency-tests",
        "photosorter-overlay-view-consistency-tests",
        "photosorter-ui-preview-cache-consistency-tests",
        "photosorter-ui-thumbnail-cache-consistency-tests",
        "open-source-release-dry-run",
        "dynamic-embedded-cpython-swift-tests",
        "focused-test-suites-ledger",
        "full-swift-test-suite",
        "full-agentbridge-parity-matrix",
        "core100-closure",
        "core100-noninteractive-oracle",
        "python-oracle-coverage-accounting",
        "debian12-noninteractive-oracle",
        "live-noninteractive-linux-vps-oracle",
        "debian12-linux-pty-oracle",
        "debian12-linux-pty-report-verify",
        "real-model-simulator-pressure-matrix"
    ]

    static func writeFinalGateStepLogs(rootURL: URL) throws -> [String: String] {
        var stepLogs: [String: String] = [:]
        for step in finalGateFixtureSteps {
            let logURL = rootURL.appendingPathComponent("\(step).log")
            try finalGateStepLogText(for: step).write(to: logURL, atomically: true, encoding: .utf8)
            stepLogs[step] = logURL.path
        }
        return stepLogs
    }

    static func finalGateStepLogText(for step: String) -> String {
        switch step {
        case "real-model-pressure-preflight-hardening":
            return "real-model pressure preflight checks passed\n"
        case "swift-build":
            return """
            command: swift build --scratch-path /tmp/final-gate/swiftpm-scratch/swift-build --target ModelShellProxy

            [0/1] Planning build
            Building for debugging...
            Build of target: 'ModelShellProxy' complete! (0.80s)

            """
        case "exec-command-bridge-tests",
             "pipe-session-contract-tests",
             "pty-session-contract-tests",
             "pty-session-interactive-tests",
             "yielded-session-poll-tests",
             "python-vfs-path-semantics-tests",
             "python-script-traceback-path-tests",
             "profile-asset-tests",
             "workspace-ui-snapshot-consistency-tests",
             "photosorter-overlay-view-consistency-tests",
             "photosorter-ui-preview-cache-consistency-tests",
             "photosorter-ui-thumbnail-cache-consistency-tests",
             "core100-noninteractive-oracle",
             "debian12-noninteractive-oracle",
             "debian12-linux-pty-oracle":
            return swiftStepLog(step: step, executedTests: 1)
        case "python-subprocess-policy-tests":
            return swiftStepLog(step: step, executedTests: 9)
        case "external-runner-path-virtualization-tests":
            return swiftStepLog(step: step, executedTests: 10)
        case "mixed-workspace-lazy-remote-tests":
            return swiftStepLog(step: step, executedTests: 2)
        case "open-source-release-dry-run":
            return "MSP open-source release dry-run passed\nreport=open-source-release-dry-run-report.json\n"
        case "dynamic-embedded-cpython-swift-tests":
            return "MSP dynamic embedded CPython Swift tests passed\nreport=dynamic-embedded-cpython-swift-tests-report.json\n"
        case "focused-test-suites-ledger":
            return "MSP focused test suites ledger passed\nreport=focused-test-suites-ledger-report.json\n"
        case "full-swift-test-suite":
            return "MSP full Swift test suite passed\nreport=full-swift-test-suite-report.json\n"
        case "full-agentbridge-parity-matrix":
            return "MSP full AgentBridge parity matrix passed\nreport=full-agentbridge-parity-matrix-report.json\n"
        case "core100-closure":
            return """
            {"artifact_kind":"msp-core100-closure-gate","batch_count":6,"failure_count":0,"failure_count_by_file":{},"required_command_count":100}
            """
        case "python-oracle-coverage-accounting":
            return """
            {"ios_embedded_cpython_gate_case_count":11,"noninteractive_python_case_count":11,"node_blocked_case_count":0,"pty_python_case_count":12,"pty_runtime_gate_case_count":12,"pty_runtime_gate_status":"executable-by-debian12-pty-oracle"}
            """
        case "readex-boundary-check":
            return "MSP Readex boundary verified\nsummary_report=readex-boundary-report.json\n"
        case "exec-session-stress-gate":
            return "MSP exec session stress gate passed\nreport=exec-session-stress-report.json\n"
        case "live-noninteractive-linux-vps-oracle":
            return "Live noninteractive Linux VPS oracle passed\nreport=live-noninteractive-linux-vps-oracle-report.json\n"
        case "debian12-linux-pty-report-verify":
            return "Debian 12 Linux PTY oracle report verified\n"
        case "real-model-simulator-pressure-matrix":
            return "real-model pressure matrix passed\nreport=pressure-matrix-report.json\n"
        default:
            return "step passed\n"
        }
    }

    private static func swiftStepLog(step: String, executedTests: Int) -> String {
        let noun = executedTests == 1 ? "test" : "tests"
        return """
        command: swift test --scratch-path /tmp/final-gate/swiftpm-scratch/\(step) --filter fixture

        Test Suite 'Selected tests' passed.
        \t Executed \(executedTests) \(noun), with 0 failures (0 unexpected) in 0.001 seconds

        """
    }
}
