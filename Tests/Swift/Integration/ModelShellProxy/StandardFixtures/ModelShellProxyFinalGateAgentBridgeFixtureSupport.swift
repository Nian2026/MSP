import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateAgentBridgeParityMatrixFixture(rootURL: URL) throws -> URL {
        let fixturePaths = try writeFinalGateFullSwiftTestSuiteEnvironmentFixture(rootURL: rootURL)
        let reportURL = rootURL
            .appendingPathComponent("full-agentbridge-parity-matrix")
            .appendingPathComponent("full-agentbridge-parity-matrix-report.json")
        let reportRootURL = reportURL.deletingLastPathComponent()
        let swiftLogURL = reportRootURL.appendingPathComponent("full-agentbridge-parity-matrix-swift.log")
        let sourceLogURL = reportRootURL.appendingPathComponent("agentbridge-compaction-source-currentness.log")
        let discoveryURL = reportRootURL.appendingPathComponent("agentbridge-test-discovery.json")
        let scratchRootURL = reportRootURL.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: reportRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchRootURL, withIntermediateDirectories: true)

        try """
        OK Codex compaction currentness
        pinned_commit=80f54d1266b4571ef649e7e5ecc382dd4e670937
        origin_head=a98a21798c3301cfbeb6c323d6c0f6a804e08a57
        codex_paths=66
        storage_evidence_paths=7

        """.write(to: sourceLogURL, atomically: true, encoding: .utf8)

        let requiredBuckets = [
            "exec-command-session-contract",
            "responses-streaming-and-tool-calls",
            "apply-patch-tool",
            "conversation-request-history",
            "interrupt-and-turn-interrupt",
            "compaction-local-auto-remote-replay",
            "goal-capability",
            "turn-steer-capability"
        ]
        let bucketClasses: [String: [String]] = [
            "exec-command-session-contract": ["MSPExecCommandBridgeTests", "MSPAgentConversationExecSessionRequestTests"],
            "responses-streaming-and-tool-calls": ["MSPResponsesStreamingModelClientTests", "MSPAgentConversationToolOutputTests"],
            "apply-patch-tool": ["MSPApplyPatchToolTests"],
            "conversation-request-history": ["MSPAgentConversationRequestHistoryTests", "MSPAgentConversationRequestMetadataTests"],
            "interrupt-and-turn-interrupt": ["MSPAgentConversationInterruptTests", "MSPAgentConversationInterruptRequestTests", "MSPTurnInterruptCapabilityTests"],
            "compaction-local-auto-remote-replay": ["MSPAgentConversationCompactionRequestTests", "MSPAgentConversationAutoCompactionRequestTests", "MSPAgentConversationPendingInputCompactionTests", "MSPAgentConversationRemoteCompactionTests", "MSPAgentToolLoopPendingInputCompactionTests", "MSPChatCompactionPackageStoreTests", "MSPCompactionHistoryRewriterTests"],
            "goal-capability": ["MSPGoalCapabilityTests"],
            "turn-steer-capability": ["MSPTurnSteerCapabilityTests", "MSPTurnSteerTimingTests", "MSPTurnSteerValidationTests"]
        ]
        let classNames = Array(Set(bucketClasses.values.flatMap { $0 })).sorted()
        let baseClassTestCount = 9
        let extraClassTestCount = 207 - (baseClassTestCount * classNames.count)
        let classDeclaredTestCounts = Dictionary(uniqueKeysWithValues: classNames.enumerated().map { index, name in
            (name, baseClassTestCount + (index == 0 ? extraClassTestCount : 0))
        })
        let testFilter = classNames.joined(separator: "|")
        let swiftLog = classNames
            .map { "Test Suite '\($0)' passed." }
            .joined(separator: "\n")
            + """

            Test Suite 'Selected tests' passed.
            \t Executed 207 tests, with 0 failures (0 unexpected) in 0.001 seconds

            """
        try swiftLog.write(to: swiftLogURL, atomically: true, encoding: .utf8)

        var capabilityBuckets: [String: Any] = [:]
        for bucket in requiredBuckets {
            let classes = bucketClasses[bucket] ?? []
            capabilityBuckets[bucket] = [
                "classes": classes,
                "coverage": ["fixture coverage for \(bucket)"],
                "missing_classes": [],
                "present": true,
                "declared_test_count": classes.reduce(0) { total, name in
                    total + (classDeclaredTestCounts[name] ?? 0)
                }
            ]
        }
        let testClasses = classNames
            .map { name in
                [
                    "name": name,
                    "declared_test_count": classDeclaredTestCounts[name] ?? 0,
                    "source_files": ["Tests/Swift/Unit/MSPAgentBridge/\(name).swift"]
                ] as [String: Any]
            }
        try writeJSONObject([
            "test_root": "Tests/Swift/Unit/MSPAgentBridge",
            "test_class_count": testClasses.count,
            "declared_test_count": 207,
            "test_filter": testFilter,
            "test_classes": testClasses,
            "required_capability_buckets": requiredBuckets,
            "capability_buckets": capabilityBuckets,
            "failures": []
        ], to: discoveryURL)

        try writeJSONObject([
            "passed": true,
            "gate": "msp-full-agentbridge-parity-matrix",
            "package_path": ".",
            "command": ["swift", "test", "--scratch-path", scratchRootURL.path, "--filter", testFilter],
            "swift_filter": testFilter,
            "out_dir": reportRootURL.path,
            "scratch_root": scratchRootURL.path,
            "discovery": discoveryURL.path,
            "swift_log": swiftLogURL.path,
            "source_currentness_log": sourceLogURL.path,
            "minimum_executed_test_count": 180,
            "test_root": "Tests/Swift/Unit/MSPAgentBridge",
            "test_class_count": testClasses.count,
            "declared_test_count": 207,
            "executed_test_count": 207,
            "skipped_test_count": 0,
            "failure_count": 0,
            "unexpected_failure_count": 0,
            "environment_contract": [
                "MSP_CODEX_APPLY_PATCH_DYLIB": fixturePaths.applyPatchDylib.path
            ],
            "required_capability_buckets": requiredBuckets,
            "capability_buckets": capabilityBuckets,
            "test_classes": testClasses,
            "source_currentness": [
                "script": "Conformance/Scripts/verify_agentbridge_compaction_source_currentness.sh",
                "exit_code": 0,
                "passed": true,
                "pinned_commit": "80f54d1266b4571ef649e7e5ecc382dd4e670937",
                "origin_head": "a98a21798c3301cfbeb6c323d6c0f6a804e08a57",
                "codex_paths": 66,
                "storage_evidence_paths": 7
            ],
            "failures": []
        ], to: reportURL)
        return reportURL
    }
}
