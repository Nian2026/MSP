import Foundation
import XCTest

class ModelShellProxyPressureLogVerifierTestCase: XCTestCase {
    let syntheticEventTimestamp = "2026-07-03T00:00:00Z"

    func pressureLogVerifierURL() throws -> URL {
        try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("MSPPlaygroundApp")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("verify-real-model-pressure-log.py")
    }

    func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "ModelShellProxyPressureLogVerifierConformanceTests",
            name: name
        )
    }

    func removeTemporaryURL(_ url: URL) {
        ModelShellProxyConformanceSupport.removeTemporaryURL(url)
    }

    func pressureToolStarted(_ command: String) -> [String: Any] {
        [
            "event": "tool_started",
            "fields": [
                "cmd": command
            ]
        ]
    }

    func pressureToolCompleted(stdout: String = "", stderr: String = "") -> [String: Any] {
        [
            "event": "tool_completed",
            "fields": [
                "content_text": stdout,
                "error_message": stderr
            ]
        ]
    }

    func pressureToolOutputDelta(_ stream: String, text: String) -> [String: Any] {
        [
            "event": "tool_output_delta",
            "fields": [
                "name": "exec_command",
                "stream": stream,
                "text": text
            ]
        ]
    }

    func pressureFinalAnswerDelta(_ text: String) -> [String: Any] {
        [
            "event": "final_answer_delta",
            "fields": [
                "text": text
            ]
        ]
    }

    func pressureModelRequestBuilt(
        model: String = "gpt-5.5",
        requestLastUserInputHash: String? = nil,
        requestRunID: String,
        requestSequence: Int = 1
    ) -> [String: Any] {
        let requestLastUserInputHash = requestLastUserInputHash ?? ""
        let fields: [String: Any] = [
            "request_layer": "runtime_provider",
            "request_run_id": requestRunID,
            "request_sequence": "\(requestSequence)",
            "model": model,
            "input_count": "1",
            "request_user_input_count": requestLastUserInputHash.isEmpty ? "0" : "1",
            "request_user_input_hash_algorithm": "sha256-utf8",
            "request_user_input_sha256s": requestLastUserInputHash,
            "request_last_user_input_sha256": requestLastUserInputHash,
            "tool_count": "1",
            "stream": "true"
        ]
        return [
            "event": "model_request_built",
            "fields": fields
        ]
    }

    func pressurePromptDeliveryEvents(promptURL: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: promptURL)
        let prompts = try JSONDecoder().decode([String].self, from: data)
        let hashes = ModelShellProxyPressureGateFixtureSupport.promptHashes(prompts)
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

    func pressureFinalAnswer(_ text: String) -> [String: Any] {
        [
            "event": "final_answer",
            "fields": [
                "text": text
            ]
        ]
    }

    func appendRawJSONLLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    func timestampedRawEvent(_ body: String) -> String {
        #"{"timestamp":"\#(syntheticEventTimestamp)",\#(body)}"#
    }

    func timestampedPressureEvent(_ event: [String: Any]) -> [String: Any] {
        var event = event
        event["timestamp"] = event["timestamp"] ?? syntheticEventTimestamp
        return event
    }

    func cleanPressureEvents() -> [[String: Any]] {
        [
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("created files\nPRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"all observed paths matched Linux expectations"}
            """)
        ]
    }

    func writePressureEvents(
        _ events: [[String: Any]],
        to url: URL,
        model: String = "gpt-5.5",
        modelRequestCount: Int? = nil,
        includeModelRequestPromptHashes: Bool = true,
        includeModelResponseProvenance: Bool = true
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let promptHashes = includeModelRequestPromptHashes
            ? events.compactMap { event -> String? in
                guard (event["event"] as? String) == "auto_submit",
                      let fields = event["fields"] as? [String: Any] else {
                    return nil
                }
                return fields["prompt_sha256"] as? String
            }
            : []
        let eventBody = includeModelResponseProvenance
            ? pressureEventsWithModelResponseProvenance(
                events,
                requestLastUserInputHashes: promptHashes
            )
            : events
        let defaultPressureTurnCount = max(
            1,
            eventBody.filter { ($0["event"] as? String) == "final_answer" }.count
        )
        let pressureTurnCount = modelRequestCount ?? defaultPressureTurnCount
        let requestEvents = (0..<pressureTurnCount).map { index in
            let promptHash = index < promptHashes.count ? promptHashes[index] : nil
            return pressureModelRequestBuilt(
                model: model,
                requestLastUserInputHash: promptHash,
                requestRunID: pressureRequestRunID(index: index + 1)
            )
        }
        let lines = try (requestEvents + eventBody).map { event -> String in
            let data = try JSONSerialization.data(
                withJSONObject: timestampedPressureEvent(event),
                options: [.sortedKeys]
            )
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func pressureEventsWithModelResponseProvenance(
        _ events: [[String: Any]],
        requestLastUserInputHashes: [String] = []
    ) -> [[String: Any]] {
        var rewritten: [[String: Any]] = []
        var finalAnswerIndex = 0
        for event in events {
            guard (event["event"] as? String) == "final_answer" else {
                rewritten.append(event)
                continue
            }
            finalAnswerIndex += 1
            let responseID = "resp_pressure_fixture_\(finalAnswerIndex)"
            let requestRunID = pressureRequestRunID(index: finalAnswerIndex)
            let requestRef = "\(requestRunID):1"
            var finalAnswer = event
            var fields = finalAnswer["fields"] as? [String: Any] ?? [:]
            let text = fields["text"] as? String ?? ""
            let textLength = fields["text_length"] as? String ?? "\(text.count)"
            let textSHA256 = fields["text_sha256"] as? String
                ?? ModelShellProxyPressureGateFixtureSupport.sha256Hex(text)
            let requestLastUserInputHash = finalAnswerIndex <= requestLastUserInputHashes.count
                ? requestLastUserInputHashes[finalAnswerIndex - 1]
                : (fields["request_last_user_input_sha256"] as? String ?? "")
            let requestUserInputHashes = fields["request_user_input_sha256s"] as? String ?? requestLastUserInputHash
            let requestHashAlgorithm = fields["request_user_input_hash_algorithm"] as? String ?? "sha256-utf8"
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
                    "request_user_input_hash_algorithm": requestHashAlgorithm,
                    "request_user_input_sha256s": requestUserInputHashes,
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
                    "request_user_input_hash_algorithm": requestHashAlgorithm,
                    "request_user_input_sha256s": requestUserInputHashes,
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
            fields["model_request_ref"] = requestRef
            fields["request_user_input_hash_algorithm"] = requestHashAlgorithm
            fields["request_user_input_sha256s"] = requestUserInputHashes
            fields["request_last_user_input_sha256"] = requestLastUserInputHash
            finalAnswer["fields"] = fields
            rewritten.append(finalAnswer)
        }
        return rewritten
    }

    private func pressureRequestRunID(index: Int) -> String {
        "run_pressure_fixture_\(index)"
    }

    func writeProviderSmokeEvidence(
        _ directoryURL: URL,
        requestModel: String = "gpt-5.5",
        expectedOutput: String = "MSP_PROVIDER_OK_1234567890abcdef",
        actualOutput: String = "MSP_PROVIDER_OK_1234567890abcdef"
    ) throws -> (request: URL, response: URL) {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let requestURL = directoryURL.appendingPathComponent("provider-smoke-request.redacted.json")
        let responseURL = directoryURL.appendingPathComponent("provider-smoke-response.json")
        try writeJSONObject([
            "model": requestModel,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "Return exactly and only this string: \(expectedOutput)"
                        ]
                    ]
                ]
            ],
            "store": false,
            "stream": false
        ], to: requestURL)
        try writeJSONObject([
            "id": "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            "object": "response",
            "output_text": actualOutput
        ], to: responseURL)
        return (requestURL, responseURL)
    }

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func runPressureVerifier(
        verifierURL: URL,
        eventLogURL: URL,
        model: String = "gpt-5.5",
        extraArguments: [String] = []
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            verifierURL.path,
            eventLogURL.path,
            "--report",
            eventLogURL.deletingPathExtension().appendingPathExtension("report.json").path,
            "--model",
            model
        ] + extraArguments

        var environment = ProcessInfo.processInfo.environment
        for key in [
            "PYTHONHOME",
            "PYTHONPATH",
            "PYTHONEXECUTABLE",
            "PYTHONUSERBASE",
            "PYTHONSTARTUP",
            "PYTHONPLATLIBDIR",
            "MSP_CPYTHON_LIBRARY_PATH",
            "MSP_CPYTHON_HOME",
            "MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH",
            "MSP_PLAYGROUND_EMBEDDED_CPYTHON_LIBRARY_PATH",
            "__PYVENV_LAUNCHER__"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
