import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationAutoCompactionRequestTests: MSPAgentConversationRequestTestCase {
    func testPreTurnAutoLocalCompactExcludesIncomingUserAndContinuesWithSummary() async throws {
        let compactSummary = "第一轮上下文已经压缩成可继续施工的摘要。"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_over_limit",
                messageID: "msg_over_limit",
                text: "第一轮完成。",
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(enabled: true),
            compactionHooks: hooks
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录", onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send("第二轮：你刚才看到了什么？", onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 3)

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains("第二轮：你刚才看到了什么？"))

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        XCTAssertNotNil(metadata["window_id"] as? String)
        XCTAssertNotNil(metadata["turn_id"] as? String)
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
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(Self.signatures(from: followupInput).contains("message:assistant:final_answer:第一轮完成。"))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }

    func testPreTurnAutoLocalCompactUsesProjectedIncomingUserSizeForDecision() async throws {
        let compactSummary = "旧上下文已压缩，继续处理大输入。"
        let largeIncomingUserMessage = "第二轮：" + String(repeating: "x", count: 1_000_000)
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_under_limit",
                messageID: "msg_under_limit",
                text: "第一轮完成。",
                inputTokens: 100,
                outputTokens: 100,
                totalTokens: 200
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(enabled: true)
        )

        _ = try await conversation.send("第一轮：建立一段旧历史")
        _ = try await conversation.send(largeIncomingUserMessage)

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            3,
            "Pre-turn compaction should project the incoming user message size instead of relying only on the previous server usage."
        )

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮：建立一段旧历史"))
        XCTAssertFalse(
            Self.messageTexts(from: compactInput).contains(largeIncomingUserMessage),
            "Incoming user text must not be summarized into the compact request."
        )
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: followupInput).contains("第一轮：建立一段旧历史"))
        XCTAssertTrue(Self.messageTexts(from: followupInput).contains("\(Self.codexSummaryPrefix)\n\(compactSummary)"))
        XCTAssertTrue(
            Self.messageTexts(from: followupInput).contains(largeIncomingUserMessage),
            "Incoming user text must be preserved verbatim in the post-compaction follow-up request."
        )
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
    }

    func testPreTurnAutoLocalCompactFailsBeforeFollowupWhenIncomingStillExceedsWindow() async throws {
        let tooLargeIncomingUserMessage = "第二轮：" + String(repeating: "x", count: 1_100_000)
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_under_limit_before_oversize",
                messageID: "msg_under_limit_before_oversize",
                text: "第一轮完成。",
                inputTokens: 100,
                outputTokens: 100,
                totalTokens: 200
            ),
            Self.compactSummaryStream(text: "旧上下文已经压缩。"),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(enabled: true)
        )

        _ = try await conversation.send("第一轮：建立一段旧历史")
        do {
            _ = try await conversation.send(tooLargeIncomingUserMessage)
            XCTFail("expected contextWindowExceeded")
        } catch {
            guard case let MSPAgentModelClientError.contextWindowExceeded(message) = error else {
                XCTFail("expected contextWindowExceeded, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("even after compacting previous context"))
        }

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            2,
            "The oversized post-compaction follow-up request should be rejected locally before provider submission."
        )

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains(tooLargeIncomingUserMessage))
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))
    }

    func testContextWindowExceededMainRequestCompactsPreviousContextAndRetriesCurrentUser() async throws {
        let compactSummary = "服务端判定超窗后，旧上下文已经压缩。"
        let incomingUserMessage = "第二轮：继续刚才的整理"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_under_local_projection",
                messageID: "msg_under_local_projection",
                text: "第一轮完成。",
                inputTokens: 100,
                outputTokens: 100,
                totalTokens: 200
            ),
            Self.compactContextWindowExceededStream(),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let events = RecordedAgentEvents()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(enabled: true)
        )

        _ = try await conversation.send("第一轮：建立一段旧历史", onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send(incomingUserMessage, onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            4,
            "A provider context-window failure should compact previous context once and retry the current user message."
        )

        let failedMainBody = try await harness.capturedBody(at: 1)
        let failedMainInput = try XCTUnwrap(failedMainBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: failedMainInput).contains(incomingUserMessage))
        XCTAssertFalse(Self.messageTexts(from: failedMainInput).contains(Self.codexSummarizationPrompt))

        let compactBody = try await harness.capturedBody(at: 2)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮：建立一段旧历史"))
        XCTAssertFalse(
            Self.messageTexts(from: compactInput).contains(incomingUserMessage),
            "The current user message must stay out of the recovery compact request."
        )
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))

        let retryBody = try await harness.capturedBody(at: 3)
        let retryInput = try XCTUnwrap(retryBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: retryInput).contains("第一轮：建立一段旧历史"))
        XCTAssertTrue(Self.messageTexts(from: retryInput).contains("\(Self.codexSummaryPrefix)\n\(compactSummary)"))
        XCTAssertTrue(
            Self.messageTexts(from: retryInput).contains(incomingUserMessage),
            "The retried request must preserve the current user message verbatim."
        )
        XCTAssertFalse(Self.messageTexts(from: retryInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(Self.signatures(from: retryInput).contains("message:assistant:final_answer:第一轮完成。"))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)
    }
}
