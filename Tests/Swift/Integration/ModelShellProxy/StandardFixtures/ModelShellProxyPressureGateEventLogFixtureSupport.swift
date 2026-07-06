import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static let syntheticEventTimestamp = "2026-07-03T00:00:00Z"

    static func overwritePressureEventLog(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil,
        visibleOutput: String
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: visibleOutput))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append(feedbackEvent(notes: cleanFeedbackNotes))
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    static func overwritePressureEventLogWithoutTools(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append(feedbackEvent(notes: "synthetic pressure event log without tools"))
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))

        var report = try readJSONObject(pressureReportURL(rootURL: rootURL, suite: suite))
        report["tool_started_count"] = 0
        report["tool_completed_count"] = 0
        try writeJSONObject(report, to: pressureReportURL(rootURL: rootURL, suite: suite))
    }

    static func overwritePressureEventLogWithCollapsedFinalAnswers(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": sentinels.map { "completed \($0)\n\($0)" }.joined(separator: "\n")
            ]
        ])
        events.append(feedbackEvent(notes: "synthetic pressure event log with collapsed final answers"))
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))

        var report = try readJSONObject(pressureReportURL(rootURL: rootURL, suite: suite))
        report["final_answer_count"] = 2
        try writeJSONObject(report, to: pressureReportURL(rootURL: rootURL, suite: suite))
    }

    static func overwritePressureEventLogWithSharedSentinelFinalAnswer(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": sentinels.map { "completed \($0)\n\($0)" }.joined(separator: "\n")
            ]
        ])
        if sentinels.count > 1 {
            for index in 1..<sentinels.count {
                events.append([
                    "event": "final_answer",
                    "fields": [
                        "text": "completed pressure task \(index)"
                    ]
                ])
            }
        }
        events.append(feedbackEvent(notes: "synthetic pressure event log with shared sentinel final answer"))
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))

        var report = try readJSONObject(pressureReportURL(rootURL: rootURL, suite: suite))
        report["final_answer_count"] = sentinels.count + 1
        report["required_final_sentinel_answer_indices"] = sharedSentinelAnswerIndices(for: suite)
        try writeJSONObject(report, to: pressureReportURL(rootURL: rootURL, suite: suite))
    }

    static func overwritePressureEventLogWithExtraFillerFinalAnswer(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": "completed an extra pressure step without a required sentinel"
            ]
        ])
        events.append(feedbackEvent(notes: "synthetic pressure event log with extra filler final answer"))
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))

        var report = try readJSONObject(pressureReportURL(rootURL: rootURL, suite: suite))
        report["final_answer_count"] = sentinels.count + 2
        report["required_final_sentinel_answer_indices"] = requiredSentinelAnswerIndices(for: suite)
        try writeJSONObject(report, to: pressureReportURL(rootURL: rootURL, suite: suite))
    }

    static func overwritePressureEventLogWithNoisyFeedbackAnswer(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": """
                Feedback follows:
                {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"synthetic pressure event log with noisy feedback"}
                Done.
                """
            ]
        ])
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    static func overwritePressureEventLogWithMarkdownFencedFeedback(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": """
                ```json
                {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"synthetic pressure event log with fenced feedback"}
                ```
                """
            ]
        ])
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    static func overwritePressureEventLogWithUnquotedFeedbackLeak(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": """
                {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":["/private/var/mobile/Containers/Data/Application/ABC/tmp/msp-python-launcher.py"],"notes":"reported a leaked path that was not observed earlier"}
                """
            ]
        ])
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    static func overwritePressureEventLogWithUnquotedSuspiciousOutput(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": """
                {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":["error wording did not match Linux"],"leaked_internal_paths":[],"notes":"reported a suspicious output that was not observed earlier"}
                """
            ]
        ])
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    static func overwritePressureEventLogWithNegativeFeedbackWithoutEvidence(
        rootURL: URL,
        suite: String = "host-backed",
        model: String = requiredModel,
        modelRequestCount: Int? = nil
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: suiteURL, withIntermediateDirectories: true)
        let sentinels = requiredSentinels(for: suite)
        let pressureTurnCount = modelRequestCount ?? (sentinels.count + 1)
        var events = try basePressureEvents(suite: suite, model: model, count: pressureTurnCount)
        events.append(contentsOf: pwdToolEvents(visibleOutput: "/\n"))
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append([
            "event": "final_answer",
            "fields": [
                "text": """
                {"looks_like_regular_linux":false,"can_distinguish_from_regular_linux":true,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"reported a negative Linux verdict without observed evidence"}
                """
            ]
        ])
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    static func writePressureEventLog(
        suite: String,
        rootURL: URL,
        model: String,
        modelRequestCount: Int
    ) throws {
        let suiteURL = rootURL.appendingPathComponent(suite)
        let sentinels = requiredSentinels(for: suite)
        var events = try basePressureEvents(suite: suite, model: model, count: modelRequestCount)
        events.append([
            "event": "tool_started",
            "fields": [
                "cmd": isExecSessionSuite(suite) ? "python3 -i" : "pwd"
            ]
        ])
        if isExecSessionSuite(suite) {
            events.append(contentsOf: execSessionEvidenceEvents())
        } else {
            events.append([
                "event": "tool_completed",
                "fields": [
                    "content_text": "/\n",
                    "error_message": ""
                ]
            ])
        }
        events.append(contentsOf: sentinelAnswerEvents(sentinels))
        events.append(feedbackEvent(notes: cleanFeedbackNotes))
        try writeEvents(events, to: suiteURL.appendingPathComponent("events.jsonl"))
    }

    private static func basePressureEvents(suite: String, model: String, count: Int) throws -> [[String: Any]] {
        let promptEvents = try autoSubmitEvents(suite: suite)
        return try promptEvents + modelRequestEvents(suite: suite, model: model, count: count)
    }

    private static func autoSubmitEvents(suite: String) throws -> [[String: Any]] {
        let prompts = try pressurePrompts(for: suite)
        let hashes = promptHashes(prompts)
        return [
            [
                "event": "auto_submit_sequence_loaded",
                "fields": [
                    "prompt_count": "\(prompts.count)",
                    "prompt_hash_algorithm": "sha256-utf8",
                    "prompt_sha256s": hashes.joined(separator: ",")
                ]
            ]
        ] + hashes.enumerated().map { index, hash in
            [
                "event": "auto_submit",
                "fields": [
                    "prompt_index": "\(index + 1)",
                    "prompt_count": "\(prompts.count)",
                    "prompt_hash_algorithm": "sha256-utf8",
                    "prompt_sha256": hash
                ]
            ]
        }
    }

    private static func modelRequestEvents(suite: String, model: String, count: Int) throws -> [[String: Any]] {
        let hashes = promptHashes(try pressurePrompts(for: suite))
        return (0..<count).map { turnIndex in
            let index = min(turnIndex, max(0, hashes.count - 1))
            let hash = hashes.isEmpty ? "" : hashes[index]
            return [
                "event": "model_request_built",
                "fields": [
                    "request_layer": "runtime_provider",
                    "model": model,
                    "request_run_id": pressureRequestRunID(suite: suite, index: turnIndex + 1),
                    "request_sequence": "1",
                    "input_count": "1",
                    "request_user_input_count": "1",
                    "request_user_input_hash_algorithm": "sha256-utf8",
                    "request_user_input_sha256s": hash,
                    "request_last_user_input_sha256": hash,
                    "tool_count": "1",
                    "stream": "true"
                ]
            ]
        }
    }

    private static func pwdToolEvents(visibleOutput: String) -> [[String: Any]] {
        [
            [
                "event": "tool_started",
                "fields": [
                    "cmd": "pwd"
                ]
            ],
            [
                "event": "tool_completed",
                "fields": [
                    "content_text": visibleOutput,
                    "error_message": ""
                ]
            ]
        ]
    }

    private static func sentinelAnswerEvents(_ sentinels: [String]) -> [[String: Any]] {
        sentinels.map { sentinel in
            [
                "event": "final_answer",
                "fields": [
                    "text": "completed \(sentinel)\n\(sentinel)"
                ]
            ]
        }
    }

    private static func feedbackEvent(notes: String) -> [String: Any] {
        [
            "event": "final_answer",
            "fields": [
                "text": """
                {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"\(notes)"}
                """
            ]
        ]
    }

    private static func writeEvents(_ events: [[String: Any]], to url: URL) throws {
        let suite = url.deletingLastPathComponent().lastPathComponent
        let eventsWithProvenance = pressureEventsWithModelResponseProvenance(events, suite: suite)
        let lines = try eventsWithProvenance.map { event -> String in
            let data = try JSONSerialization.data(
                withJSONObject: timestampedPressureEvent(event),
                options: [.sortedKeys]
            )
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func timestampedPressureEvent(_ event: [String: Any]) -> [String: Any] {
        var event = event
        event["timestamp"] = event["timestamp"] ?? syntheticEventTimestamp
        return event
    }

    private static func pressureEventsWithModelResponseProvenance(
        _ events: [[String: Any]],
        suite: String
    ) -> [[String: Any]] {
        var rewritten: [[String: Any]] = []
        var finalAnswerIndex = 0
        for event in events {
            guard (event["event"] as? String) == "final_answer" else {
                rewritten.append(event)
                continue
            }
            finalAnswerIndex += 1
            let responseID = pressureResponseID(suite: suite, index: finalAnswerIndex)
            let requestRunID = pressureRequestRunID(suite: suite, index: finalAnswerIndex)
            var finalAnswer = event
            var fields = finalAnswer["fields"] as? [String: Any] ?? [:]
            let text = fields["text"] as? String ?? ""
            let textLength = fields["text_length"] as? String ?? "\(text.count)"
            let textSHA256 = fields["text_sha256"] as? String
                ?? ModelShellProxyPressureGateFixtureSupport.sha256Hex(text)
            let requestLastUserInputHash = requestLastUserInputHash(suite: suite, index: finalAnswerIndex)
            rewritten.append([
                "event": "model_response_completed",
                "fields": [
                    "response_id": responseID,
                    "response_completed": "true",
                    "source": "responses_stream",
                    "model_request_layer": "runtime_provider",
                    "model_request_run_id": requestRunID,
                    "model_request_sequence": "1",
                    "model_request_model": "gpt-5.5",
                    "request_user_input_hash_algorithm": "sha256-utf8",
                    "request_user_input_sha256s": requestLastUserInputHash,
                    "request_last_user_input_sha256": requestLastUserInputHash,
                    "output_item_count": "1",
                    "tool_call_count": "0",
                    "has_final_answer": "true",
                    "has_assistant_message": "false"
                ]
            ])
            rewritten.append([
                "event": "model_final_answer_provenance",
                "fields": [
                    "response_id": responseID,
                    "response_completed": "true",
                    "source": "provider_stream_final_answer",
                    "model_request_layer": "runtime_provider",
                    "model_request_run_id": requestRunID,
                    "model_request_sequence": "1",
                    "model_request_model": "gpt-5.5",
                    "request_user_input_hash_algorithm": "sha256-utf8",
                    "request_user_input_sha256s": requestLastUserInputHash,
                    "request_last_user_input_sha256": requestLastUserInputHash,
                    "text_length": textLength,
                    "text_hash_algorithm": "sha256-utf8",
                    "text_sha256": textSHA256,
                    "output_item_count": "1",
                    "tool_call_count": "0"
                ]
            ])
            fields["text_length"] = textLength
            fields["text_hash_algorithm"] = "sha256-utf8"
            fields["text_sha256"] = textSHA256
            fields["response_id"] = responseID
            fields["response_completed"] = "true"
            fields["source"] = "provider_stream_final_answer"
            fields["provenance_event"] = "model_final_answer_provenance"
            fields["provenance_text_length"] = textLength
            fields["provenance_text_hash_algorithm"] = "sha256-utf8"
            fields["provenance_text_sha256"] = textSHA256
            fields["model_request_layer"] = "runtime_provider"
            fields["model_request_run_id"] = requestRunID
            fields["model_request_sequence"] = "1"
            fields["model_request_model"] = "gpt-5.5"
            fields["request_user_input_hash_algorithm"] = "sha256-utf8"
            fields["request_user_input_sha256s"] = requestLastUserInputHash
            fields["request_last_user_input_sha256"] = requestLastUserInputHash
            finalAnswer["fields"] = fields
            rewritten.append(finalAnswer)
        }
        return rewritten
    }

    private static func pressureRequestRunID(suite: String, index: Int) -> String {
        let normalizedSuite = suite
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "run_\(normalizedSuite)_fixture_\(index)"
    }

    private static func requestLastUserInputHash(suite: String, index: Int) -> String {
        let hashes = (try? promptHashes(pressurePrompts(for: suite))) ?? []
        guard !hashes.isEmpty else {
            return ""
        }
        return hashes[min(index - 1, hashes.count - 1)]
    }

    private static func isExecSessionSuite(_ suite: String) -> Bool {
        suite == "exec-session" || suite == "photosorter-exec-session"
    }

    private static func execSessionEvidenceEvents() -> [[String: Any]] {
        [
            [
                "event": "probe_agent_runtime_bridge_run_before",
                "fields": [
                    "yield_time_ms": "1000",
                    "tty": "true"
                ]
            ],
            [
                "event": "probe_agent_runtime_bridge_run_after",
                "fields": [
                    "session_id": "session_synthetic"
                ]
            ],
            [
                "event": "probe_agent_runtime_bridge_write_stdin_before",
                "fields": [
                    "chars_kind": "empty_poll"
                ]
            ],
            [
                "event": "probe_agent_runtime_bridge_write_stdin_before",
                "fields": [
                    "chars_kind": "input"
                ]
            ],
            [
                "event": "probe_agent_runtime_bridge_write_stdin_before",
                "fields": [
                    "chars_kind": "interrupt"
                ]
            ],
            [
                "event": "probe_agent_runtime_bridge_write_stdin_after",
                "fields": [:]
            ],
            [
                "event": "probe_agent_runtime_bridge_write_stdin_after",
                "fields": [:]
            ],
            [
                "event": "probe_agent_runtime_bridge_write_stdin_after",
                "fields": [:]
            ],
            [
                "event": "tool_completed",
                "fields": [
                    "content_text": "Process running with session ID session_synthetic\n",
                    "error_message": ""
                ]
            ],
            [
                "event": "tool_completed",
                "fields": [
                    "content_text": "Process exited with code 0\n",
                    "error_message": ""
                ]
            ]
        ]
    }
}
