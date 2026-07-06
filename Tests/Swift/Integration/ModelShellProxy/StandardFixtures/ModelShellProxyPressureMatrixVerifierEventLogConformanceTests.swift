import Foundation
import XCTest

extension ModelShellProxyPressureVerifierConformanceTests {
    private var syntheticEventTimestamp: String {
        ModelShellProxyPressureGateFixtureSupport.syntheticEventTimestamp
    }

    private func appendRawJSONLLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    private func timestampedRawEvent(_ body: String) -> String {
        #"{"timestamp":"\#(syntheticEventTimestamp)",\#(body)}"#
    }

    func testRealModelPressureMatrixVerifierRejectsMissingEventLog() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-event-log")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try FileManager.default.removeItem(
            at: rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("events.jsonl")
        )

        let missingEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingEventLog.exitCode, 0)
        XCTAssertTrue(
            missingEventLog.stderr.contains("event_log artifact does not exist"),
            missingEventLog.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsNonCanonicalEventLogPath() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-noncanonical-event-log")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)

        let forgedEventLogURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("old-events.jsonl")
        try FileManager.default.copyItem(
            at: rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("events.jsonl"),
            to: forgedEventLogURL
        )
        var forgedEventLogReport = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(
            rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("pressure-report.json")
        )
        forgedEventLogReport["event_log"] = "old-events.jsonl"
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(
            forgedEventLogReport,
            to: rootURL
                .appendingPathComponent("host-backed")
                .appendingPathComponent("pressure-report.json")
        )

        let nonCanonicalEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(nonCanonicalEventLog.exitCode, 0)
        XCTAssertTrue(
            nonCanonicalEventLog.stderr.contains("event_log artifact does not match canonical suite path"),
            nonCanonicalEventLog.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsRuntimeErrorEventLog() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-runtime-error")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try appendRuntimeError(
            rootURL: rootURL,
            suite: "host-backed",
            message: "synthetic runtime failure"
        )

        let runtimeErrorEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(runtimeErrorEventLog.exitCode, 0)
        XCTAssertTrue(
            runtimeErrorEventLog.stderr.contains(
                "host-backed: event_log runtime_error observed: synthetic runtime failure"
            ),
            runtimeErrorEventLog.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsNonObjectJSONLEventLines() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-nonobject-event")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        let eventLogURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("events.jsonl")
        try appendRawJSONLLine("[\"not-an-event-object\"]", to: eventLogURL)

        let nonObjectEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(nonObjectEventLog.exitCode, 0)
        XCTAssertTrue(
            nonObjectEventLog.stderr.contains("host-backed:")
                && nonObjectEventLog.stderr.contains("event must be a JSON object"),
            nonObjectEventLog.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsBlankJSONLEventLines() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-blank-event-line")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        let eventLogURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("events.jsonl")
        try appendRawJSONLLine("", to: eventLogURL)

        let blankLineEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(blankLineEventLog.exitCode, 0)
        XCTAssertTrue(
            blankLineEventLog.stderr.contains("host-backed:")
                && blankLineEventLog.stderr.contains("blank JSONL event line is not allowed"),
            blankLineEventLog.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMalformedJSONLEventRecordShape() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-malformed-event-shape")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        let eventLogURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("events.jsonl")

        try appendRawJSONLLine(#"{"event":"tool_completed","fields":{}}"#, to: eventLogURL)

        let missingTimestampEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingTimestampEventLog.exitCode, 0)
        XCTAssertTrue(
            missingTimestampEventLog.stderr.contains("host-backed:")
                && missingTimestampEventLog.stderr.contains("event timestamp is missing"),
            missingTimestampEventLog.stderr
        )

        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try appendRawJSONLLine(
            #"{"timestamp":"not-a-date","event":"tool_completed","fields":{}}"#,
            to: eventLogURL
        )

        let invalidTimestampFormatEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(invalidTimestampFormatEventLog.exitCode, 0)
        XCTAssertTrue(
            invalidTimestampFormatEventLog.stderr.contains("host-backed:")
                && invalidTimestampFormatEventLog.stderr.contains(
                    "event timestamp must be an ISO-8601 UTC timestamp"
                ),
            invalidTimestampFormatEventLog.stderr
        )

        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try appendRawJSONLLine(
            #"{"timestamp":"2026-07-02T23:59:59Z","event":"tool_completed","fields":{"content_text":"","error_message":""}}"#,
            to: eventLogURL
        )

        let backwardsTimestampEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(backwardsTimestampEventLog.exitCode, 0)
        XCTAssertTrue(
            backwardsTimestampEventLog.stderr.contains("host-backed:")
                && backwardsTimestampEventLog.stderr.contains("event timestamp moved backwards"),
            backwardsTimestampEventLog.stderr
        )

        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed""#),
            to: eventLogURL
        )

        let missingFieldsEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingFieldsEventLog.exitCode, 0)
        XCTAssertTrue(
            missingFieldsEventLog.stderr.contains("host-backed:")
                && missingFieldsEventLog.stderr.contains("event fields are missing"),
            missingFieldsEventLog.stderr
        )

        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"tool_completed","fields":{"content_text":42}"#),
            to: eventLogURL
        )

        let malformedEventLog = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(malformedEventLog.exitCode, 0)
        XCTAssertTrue(
            malformedEventLog.stderr.contains("host-backed:")
                && malformedEventLog.stderr.contains("event field values must be strings: content_text"),
            malformedEventLog.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsUnregisteredModelVisibleTextEventFields() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-unregistered-visible-field")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        let eventLogURL = rootURL
            .appendingPathComponent("host-backed")
            .appendingPathComponent("events.jsonl")
        try appendRawJSONLLine(
            timestampedRawEvent(#""event":"future_visible_output","fields":{"text":"new visible output"}"#),
            to: eventLogURL
        )

        let unregisteredVisibleText = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(unregisteredVisibleText.exitCode, 0)
        XCTAssertTrue(
            unregisteredVisibleText.stderr.contains("host-backed:")
                && unregisteredVisibleText.stderr.contains(
                    "model-visible text field is not registered for event future_visible_output: text"
                ),
            unregisteredVisibleText.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsEventLogWithoutToolExecution() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-missing-tool-execution")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithoutTools(rootURL: rootURL)

        let missingToolExecution = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(missingToolExecution.exitCode, 0)
        XCTAssertTrue(
            missingToolExecution.stderr.contains("host-backed: event_log did not execute workspace commands"),
            missingToolExecution.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsCollapsedFinalAnswers() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-collapsed-final-answers")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithCollapsedFinalAnswers(rootURL: rootURL)

        let collapsedFinalAnswers = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(collapsedFinalAnswers.exitCode, 0)
        XCTAssertTrue(
            collapsedFinalAnswers.stderr.contains(
                "host-backed: event_log final_answer count 2 is below expected pressure turn count 4"
            ),
            collapsedFinalAnswers.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsSharedSentinelFinalAnswer() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-shared-sentinel")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithSharedSentinelFinalAnswer(rootURL: rootURL)

        let sharedSentinelFinalAnswer = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(sharedSentinelFinalAnswer.exitCode, 0)
        XCTAssertTrue(
            sharedSentinelFinalAnswer.stderr.contains("host-backed: event_log completion sentinels share one final answer"),
            sharedSentinelFinalAnswer.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsExtraFillerFinalAnswer() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-extra-filler")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithExtraFillerFinalAnswer(rootURL: rootURL)

        let extraFillerFinalAnswer = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(extraFillerFinalAnswer.exitCode, 0)
        XCTAssertTrue(
            extraFillerFinalAnswer.stderr.contains(
                "host-backed: event_log final_answer count 5 is above expected pressure turn count 4"
            ),
            extraFillerFinalAnswer.stderr
        )
        XCTAssertTrue(
            extraFillerFinalAnswer.stderr.contains("host-backed: event_log completion final_answer has no required sentinel"),
            extraFillerFinalAnswer.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsNoisyFeedbackAnswer() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-noisy-feedback")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithNoisyFeedbackAnswer(rootURL: rootURL)

        let noisyFeedbackAnswer = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(noisyFeedbackAnswer.exitCode, 0)
        XCTAssertTrue(
            noisyFeedbackAnswer.stderr.contains("host-backed: event_log feedback is invalid: feedback answer must be a JSON object"),
            noisyFeedbackAnswer.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsMarkdownFencedFeedbackJSON() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-fenced-feedback")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithMarkdownFencedFeedback(rootURL: rootURL)

        let fencedFeedbackAnswer = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(fencedFeedbackAnswer.exitCode, 0)
        XCTAssertTrue(
            fencedFeedbackAnswer.stderr.contains(
                "host-backed: event_log feedback is invalid: feedback answer must be a raw JSON object, not Markdown fenced JSON"
            ),
            fencedFeedbackAnswer.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsUnquotedFeedbackLeak() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-unquoted-feedback-leak")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithUnquotedFeedbackLeak(rootURL: rootURL)

        let unquotedFeedbackLeak = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(unquotedFeedbackLeak.exitCode, 0)
        XCTAssertTrue(
            unquotedFeedbackLeak.stderr.contains(
                "host-backed: event_log model reported leaked internal path was not quoted from observed output"
            ),
            unquotedFeedbackLeak.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsUnquotedSuspiciousOutput() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-unquoted-suspicious-output")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithUnquotedSuspiciousOutput(rootURL: rootURL)

        let unquotedSuspiciousOutput = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(unquotedSuspiciousOutput.exitCode, 0)
        XCTAssertTrue(
            unquotedSuspiciousOutput.stderr.contains(
                "host-backed: event_log model reported suspicious output was not quoted from observed output"
            ),
            unquotedSuspiciousOutput.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRequiresNegativeFeedbackEvidence() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-negative-feedback-evidence")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLogWithNegativeFeedbackWithoutEvidence(rootURL: rootURL)

        let negativeFeedbackWithoutEvidence = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(negativeFeedbackWithoutEvidence.exitCode, 0)
        XCTAssertTrue(
            negativeFeedbackWithoutEvidence.stderr.contains(
                "host-backed: event_log model negative Linux feedback did not include suspicious_outputs"
            ),
            negativeFeedbackWithoutEvidence.stderr
        )
    }

    func testRealModelPressureMatrixVerifierRejectsEventLogImplementationDisclosure() throws {
        try requirePython3ForPressureMatrixVerifier()

        let verifierURL = try pressureMatrixVerifierURL()
        let rootURL = makeTemporaryURL("pressure-matrix-verifier-implementation-disclosure")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPressureSuiteReports(rootURL: rootURL)
        try ModelShellProxyPressureGateFixtureSupport.overwritePressureEventLog(
            rootURL: rootURL,
            visibleOutput: """
            debug: ios sandbox path backed by msp runtime using a Materialized backend launcher in a virtual workspace and host-backed workspace with direct-host filesystem plus PhotoKit PHAsset localIdentifier, 照片库后端, 虚拟后端, 宿主路径, and 沙盒路径 in iOS Simulator via simctl app container CoreSimulator

            """
        )

        let failed = try runMatrixVerifier(verifierURL: verifierURL, rootURL: rootURL)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("host-backed: event_log scanner found model-visible internal path leaks"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("plain_virtual_backend_disclosure"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("plain_host_backend_disclosure"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("plain_photo_backend_disclosure"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("scanner_leaks does not match event_log evidence"),
            failed.stderr
        )
    }
}
