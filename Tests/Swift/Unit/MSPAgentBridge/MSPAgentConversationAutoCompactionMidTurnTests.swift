import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


extension MSPAgentConversationAutoCompactionRequestTests {
    func testMidTurnAutoLocalCompactRunsBeforeToolContinuation() async throws {
        let compactSummary = "中途工具结果已经压缩，继续同一轮回答。"
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStreamWithUsage(
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

        _ = try await conversation.send("第一轮：触发中途压缩", onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 3)

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：触发中途压缩",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_1",
            "function_call_output:call_1:exec_output;exit=0;output=/\n",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        XCTAssertNotNil(metadata["window_id"] as? String)
        XCTAssertNotNil(metadata["turn_id"] as? String)
        let compaction = try XCTUnwrap(metadata["compaction"] as? [String: Any])
        XCTAssertEqual(compaction["trigger"] as? String, "auto")
        XCTAssertEqual(compaction["reason"] as? String, "context_limit")
        XCTAssertEqual(compaction["implementation"] as? String, "responses")
        XCTAssertEqual(compaction["phase"] as? String, "mid_turn")
        XCTAssertEqual(compaction["strategy"] as? String, "memento")

        let continuationBody = try await harness.capturedBody(at: 2)
        let continuationInput = try XCTUnwrap(continuationBody["input"] as? [[String: Any]])
        let continuationSignatures = Self.signatures(from: continuationInput)
        XCTAssertEqual(continuationSignatures, [
            "message:developer",
            "message:user:第一轮：触发中途压缩",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)"
        ])
        XCTAssertFalse(continuationSignatures.contains("function_call:exec_command:call_1"))
        XCTAssertFalse(continuationSignatures.contains {
            $0.hasPrefix("function_call_output:call_1:")
        })
        XCTAssertFalse(Self.messageTexts(from: continuationInput).contains(Self.codexSummarizationPrompt))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }

    func testMidTurnBodyAfterPrefixCompactsWhenLatestCurrentUsageCrossesThreshold() async throws {
        let compactSummary = "最新上下文窗口占用已经接近上限，中途先压缩再继续。"
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_prefill_baseline",
                messageID: "msg_prefill_baseline",
                text: "第一轮完成。",
                inputTokens: 100_000,
                outputTokens: 20,
                totalTokens: 100_020
            ),
            Self.firstTurnToolCallStreamWithUsage(
                inputTokens: 120_000,
                outputTokens: 135_100,
                totalTokens: 255_100
            ),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            ),
            compactionHooks: hooks
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：建立较大的窗口前缀")
        _ = try await conversation.send("第二轮：工具调用后上下文窗口已经到 94%", onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        XCTAssertEqual(
            requestCount,
            4,
            "A mid-turn follow-up must compact when latest context usage is already over the auto compact threshold, even if an older body-after-prefix baseline exists."
        )

        let compactBody = try await harness.capturedBody(at: 2)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：建立较大的窗口前缀",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：工具调用后上下文窗口已经到 94%",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_1",
            "function_call_output:call_1:exec_output;exit=0;output=/\n",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        let compaction = try XCTUnwrap(metadata["compaction"] as? [String: Any])
        XCTAssertEqual(compaction["trigger"] as? String, "auto")
        XCTAssertEqual(compaction["phase"] as? String, "mid_turn")

        let continuationBody = try await harness.capturedBody(at: 3)
        let continuationInput = try XCTUnwrap(continuationBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: continuationInput), [
            "message:developer",
            "message:user:第一轮：建立较大的窗口前缀",
            "message:user:第二轮：工具调用后上下文窗口已经到 94%",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)"
        ])
        XCTAssertFalse(Self.messageTexts(from: continuationInput).contains(Self.codexSummarizationPrompt))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }
}
