import XCTest
@testable import MSPChat

final class MSPChatValidatorTests: XCTestCase {
    func testGoodSamplesPass() throws {
        for name in [
            "pure-chat.chat",
            "assistant-progress.chat",
            "interleaved-command.chat",
            "command-parse-error.chat",
            "permission-denied.chat",
            "non-zero-exit.chat",
            "long-output-truncation.chat",
            "artifact-blob-refs.chat",
            "redacted-artifact.chat",
            "skipped-stage.chat",
            "runtime-journal.chat",
            "lossy-import-marker.chat",
            "unknown-preserved.chat",
            "context-control.chat"
        ] {
            let report = validate("good/\(name)")
            XCTAssertTrue(report.isValid, "\(name) should pass:\n\(report.renderedText())")
        }
    }

    func testBadSamplesFailWithSpecificDiagnostics() throws {
        let cases: [(String, String)] = [
            ("bad/missing-manifest.chat", "missing-manifest"),
            ("bad/out-of-order-seq.chat", "timeline-seq-order"),
            ("bad/command-output-before-call.chat", "command-output-before-call"),
            ("bad/pipefail-negation-mismatch.chat", "command-exit-formula"),
            ("bad/stale-projection.chat", "projection-range-beyond-timeline"),
            ("bad/compaction-missing-source.chat", "compaction-source-range"),
            ("bad/missing-artifact.chat", "artifact-path-missing"),
            ("bad/blob-hash-mismatch.chat", "artifact-hash-mismatch"),
            ("bad/unsafe-artifact-path.chat", "artifact-path-unsafe"),
            ("bad/markdown-only-projection.chat", "markdown-only-projection"),
            ("bad/tool-output-before-call.chat", "tool-output-before-call"),
            ("bad/scope-bound-cursor.chat", "projection-cursor-self-description"),
            ("bad/synthetic-replay-missing-marker.chat", "projection-synthetic-marker"),
            ("bad/inserted-aborted-output-missing-policy.chat", "projection-call-output-balance-policy"),
            ("bad/stdout-stderr-order.chat", "command-stream-order"),
            ("bad/fork-missing-source.chat", "fork-source-package"),
            ("bad/continuation-handle-in-core.chat", "continuation-handle-in-core"),
            ("bad/continuation-handle-invalidated.chat", "continuation-handle-invalidated-reason"),
            ("bad/cold-history-no-materialize.chat", "cold-history-materialize-before-append"),
            ("bad/stale-index.chat", "index-range-beyond-timeline"),
            ("bad/lossy-missing-detail.chat", "lossy-marker-detail")
        ]

        for (sample, expectedCode) in cases {
            let report = validate(sample)
            XCTAssertFalse(report.isValid, "\(sample) should fail")
            XCTAssertTrue(
                report.diagnostics.contains { $0.code == expectedCode && $0.severity == .error },
                "\(sample) should include \(expectedCode), got:\n\(report.renderedText())"
            )
        }
    }

    func testJSONReportIsCodable() throws {
        let report = validate("good/interleaved-command.chat")
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MSPChatValidationReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    func testDiagnosticLocationFieldsAndNDJSONLineNumbersAreStable() throws {
        let packageURL = try makeTemporaryPackageURL(named: "line-fields.chat")
        try writeValidationPackage(
            at: packageURL,
            timeline: "\r\n   \r\n{\"id\":\"evt_bad_message\",\"type\":\"message\",\"seq\":1,\"created_at\":\"2026-06-30T01:00:00Z\",\"durability\":\"durable_replay\",\"payload\":{}}\r\n"
        )

        let report = MSPChatValidator().validate(packageAt: packageURL)
        let diagnostic = try XCTUnwrap(report.diagnostics.first { $0.code == "message-role" })

        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.message, "message payload requires role.")
        XCTAssertEqual(diagnostic.path, "timeline.ndjson")
        XCTAssertEqual(diagnostic.line, 3)
        XCTAssertEqual(diagnostic.eventID, "evt_bad_message")
    }

    private func validate(_ relativeSamplePath: String) -> MSPChatValidationReport {
        MSPChatValidator().validate(packageAt: samplesRoot().appendingPathComponent(relativeSamplePath))
    }

    private func samplesRoot() -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("Spec/Chat/Samples")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        XCTFail("Could not locate Spec/Chat/Samples from \(#filePath)")
        return URL(fileURLWithPath: "/")
    }

    private func makeTemporaryPackageURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPChatValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func writeValidationPackage(at packageURL: URL, timeline: String) throws {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let manifest = """
        {
          "format": "msp.chat",
          "version": 1,
          "profiles": ["core-timeline"],
          "capabilities": ["read_core"],
          "timeline": {
            "path": "timeline.ndjson",
            "record_format": "ndjson"
          }
        }
        """
        try manifest.write(to: packageURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try timeline.write(to: packageURL.appendingPathComponent("timeline.ndjson"), atomically: true, encoding: .utf8)
    }
}
