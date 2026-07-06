import Foundation
import CryptoKit

enum ModelShellProxyPressureGateFixtureSupport {
    static let requiredModel = "gpt-5.5"

    static let pressureSuites = ["host-backed", "exec-session", "mixed-backend", "photosorter-virtual", "photosorter-exec-session"]
    static let cleanFeedbackNotes = "synthetic real-model pressure fixture"

    static func requiredSentinels(for suite: String) -> [String] {
        [
            "host-backed": [
                "PRESSURE_TASK_DONE",
                "PRESSURE_STATE_CHANGE_DONE",
                "PRESSURE_BULK_PERMISSION_DONE"
            ],
            "exec-session": [
                "EXEC_YIELD_POLL_DONE",
                "EXEC_PTY_PYTHON_DONE",
                "EXEC_INTERRUPT_DONE"
            ],
            "mixed-backend": [
                "MIXED_WORKSPACE_TASK_DONE",
                "MIXED_PYTHON_SUBPROCESS_DONE",
                "MIXED_MOVE_DELETE_BATCH_DONE"
            ],
            "photosorter-virtual": [
                "PHOTO_ROOT_DONE",
                "PHOTO_PYTHON_DONE",
                "PHOTO_STATE_BATCH_DONE"
            ],
            "photosorter-exec-session": [
                "EXEC_YIELD_POLL_DONE",
                "EXEC_PTY_PYTHON_DONE",
                "EXEC_INTERRUPT_DONE"
            ]
        ][suite] ?? []
    }

    static func requiredSentinelAnswerIndices(for suite: String) -> [String: [Int]] {
        Dictionary(uniqueKeysWithValues: requiredSentinels(for: suite).enumerated().map { index, sentinel in
            (sentinel, [index])
        })
    }

    static func sharedSentinelAnswerIndices(for suite: String) -> [String: [Int]] {
        Dictionary(uniqueKeysWithValues: requiredSentinels(for: suite).map { sentinel in
            (sentinel, [0])
        })
    }

    static func requiredPromptPath(for suite: String) -> String {
        [
            "host-backed": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/host-backed-linux-parity-prompts.json",
            "exec-session": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/exec-session-parity-prompts.json",
            "mixed-backend": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/mixed-backend-linux-parity-prompts.json",
            "photosorter-virtual": "Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-virtual-workspace-prompts.json",
            "photosorter-exec-session": "Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-exec-session-parity-prompts.json"
        ][suite] ?? ""
    }

