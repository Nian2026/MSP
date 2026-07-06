import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


extension MSPAgentConversationAutoCompactionRequestTests {
    func testManualTokenBudgetCompactStartsFreshContextWindowWithoutModelRequest() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let persistence = RecordingCompactionPersistenceAdapter()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenBudgetFeatureEnabled: true
            ),
            compactionHooks: hooks,
            compactionPersistenceAdapter: persistence
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let requestCountBeforeCompact = await harness.requestCount()
        XCTAssertEqual(requestCountBeforeCompact, 1)

        let compactResult = try await conversation.compact(onEvent: { event in
            await events.append(event)
        })
        XCTAssertNil(compactResult.responseID)
        let requestCountAfterCompact = await harness.requestCount()
        XCTAssertEqual(requestCountAfterCompact, 1)

        let compactUsage = try XCTUnwrap(compactResult.contextUsage)
        XCTAssertGreaterThan(compactUsage.currentTokens, 0)
        XCTAssertEqual(compactUsage.estimatedInputTokens, compactUsage.currentTokens)
        XCTAssertNil(compactUsage.serverInputTokens)
        XCTAssertNil(compactUsage.serverOutputTokens)
        XCTAssertNil(compactUsage.serverTotalTokens)

        _ = try await conversation.send("第二轮：你刚才看到了什么？")
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 2)
        guard requestCount >= 2 else { return }

        let followupBody = try await harness.capturedBody(at: 1)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: followupInput), [
            "message:developer",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains { text in
            text.hasPrefix(Self.codexSummaryPrefix)
        })

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)

        let checkpoints = await persistence.checkpoints()
        XCTAssertEqual(checkpoints.count, 1)
        let checkpoint = try XCTUnwrap(checkpoints.first)
        XCTAssertEqual(checkpoint.replayMode, .exact)
        XCTAssertNotNil(checkpoint.sourceRange.sourceHash)
        XCTAssertNotNil(checkpoint.replacementHistoryHash)
        XCTAssertEqual(checkpoint.lineage.windowNumber, 1)
        XCTAssertEqual(checkpoint.lineage.firstWindowID, checkpoint.lineage.previousWindowID)
        XCTAssertNotEqual(checkpoint.lineage.currentWindowID, checkpoint.lineage.previousWindowID)
        let replacementHistory = try XCTUnwrap(checkpoint.replacementHistory)
        let replacementObjects = try replacementHistory.map { value -> [String: Any] in
            try XCTUnwrap(value.jsonObject as? [String: Any])
        }
        XCTAssertEqual(Self.signatures(from: replacementObjects), [
            "message:developer"
        ])
    }

    func testPreTurnAutoTokenBudgetStartsFreshContextWindowWithoutSummaryRequest() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_over_limit",
                messageID: "msg_over_limit",
                text: "第一轮完成。",
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenBudgetFeatureEnabled: true
            ),
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
        XCTAssertEqual(requestCount, 2)
        guard requestCount >= 2 else { return }

        let followupBody = try await harness.capturedBody(at: 1)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: followupInput), [
            "message:developer",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains("第一轮：看看当前目录"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(Self.signatures(from: followupInput).contains("message:assistant:final_answer:第一轮完成。"))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }

    func testMidTurnAutoTokenBudgetStartsFreshContextWindowBeforeContinuation() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStreamWithUsage(
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenBudgetFeatureEnabled: true
            ),
            compactionHooks: hooks
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：触发中途 token-budget 重置", onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 2)
        guard requestCount >= 2 else { return }

        let continuationBody = try await harness.capturedBody(at: 1)
        let continuationInput = try XCTUnwrap(continuationBody["input"] as? [[String: Any]])
        let continuationSignatures = Self.signatures(from: continuationInput)
        XCTAssertEqual(continuationSignatures, [
            "message:developer"
        ])
        XCTAssertFalse(continuationSignatures.contains("message:user:第一轮：触发中途 token-budget 重置"))
        XCTAssertFalse(continuationSignatures.contains("function_call:exec_command:call_1"))
        XCTAssertFalse(continuationSignatures.contains {
            $0.hasPrefix("function_call_output:call_1:")
        })
        XCTAssertFalse(Self.messageTexts(from: continuationInput).contains(Self.codexSummarizationPrompt))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }
}
