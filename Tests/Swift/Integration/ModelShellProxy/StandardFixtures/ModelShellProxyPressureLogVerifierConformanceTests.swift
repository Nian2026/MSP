import Foundation
import XCTest

final class ModelShellProxyPressureLogVerifierConformanceTests: ModelShellProxyPressureLogVerifierTestCase {
    func testRealModelPressureVerifierAcceptsCleanLogAndWritesModelEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-basic")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let cleanLog = rootURL.appendingPathComponent("clean.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: cleanLog)
        let clean = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertEqual(clean.exitCode, 0, clean.stderr)
        let cleanReport = try String(
            contentsOf: cleanLog.deletingPathExtension().appendingPathExtension("report.json"),
            encoding: .utf8
        )
        XCTAssertTrue(cleanReport.contains(#""passed": true"#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""failures": []"#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""model_request_built""#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""expected_count": 2"#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""models": ["#), cleanReport)
        XCTAssertTrue(cleanReport.contains(#""gpt-5.5""#), cleanReport)
    }

    func testRealModelPressureVerifierRejectsNoisyFeedbackEnvelope() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-noisy-feedback")
        defer { removeTemporaryURL(rootURL) }
        let noisyFeedbackLog = rootURL.appendingPathComponent("noisy-feedback.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("created files\nPRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            Feedback follows:
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"all observed paths matched Linux expectations"}
            Done.
            """)
        ], to: noisyFeedbackLog)

        let noisyFeedback = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: noisyFeedbackLog)

        XCTAssertNotEqual(noisyFeedback.exitCode, 0)
        XCTAssertTrue(
            noisyFeedback.stderr.contains("feedback answer is invalid: feedback answer must be a JSON object"),
            noisyFeedback.stderr
        )
    }

    func testRealModelPressureVerifierRejectsMarkdownFencedFeedbackJSON() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-fenced-feedback")
        defer { removeTemporaryURL(rootURL) }
        let fencedFeedbackLog = rootURL.appendingPathComponent("fenced-feedback.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("created files\nPRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            ```json
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"all observed paths matched Linux expectations"}
            ```
            """)
        ], to: fencedFeedbackLog)

        let fencedFeedback = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: fencedFeedbackLog
        )

        XCTAssertNotEqual(fencedFeedback.exitCode, 0)
        XCTAssertTrue(
            fencedFeedback.stderr.contains("feedback answer must be a raw JSON object, not Markdown fenced JSON"),
            fencedFeedback.stderr
        )
    }

    func testRealModelPressureVerifierRejectsNonObjectJSONLEventLines() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-nonobject-event")
        defer { removeTemporaryURL(rootURL) }
        let nonObjectEventLog = rootURL.appendingPathComponent("nonobject-event.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: nonObjectEventLog)
        try appendRawJSONLLine("[\"not-an-event-object\"]", to: nonObjectEventLog)

        let nonObjectEvent = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: nonObjectEventLog
        )

        XCTAssertNotEqual(nonObjectEvent.exitCode, 0)
        XCTAssertTrue(
            nonObjectEvent.stderr.contains("event must be a JSON object"),
            nonObjectEvent.stderr
        )
    }

    func testRealModelPressureVerifierRejectsBlankJSONLEventLines() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-blank-event-line")
        defer { removeTemporaryURL(rootURL) }
        let blankLineEventLog = rootURL.appendingPathComponent("blank-event-line.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: blankLineEventLog)
        try appendRawJSONLLine("", to: blankLineEventLog)

        let blankLineEvent = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: blankLineEventLog
        )

        XCTAssertNotEqual(blankLineEvent.exitCode, 0)
        XCTAssertTrue(
            blankLineEvent.stderr.contains("blank JSONL event line is not allowed"),
            blankLineEvent.stderr
        )
    }

    func testRealModelPressureVerifierRejectsMalformedJSONLEventRecordShape() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-malformed-event-shape")
        defer { removeTemporaryURL(rootURL) }

        let missingNameLog = rootURL.appendingPathComponent("missing-event-name.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: missingNameLog)
        try appendRawJSONLLine(timestampedRawEvent(#""fields":{}"#), to: missingNameLog)

        let missingName = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: missingNameLog)

        XCTAssertNotEqual(missingName.exitCode, 0)
        XCTAssertTrue(
            missingName.stderr.contains("event must have a non-empty string event name"),
            missingName.stderr
        )

        let missingTimestampLog = rootURL.appendingPathComponent("missing-timestamp.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: missingTimestampLog)
        try appendRawJSONLLine(#"{"event":"tool_completed","fields":{}}"#, to: missingTimestampLog)

        let missingTimestamp = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: missingTimestampLog
        )

        XCTAssertNotEqual(missingTimestamp.exitCode, 0)
        XCTAssertTrue(
            missingTimestamp.stderr.contains("event timestamp is missing"),
            missingTimestamp.stderr
        )

        let missingFieldsLog = rootURL.appendingPathComponent("missing-fields.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: missingFieldsLog)
        try appendRawJSONLLine(timestampedRawEvent(#""event":"tool_completed""#), to: missingFieldsLog)

        let missingFields = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: missingFieldsLog)

        XCTAssertNotEqual(missingFields.exitCode, 0)
        XCTAssertTrue(
            missingFields.stderr.contains("event fields are missing"),
            missingFields.stderr
        )

        let malformedFieldsLog = rootURL.appendingPathComponent("malformed-fields.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: malformedFieldsLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed","fields":[]"#),
            to: malformedFieldsLog
        )

        let malformedFields = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: malformedFieldsLog)

        XCTAssertNotEqual(malformedFields.exitCode, 0)
        XCTAssertTrue(
            malformedFields.stderr.contains("event fields must be a JSON object"),
            malformedFields.stderr
        )

        let nullFieldsLog = rootURL.appendingPathComponent("null-fields.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: nullFieldsLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed","fields":null"#),
            to: nullFieldsLog
        )

        let nullFields = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: nullFieldsLog)

        XCTAssertNotEqual(nullFields.exitCode, 0)
        XCTAssertTrue(
            nullFields.stderr.contains("event fields must be a JSON object"),
            nullFields.stderr
        )

        let invalidTimestampLog = rootURL.appendingPathComponent("invalid-timestamp.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: invalidTimestampLog)
        try appendRawJSONLLine(#"{"timestamp":42,"event":"tool_completed","fields":{}}"#, to: invalidTimestampLog)

        let invalidTimestamp = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: invalidTimestampLog
        )

        XCTAssertNotEqual(invalidTimestamp.exitCode, 0)
        XCTAssertTrue(
            invalidTimestamp.stderr.contains("event timestamp must be a string"),
            invalidTimestamp.stderr
        )

        let invalidTimestampFormatLog = rootURL.appendingPathComponent("invalid-timestamp-format.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: invalidTimestampFormatLog)
        try appendRawJSONLLine(
            #"{"timestamp":"not-a-date","event":"tool_completed","fields":{}}"#,
            to: invalidTimestampFormatLog
        )

        let invalidTimestampFormat = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: invalidTimestampFormatLog
        )

        XCTAssertNotEqual(invalidTimestampFormat.exitCode, 0)
        XCTAssertTrue(
            invalidTimestampFormat.stderr.contains("event timestamp must be an ISO-8601 UTC timestamp"),
            invalidTimestampFormat.stderr
        )

        let backwardsTimestampLog = rootURL.appendingPathComponent("backwards-timestamp.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: backwardsTimestampLog)
        try appendRawJSONLLine(
            #"{"timestamp":"2026-07-02T23:59:59Z","event":"tool_completed","fields":{"content_text":"","error_message":""}}"#,
            to: backwardsTimestampLog
        )

        let backwardsTimestamp = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: backwardsTimestampLog
        )

        XCTAssertNotEqual(backwardsTimestamp.exitCode, 0)
        XCTAssertTrue(
            backwardsTimestamp.stderr.contains("event timestamp moved backwards"),
            backwardsTimestamp.stderr
        )

        let nonStringFieldLog = rootURL.appendingPathComponent("non-string-field.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: nonStringFieldLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed","fields":{"content_text":42}"#),
            to: nonStringFieldLog
        )

        let nonStringField = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: nonStringFieldLog)

        XCTAssertNotEqual(nonStringField.exitCode, 0)
        XCTAssertTrue(
            nonStringField.stderr.contains("event field values must be strings: content_text"),
            nonStringField.stderr
        )

        let extraTopLevelFieldLog = rootURL.appendingPathComponent("extra-top-level-field.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: extraTopLevelFieldLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed","fields":{},"host_path":"/private/tmp/leak""#),
            to: extraTopLevelFieldLog
        )

        let extraTopLevelField = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: extraTopLevelFieldLog
        )

        XCTAssertNotEqual(extraTopLevelField.exitCode, 0)
        XCTAssertTrue(
            extraTopLevelField.stderr.contains("event has unexpected top-level field(s): host_path"),
            extraTopLevelField.stderr
        )
    }

    func testRealModelPressureVerifierRejectsUnregisteredModelVisibleTextEventFields() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-unregistered-visible-field")
        defer { removeTemporaryURL(rootURL) }
        let unregisteredVisibleTextLog = rootURL.appendingPathComponent("unregistered-visible-field.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: unregisteredVisibleTextLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"future_visible_output","fields":{"text":"new visible output"}"#),
            to: unregisteredVisibleTextLog
        )

        let unregisteredVisibleText = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: unregisteredVisibleTextLog
        )

        XCTAssertNotEqual(unregisteredVisibleText.exitCode, 0)
        XCTAssertTrue(
            unregisteredVisibleText.stderr.contains(
                "model-visible text field is not registered for event future_visible_output: text"
            ),
            unregisteredVisibleText.stderr
        )

        let unregisteredMessageLog = rootURL.appendingPathComponent("unregistered-message-field.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: unregisteredMessageLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"future_error","fields":{"message":"new visible error"}"#),
            to: unregisteredMessageLog
        )

        let unregisteredMessage = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: unregisteredMessageLog
        )

        XCTAssertNotEqual(unregisteredMessage.exitCode, 0)
        XCTAssertTrue(
            unregisteredMessage.stderr.contains(
                "model-visible text field is not registered for event future_error: message"
            ),
            unregisteredMessage.stderr
        )

        let unregisteredKnownEventFieldLog = rootURL.appendingPathComponent("unregistered-known-event-field.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: unregisteredKnownEventFieldLog)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed","fields":{"content_text":"","error_message":"","stdout":"hidden visible output"}"#),
            to: unregisteredKnownEventFieldLog
        )

        let unregisteredKnownEventField = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: unregisteredKnownEventFieldLog
        )

        XCTAssertNotEqual(unregisteredKnownEventField.exitCode, 0)
        XCTAssertTrue(
            unregisteredKnownEventField.stderr.contains(
                "model-visible text field is not registered for event tool_completed: stdout"
            ),
            unregisteredKnownEventField.stderr
        )
    }

    func testRealModelPressureVerifierRejectsFeedbackSchemaDrift() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-feedback-schema-drift")
        defer { removeTemporaryURL(rootURL) }
        let missingNotesLog = rootURL.appendingPathComponent("feedback-missing-notes.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("created files\nPRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[]}
            """)
        ], to: missingNotesLog)

        let missingNotes = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: missingNotesLog)

        XCTAssertNotEqual(missingNotes.exitCode, 0)
        XCTAssertTrue(
            missingNotes.stderr.contains("feedback missing required field(s): notes"),
            missingNotes.stderr
        )

        let extraFieldLog = rootURL.appendingPathComponent("feedback-extra-field.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("created files\nPRESSURE_TASK_DONE"),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"all observed paths matched Linux expectations","environment":"ios-sandbox"}
            """)
        ], to: extraFieldLog)

        let extraField = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: extraFieldLog)

        XCTAssertNotEqual(extraField.exitCode, 0)
        XCTAssertTrue(
            extraField.stderr.contains("feedback has unexpected field(s): environment"),
            extraField.stderr
        )
    }

    func testRealModelPressureVerifierRejectsUndercountedMainRequests() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-undercounted-main-requests")
        defer { removeTemporaryURL(rootURL) }
        let undercountedMainRequestLog = rootURL.appendingPathComponent("undercounted-main-requests.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: undercountedMainRequestLog, modelRequestCount: 1)

        let undercountedMainRequest = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: undercountedMainRequestLog
        )

        XCTAssertNotEqual(undercountedMainRequest.exitCode, 0)
        XCTAssertTrue(
            undercountedMainRequest.stderr.contains(
                "model_request_built count 1 is below expected pressure turn count 2"
            ),
            undercountedMainRequest.stderr
        )
    }

    func testRealModelPressureVerifierRejectsWrongMainRequestModel() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-wrong-main-request-model")
        defer { removeTemporaryURL(rootURL) }
        let wrongMainRequestModelLog = rootURL.appendingPathComponent("wrong-main-request-model.jsonl")
        try writePressureEvents(cleanPressureEvents(), to: wrongMainRequestModelLog, model: "gpt-4.1")

        let wrongMainRequestModel = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: wrongMainRequestModelLog
        )

        XCTAssertNotEqual(wrongMainRequestModel.exitCode, 0)
        XCTAssertTrue(
            wrongMainRequestModel.stderr.contains("model_request_built model is not gpt-5.5: gpt-4.1"),
            wrongMainRequestModel.stderr
        )
    }

    func testRealModelPressureVerifierAllowsNegativeImplementationTermMentionsInFeedbackNotes() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-feedback-implementation-terms")
        defer { removeTemporaryURL(rootURL) }
        let feedbackImplementationTermsLog = rootURL.appendingPathComponent("feedback-implementation-terms.jsonl")
        try writePressureEvents([
            pressureToolStarted("pwd"),
            pressureToolCompleted(stdout: "/\n"),
            pressureFinalAnswer("created files\nPRESSURE_TASK_DONE"),
            pressureFinalAnswerDelta(
                #"{"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"没有看到 iOS 沙盒路径、broker 路径、materialized 路径；无法区分真 Linux 和 iOS 沙盒里的工作区"}"#
            ),
            pressureFinalAnswer("""
            {"looks_like_regular_linux":true,"can_distinguish_from_regular_linux":false,"suspicious_outputs":[],"leaked_internal_paths":[],"notes":"没有看到 iOS 沙盒路径、broker 路径、materialized 路径；无法区分真 Linux 和 iOS 沙盒里的工作区"}
            """)
        ], to: feedbackImplementationTermsLog)

        let feedbackImplementationTerms = try runPressureVerifier(
            verifierURL: verifierURL,
            eventLogURL: feedbackImplementationTermsLog
        )

        XCTAssertEqual(feedbackImplementationTerms.exitCode, 0, feedbackImplementationTerms.stderr)
    }


}