    static func writePressureSuiteReport(
        _ suite: String,
        rootURL: URL,
        passed: Bool,
        failures: [String],
        providerSmokeChecked: Bool = true,
        providerSmokeExpectedOutput: String? = nil,
        providerSmokeActualOutput: String? = nil,
        model: String = requiredModel,
        mainRequestModel: String = requiredModel,
        providerSmokeRequestModel: String = requiredModel,
        modelRequestCount: Int? = nil,
        modelRequestExpectedCount: Int? = nil,
        reportedModelFailures: [String]? = nil,
        reportedPassed: Bool? = nil
    ) throws {
        let execSessionContract: [String: Int]
        if suite == "exec-session" || suite == "photosorter-exec-session" {
            execSessionContract = [
                "bounded_yield_exec_count": 1,
                "yielded_session_count": 1,
                "running_envelope_count": 1,
                "exited_envelope_count": 1,
                "pty_exec_count": 1,
                "poll_write_count": 1,
                "input_write_count": 1,
                "interrupt_write_count": 1
            ]
        } else {
            execSessionContract = [:]
        }

        let suiteURL = rootURL
            .appendingPathComponent(suite)
            .appendingPathComponent("pressure-report.json")
        try FileManager.default.createDirectory(
            at: suiteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let effectiveProviderSmokeExpectedOutput = providerSmokeExpectedOutput ?? makeProviderSmokeExpectedOutput()
        let effectiveProviderSmokeActualOutput = providerSmokeActualOutput ?? effectiveProviderSmokeExpectedOutput
        let providerSmokeEvidence = try writeProviderSmokeEvidence(
            suiteURL.deletingLastPathComponent().appendingPathComponent("provider-smoke"),
            requestModel: providerSmokeRequestModel,
            expectedOutput: effectiveProviderSmokeExpectedOutput,
            actualOutput: effectiveProviderSmokeActualOutput
        )
        let suiteSentinels = requiredSentinels(for: suite)
        let promptContract = try pressurePromptContract(for: suite)
        let promptDelivery = try pressurePromptDelivery(for: suite)
        let modelResponseProvenance = modelResponseProvenance(for: suite)
        let defaultModelFailures = model == requiredModel ? [] : [
            "pressure suite model is not \(requiredModel): \(model)"
        ]
        let modelFailures = reportedModelFailures ?? defaultModelFailures
        let reportFailures = failures + modelFailures
        let expectedModelRequestCount = modelRequestExpectedCount ?? (suiteSentinels.count + 1)
        let reportedModelRequestCount = modelRequestCount ?? expectedModelRequestCount
        let report: [String: Any] = [
            "passed": reportedPassed ?? (passed && defaultModelFailures.isEmpty),
            "failures": reportFailures,
            "required_model": requiredModel,
            "model": model,
            "model_matches_required": model == requiredModel,
            "model_failures": modelFailures,
            "model_request_built": [
                "count": reportedModelRequestCount,
                "expected_count": expectedModelRequestCount,
                "request_layers": Array(repeating: "runtime_provider", count: reportedModelRequestCount),
                "models": [mainRequestModel],
                "all_match_required": mainRequestModel == requiredModel
                    && reportedModelRequestCount >= expectedModelRequestCount,
                "failures": modelRequestFailures(
                    model: mainRequestModel,
                    count: reportedModelRequestCount,
                    expectedCount: expectedModelRequestCount
                )
            ],
            "event_log": "events.jsonl",
            "required_final_sentinels": suiteSentinels,
            "required_final_sentinel_answer_indices": requiredSentinelAnswerIndices(for: suite),
            "final_answer_count": suiteSentinels.count + 1,
            "tool_started_count": 1,
            "tool_completed_count": suite == "exec-session" || suite == "photosorter-exec-session" ? 2 : 1,
            "feedback": [
                "looks_like_regular_linux": true,
                "can_distinguish_from_regular_linux": false,
                "suspicious_outputs": [],
                "leaked_internal_paths": [],
                "notes": cleanFeedbackNotes
            ],
            "scanner_leaks": [],
            "model_response_provenance": modelResponseProvenance,
            "prompt_contract": promptContract,
            "prompt_delivery": promptDelivery,
            "provider_smoke": [
                "checked": providerSmokeChecked,
                "request": "provider-smoke/provider-smoke-request.redacted.json",
                "response": "provider-smoke/provider-smoke-response.json",
                "request_model": providerSmokeRequestModel,
                "request_model_matches_required": providerSmokeRequestModel == requiredModel,
                "expected_output": effectiveProviderSmokeExpectedOutput,
                "actual_output": effectiveProviderSmokeActualOutput,
                "request_artifact_model": providerSmokeRequestModel,
                "request_artifact_expected_output": effectiveProviderSmokeExpectedOutput,
                "response_artifact_id": providerSmokeEvidence.responseID,
                "response_artifact_object": "response",
                "response_artifact_actual_output": effectiveProviderSmokeActualOutput
            ],
            "exec_session_contract": execSessionContract
        ]
        try writeJSONObject(report, to: suiteURL)
        try writePressureEventLog(
            suite: suite,
            rootURL: rootURL,
            model: mainRequestModel,
            modelRequestCount: reportedModelRequestCount
        )
    }

    static func removeFields(_ fields: [String], fromSuiteReport suite: String, rootURL: URL) throws {
        let suiteURL = pressureReportURL(rootURL: rootURL, suite: suite)
        var object = try readJSONObject(suiteURL)
        for field in fields {
            object.removeValue(forKey: field)
        }
        try writeJSONObject(object, to: suiteURL)
    }

    static func overwriteProviderSmokeRequest(
        rootURL: URL,
        suite: String = "host-backed",
        expectedOutput: String,
        model: String = requiredModel
    ) throws {
        try writeJSONObject([
            "model": model,
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
        ], to: providerSmokeURL(rootURL: rootURL, suite: suite, file: "provider-smoke-request.redacted.json"))
    }

    static func overwriteProviderSmokeResponse(
        rootURL: URL,
        suite: String = "host-backed",
        outputText: String
    ) throws {
        try writeJSONObject([
            "id": makeProviderSmokeResponseID(),
            "object": "response",
            "output_text": outputText
        ], to: providerSmokeURL(rootURL: rootURL, suite: suite, file: "provider-smoke-response.json"))
    }

    private static func writeProviderSmokeEvidence(
        _ directoryURL: URL,
        requestModel: String = requiredModel,
        expectedOutput: String,
        actualOutput: String
    ) throws -> (request: URL, response: URL, responseID: String) {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let requestURL = directoryURL.appendingPathComponent("provider-smoke-request.redacted.json")
        let responseURL = directoryURL.appendingPathComponent("provider-smoke-response.json")
        let responseID = makeProviderSmokeResponseID()
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
            "id": responseID,
            "object": "response",
            "output_text": actualOutput
        ], to: responseURL)
        return (requestURL, responseURL, responseID)
    }

    private static func makeProviderSmokeExpectedOutput() -> String {
        let hex = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "MSP_PROVIDER_OK_\(String(hex.prefix(16)))"
    }

    private static func makeProviderSmokeResponseID() -> String {
        let hex = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "resp_\(hex)"
    }

    private static func pressurePromptContract(for suite: String) throws -> [String: Any] {
        let relativePath = requiredPromptPath(for: suite)
        let (data, prompts) = try pressurePromptDataAndPrompts(for: suite)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return [
            "passed": true,
            "failures": [],
            "path": relativePath,
            "sha256": digest,
            "prompt_count": prompts.count,
            "required_final_sentinels": requiredSentinels(for: suite)
        ]
    }

    static func pressureResponseID(suite: String, index: Int) -> String {
        let normalizedSuite = suite
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "resp_\(normalizedSuite)_fixture_\(index)"
    }

    private static func modelResponseProvenance(for suite: String) -> [String: Any] {
        let responseIDs = (1...(requiredSentinels(for: suite).count + 1)).map { index in
            pressureResponseID(suite: suite, index: index)
        }
        let requestRefs = responseIDs.indices.map { index in
            "\(pressureRequestRunID(suite: suite, index: index + 1)):1"
        }
        let hashes = (try? promptHashes(pressurePrompts(for: suite))) ?? []
        let answerHashes = responseIDs.indices.map { index in
            hashes.isEmpty ? "" : hashes[min(index, hashes.count - 1)]
        }
        let textHashes = finalAnswerTexts(for: suite).map(sha256Hex)
        return [
            "passed": true,
            "failures": [],
            "model_response_completed_count": responseIDs.count,
            "model_response_final_answer_count": responseIDs.count,
            "final_answer_count": responseIDs.count,
            "completed_response_ids": responseIDs,
            "final_answer_response_ids": responseIDs,
            "final_answer_sources": Array(repeating: "provider_stream_final_answer", count: responseIDs.count),
            "final_answer_completed": Array(repeating: true, count: responseIDs.count),
            "completed_model_request_layers": Array(repeating: "runtime_provider", count: responseIDs.count),
            "completed_model_request_refs": requestRefs,
            "final_answer_model_request_layers": Array(repeating: "runtime_provider", count: responseIDs.count),
            "final_answer_model_request_refs": requestRefs,
            "final_answer_request_last_user_input_sha256s": answerHashes,
            "final_answer_text_sha256s": textHashes
        ]
    }

    private static func pressureRequestRunID(suite: String, index: Int) -> String {
        let normalizedSuite = suite
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "run_\(normalizedSuite)_fixture_\(index)"
    }

    private static func pressurePromptDelivery(for suite: String) throws -> [String: Any] {
        let prompts = try pressurePrompts(for: suite)
        let hashes = promptHashes(prompts)
        return [
            "passed": true,
            "failures": [],
            "path": requiredPromptPath(for: suite),
            "hash_algorithm": "sha256-utf8",
            "prompt_count": prompts.count,
            "prompt_sha256s": hashes,
            "auto_submit_sequence_loaded_count": 1,
            "auto_submit_count": prompts.count,
            "auto_submit_indices": Array(1...prompts.count),
            "model_request_count": prompts.count,
            "model_request_layers": Array(repeating: "runtime_provider", count: prompts.count),
            "model_request_last_user_input_sha256s": hashes,
            "model_request_prompt_match_indices": Array(0..<prompts.count),
            "final_answer_request_last_user_input_sha256s": hashes
        ]
    }

    private static func pressurePromptDataAndPrompts(for suite: String) throws -> (Data, [String]) {
        let promptURL = try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent(requiredPromptPath(for: suite))
        let data = try Data(contentsOf: promptURL)
        let prompts = try JSONDecoder().decode([String].self, from: data)
        return (data, prompts)
    }

    static func pressurePrompts(for suite: String) throws -> [String] {
        try pressurePromptDataAndPrompts(for: suite).1
    }

    static func promptHashes(_ prompts: [String]) -> [String] {
        prompts.map(sha256Hex)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func finalAnswerTexts(for suite: String) -> [String] {
        requiredSentinels(for: suite).map { sentinel in
            "completed \(sentinel)\n\(sentinel)"
        } + [
            """
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"\(cleanFeedbackNotes)"}
            """
        ]
    }

    static func pressureReportURL(rootURL: URL, suite: String) -> URL {
        rootURL.appendingPathComponent(suite).appendingPathComponent("pressure-report.json")
    }

    private static func providerSmokeURL(rootURL: URL, suite: String, file: String) -> URL {
        rootURL.appendingPathComponent(suite).appendingPathComponent("provider-smoke").appendingPathComponent(file)
    }

    static func modelRequestFailures(model: String, count: Int, expectedCount: Int) -> [String] {
        var failures: [String] = []
        if model != requiredModel {
            failures.append("model_request_built model is not \(requiredModel): \(model)")
        }
        if count < expectedCount {
            failures.append("model_request_built count \(count) is below expected pressure turn count \(expectedCount)")
        }
        return failures
    }

    static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(
                domain: "ModelShellProxyPressureGateFixtureSupport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JSON object is not a dictionary: \(url.path)"]
            )
        }
        return dictionary
    }

    static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
