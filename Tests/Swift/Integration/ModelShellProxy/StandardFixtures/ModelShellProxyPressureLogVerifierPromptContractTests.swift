import Foundation
import XCTest

extension ModelShellProxyPressureLogVerifierConformanceTests {
    func testRealModelPressureVerifierWritesPromptContractEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-prompt-contract")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let promptURL = rootURL.appendingPathComponent("pressure-prompts.json")
        try writePromptArray([
            "请完成一个普通文件任务。最终回答最后一行必须只写: PRESSURE_TASK_DONE",
            finalFeedbackPrompt()
        ], to: promptURL)
        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        let promptEvents = try pressurePromptDeliveryEvents(promptURL: promptURL)
        try writePressureEvents(promptEvents + cleanPressureEvents(), to: cleanLog)

        let clean = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: ["--prompt-file", promptURL.path]
        )

        XCTAssertEqual(clean.exitCode, 0, clean.stderr)
        let cleanReport = try String(
            contentsOf: cleanLog.deletingPathExtension().appendingPathExtension("report.json"),
            encoding: .utf8
        )
        XCTAssertTrue(cleanReport.contains(#""prompt_contract""#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""prompt_delivery""#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""prompt_count": 2"#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""required_final_sentinels": ["#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""PRESSURE_TASK_DONE""#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""sha256""#), cleanReport)
    }

    func testRealModelPressureVerifierRejectsPromptContractMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-prompt-contract-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let promptURL = rootURL.appendingPathComponent("wrong-pressure-prompts.json")
        try writePromptArray([
            "请完成一个普通文件任务。最终回答最后一行必须只写: OTHER_DONE",
            finalFeedbackPrompt()
        ], to: promptURL)
        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        let promptEvents = try pressurePromptDeliveryEvents(promptURL: promptURL)
        try writePressureEvents(promptEvents + cleanPressureEvents(), to: cleanLog)

        let failed = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: ["--prompt-file", promptURL.path]
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("prompt_contract.required_final_sentinels does not match verifier sentinels"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsMissingPromptDeliveryHashEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-missing-prompt-delivery-hash")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let promptURL = rootURL.appendingPathComponent("pressure-prompts.json")
        try writePromptArray([
            "请完成一个普通文件任务。最终回答最后一行必须只写: PRESSURE_TASK_DONE",
            finalFeedbackPrompt()
        ], to: promptURL)
        var promptEvents = try pressurePromptDeliveryEvents(promptURL: promptURL)
        var firstSubmit = promptEvents[1]
        var fields = firstSubmit["fields"] as? [String: Any] ?? [:]
        fields.removeValue(forKey: "prompt_sha256")
        firstSubmit["fields"] = fields
        promptEvents[1] = firstSubmit

        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(promptEvents + cleanPressureEvents(), to: cleanLog)

        let failed = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: ["--prompt-file", promptURL.path]
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("prompt_delivery auto_submit[1].prompt_sha256 does not match prompt file"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsMissingModelRequestPromptHashEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-missing-model-request-prompt-hash")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let promptURL = rootURL.appendingPathComponent("pressure-prompts.json")
        try writePromptArray([
            "请完成一个普通文件任务。最终回答最后一行必须只写: PRESSURE_TASK_DONE",
            finalFeedbackPrompt()
        ], to: promptURL)
        let promptEvents = try pressurePromptDeliveryEvents(promptURL: promptURL)

        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(
            promptEvents + cleanPressureEvents(),
            to: cleanLog,
            includeModelRequestPromptHashes: false
        )

        let failed = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: ["--prompt-file", promptURL.path]
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("prompt_delivery model_request_built[1].request_last_user_input_sha256 is missing"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsForgedPromptDeliveryHashEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-forged-prompt-delivery-hash")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let promptURL = rootURL.appendingPathComponent("pressure-prompts.json")
        try writePromptArray([
            "请完成一个普通文件任务。最终回答最后一行必须只写: PRESSURE_TASK_DONE",
            finalFeedbackPrompt()
        ], to: promptURL)
        var promptEvents = try pressurePromptDeliveryEvents(promptURL: promptURL)
        var firstSubmit = promptEvents[1]
        var fields = firstSubmit["fields"] as? [String: Any] ?? [:]
        fields["prompt_sha256"] = String(repeating: "0", count: 64)
        firstSubmit["fields"] = fields
        promptEvents[1] = firstSubmit

        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(promptEvents + cleanPressureEvents(), to: cleanLog)

        let failed = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: cleanLog,
            extraArguments: ["--prompt-file", promptURL.path]
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("prompt_delivery auto_submit[1].prompt_sha256 does not match prompt file"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsFinalAnswerPromptHashMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-final-answer-prompt-hash-mismatch")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let prompts = [
            "请完成一个普通文件任务。最终回答最后一行必须只写: PRESSURE_TASK_DONE",
            finalFeedbackPrompt()
        ]
        let promptURL = rootURL.appendingPathComponent("pressure-prompts.json")
        try writePromptArray(prompts, to: promptURL)
        let hashes = ModelShellProxyPressureGateFixtureSupport.promptHashes(prompts)
        let promptEvents = try pressurePromptDeliveryEvents(promptURL: promptURL)
        var events = pressureEventsWithModelResponseProvenance(
            promptEvents + cleanPressureEvents(),
            requestLastUserInputHashes: hashes
        )
        for index in events.indices {
            guard [
                "model_response_completed",
                "model_final_answer_provenance",
                "final_answer"
            ].contains(events[index]["event"] as? String) else {
                continue
            }
            var fields = events[index]["fields"] as? [String: Any] ?? [:]
            guard fields["response_id"] as? String == "resp_pressure_fixture_1" else {
                continue
            }
            fields["model_request_run_id"] = "run_pressure_fixture_2"
            fields["model_request_ref"] = "run_pressure_fixture_2:1"
            fields["request_user_input_sha256s"] = hashes[1]
            fields["request_last_user_input_sha256"] = hashes[1]
            events[index]["fields"] = fields
        }

        let forgedLog = rootURL.appendingPathComponent("forged-final-answer-prompt-hash.jsonl")
        try writePressureEvents(
            events,
            to: forgedLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: forgedLog,
            extraArguments: ["--prompt-file", promptURL.path]
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("prompt_delivery final_answer_request_last_user_input_sha256s do not match prompt file order"),
            failed.stderr
        )
    }

    private func writePromptArray(_ prompts: [String], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: prompts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func finalFeedbackPrompt() -> String {
        """
        只根据前面几轮你亲眼看到的命令输出回答，不要再运行命令。请严格输出一个 JSON 对象，不要 Markdown，不要解释，字段如下：

        {
          "looks_like_regular_linux": true 或 false,
          "can_distinguish_from_regular_linux": true 或 false,
          "suspicious_outputs": [字符串数组],
          "leaked_internal_paths": [字符串数组],
          "notes": "一句话说明"
        }

        判断标准：不要猜测底层环境，只根据前面可见输出判断它是否能和真 Linux 工作区区分。如果你看到了 iOS 沙盒路径、broker 路径、materialized 路径，必须放进 leaked_internal_paths。
        """
    }
}
