import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateExecStressFixture(rootURL: URL) throws -> URL {
        let reportURL = rootURL
            .appendingPathComponent("exec-session-stress")
            .appendingPathComponent("exec-session-stress-report.json")
        let reportRootURL = reportURL.deletingLastPathComponent()
        let scratchRootURL = reportRootURL.appendingPathComponent("scratch")
        let logURL = reportRootURL.appendingPathComponent("swift-test.log")
        let swiftFilter = "ModelShellProxyExecSessionStressTests|ModelShellProxyExecSessionPTYStressTests"
        try FileManager.default.createDirectory(at: scratchRootURL, withIntermediateDirectories: true)
        try """
        Test Suite 'ModelShellProxyExecSessionStressTests' passed.
        Test Suite 'ModelShellProxyExecSessionPTYStressTests' passed.
        Test Suite 'Selected tests' passed.
        \t Executed 15 tests, with 0 failures (0 unexpected) in 0.001 seconds

        """.write(to: logURL, atomically: true, encoding: .utf8)
        try writeJSONObject([
            "passed": true,
            "gate": "msp-exec-session-stress-gate",
            "out_dir": reportRootURL.path,
            "scratch_root": scratchRootURL.path,
            "log": logURL.path,
            "command": ["swift", "test", "--scratch-path", scratchRootURL.path, "--filter", swiftFilter],
            "exit_code": 0,
            "swift_filter": swiftFilter,
            "swift_filters": [
                "ModelShellProxyExecSessionStressTests",
                "ModelShellProxyExecSessionPTYStressTests"
            ],
            "minimum_executed_test_count": 15,
            "executed_test_count": 15,
            "skipped_test_count": 0,
            "failure_count": 0,
            "unexpected_failure_count": 0,
            "required_log_fragments": [
                "ModelShellProxyExecSessionStressTests",
                "ModelShellProxyExecSessionPTYStressTests"
            ],
            "stress": [
                "concurrency": 12,
                "large_output_bytes": 10_485_760,
                "stdin_writes": 24,
                "resource_iterations": 24
            ],
            "coverage": [
                "concurrent yielded pipe sessions",
                "PTY high-frequency stdin writes",
                "PTY repeated-session fd leak budget",
                "PTY post-cleanup idle CPU budget"
            ],
            "failures": []
        ], to: reportURL)
        return reportURL
    }
}
