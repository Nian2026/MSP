import Foundation
import XCTest

extension ModelShellProxyPressureLogVerifierConformanceTests {
    func testRealModelPressureVerifierRejectsMissingFinalAnswerModelResponseProvenance() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-missing-final-answer-provenance")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("missing-provenance.jsonl")
        try writePressureEvents(
            cleanPressureEvents(),
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].response_id is missing"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsForgedFinalAnswerModelResponseProvenance() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-forged-final-answer-provenance")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("forged-provenance.jsonl")
        var events = pressureEventsWithModelResponseProvenance(cleanPressureEvents())
        if let index = events.firstIndex(where: { ($0["event"] as? String) == "final_answer" }) {
            var event = events[index]
            var fields = event["fields"] as? [String: Any] ?? [:]
            fields["response_id"] = "resp_forged_final_answer"
            event["fields"] = fields
            events[index] = event
        }
        try writePressureEvents(
            events,
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].response_id does not match provenance event"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsForgedFinalAnswerModelRequestProvenance() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-forged-final-answer-request-provenance")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("forged-request-provenance.jsonl")
        var events = pressureEventsWithModelResponseProvenance(cleanPressureEvents())
        if let index = events.firstIndex(where: { ($0["event"] as? String) == "final_answer" }) {
            var event = events[index]
            var fields = event["fields"] as? [String: Any] ?? [:]
            fields["model_request_sequence"] = "999"
            event["fields"] = fields
            events[index] = event
        }
        try writePressureEvents(
            events,
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].model_request ref was not previously built"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].model_request_sequence does not match provenance event"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsForgedFinalAnswerProvenanceTextLength() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-forged-final-answer-provenance-text-length")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("forged-provenance-text-length.jsonl")
        var events = pressureEventsWithModelResponseProvenance(cleanPressureEvents())
        if let index = events.firstIndex(where: { ($0["event"] as? String) == "final_answer" }) {
            var event = events[index]
            var fields = event["fields"] as? [String: Any] ?? [:]
            fields["provenance_text_length"] = "999"
            event["fields"] = fields
            events[index] = event
        }
        try writePressureEvents(
            events,
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].provenance_text_length does not match provenance event"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsForgedFinalAnswerTextHash() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-forged-final-answer-text-hash")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("forged-final-answer-text-hash.jsonl")
        var events = pressureEventsWithModelResponseProvenance(cleanPressureEvents())
        if let index = events.firstIndex(where: { ($0["event"] as? String) == "final_answer" }) {
            var event = events[index]
            var fields = event["fields"] as? [String: Any] ?? [:]
            fields["text"] = "forged final answer text with stale hash\nPRESSURE_TASK_DONE"
            event["fields"] = fields
            events[index] = event
        }
        try writePressureEvents(
            events,
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].text_sha256 does not match text"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsForgedFinalAnswerProvenanceTextHash() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-forged-final-answer-provenance-text-hash")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("forged-provenance-text-hash.jsonl")
        var events = pressureEventsWithModelResponseProvenance(cleanPressureEvents())
        if let index = events.firstIndex(where: { ($0["event"] as? String) == "final_answer" }) {
            var event = events[index]
            var fields = event["fields"] as? [String: Any] ?? [:]
            fields["provenance_text_sha256"] = String(repeating: "0", count: 64)
            event["fields"] = fields
            events[index] = event
        }
        try writePressureEvents(
            events,
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].provenance_text_sha256 does not match provenance event"),
            failed.stderr
        )
    }

    func testRealModelPressureVerifierRejectsNonRuntimeProviderModelRequestLayer() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for pressure verifier tests.")
        }

        let verifierURL = try pressureLogVerifierURL()
        let rootURL = makeTemporaryURL("pressure-verifier-non-runtime-provider-layer")
        defer { removeTemporaryURL(rootURL) }
        let cleanLog = rootURL.appendingPathComponent("non-runtime-provider-layer.jsonl")
        var events = pressureEventsWithModelResponseProvenance(cleanPressureEvents())
        for index in events.indices {
            guard [
                "model_response_completed",
                "model_final_answer_provenance",
                "final_answer"
            ].contains(events[index]["event"] as? String) else {
                continue
            }
            var fields = events[index]["fields"] as? [String: Any] ?? [:]
            fields["model_request_layer"] = "app_turn_submission"
            events[index]["fields"] = fields
        }
        try writePressureEvents(
            events,
            to: cleanLog,
            includeModelResponseProvenance: false
        )

        let failed = try runPressureVerifier(verifierURL: verifierURL, eventLogURL: cleanLog)

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("model_response_completed[1].model_request_layer is not runtime_provider"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("final_answer[1].model_request_layer is not runtime_provider"),
            failed.stderr
        )
    }
}
