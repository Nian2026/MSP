import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationRemoteCompactionTests: MSPAgentConversationRequestTestCase {
    func testPreTurnAutoGenericProviderFallsBackToLocalResponsesWhenRemoteEnabled() async throws {
        let compactSummary = "Generic provider must use local summarization."
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_generic_preturn_over_limit",
                messageID: "msg_generic_preturn_over_limit",
                text: "第一轮完成。",
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            providerName: "Example",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                remoteCompactionEnabled: true
            )
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录", onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send("第二轮：继续", onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        let firstPath = await harness.capturedPath(at: 0)
        let compactPath = await harness.capturedPath(at: 1)
        let followupPath = await harness.capturedPath(at: 2)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(firstPath, "/v1/responses")
        XCTAssertEqual(compactPath, "/v1/responses")
        XCTAssertEqual(followupPath, "/v1/responses")

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains("第二轮：继续"))
        XCTAssertFalse(compactInput.contains { $0["type"] as? String == "compaction_trigger" })

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        let compaction = try XCTUnwrap(metadata["compaction"] as? [String: Any])
        XCTAssertEqual(compaction["trigger"] as? String, "auto")
        XCTAssertEqual(compaction["reason"] as? String, "context_limit")
        XCTAssertEqual(compaction["implementation"] as? String, "responses")
        XCTAssertEqual(compaction["phase"] as? String, "pre_turn")
        XCTAssertEqual(compaction["strategy"] as? String, "memento")

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: followupInput), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "message:user:第二轮：继续"
        ])
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(followupInput.contains { $0["type"] as? String == "compaction_trigger" })

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)
    }
}
