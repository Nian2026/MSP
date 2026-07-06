import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationCompactionRequestTests: MSPAgentConversationRequestTestCase {
    func testManualLocalCompactBuildsCompactionRequestAndInstallsReplacementHistory() async throws {
        let compactSummary = "任务已经完成第一轮，并保留用户原始目标。"
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        _ = try await conversation.compactLocal(onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send("第二轮：你刚才看到了什么？")

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        let compactSignatures = Self.signatures(from: compactInput)
        XCTAssertEqual(compactSignatures, [
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
        XCTAssertEqual(compaction["trigger"] as? String, "manual")
        XCTAssertEqual(compaction["reason"] as? String, "user_requested")
        XCTAssertEqual(compaction["implementation"] as? String, "responses")
        XCTAssertEqual(compaction["phase"] as? String, "standalone_turn")
        XCTAssertEqual(compaction["strategy"] as? String, "memento")

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let followupSignatures = Self.signatures(from: followupInput)
        XCTAssertEqual(followupSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(followupSignatures.contains("message:assistant:final_answer:第一轮完成。"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        Self.assertDeveloperPromptIsWorkspaceNative(followupInput)
    }

    func testManualLocalCompactRecomputesEstimatedUsageAfterInstallingReplacementHistory() async throws {
        let compactSummary = "任务已经完成第一轮，并保留用户原始目标。"
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                tokenLimitScope: .bodyAfterPrefix
            )
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let compactResult = try await conversation.compactLocal(onEvent: { event in
            await events.append(event)
        })

        let compactUsage = try XCTUnwrap(compactResult.contextUsage)
        XCTAssertGreaterThan(compactUsage.currentTokens, 0)
        XCTAssertEqual(compactUsage.estimatedInputTokens, compactUsage.currentTokens)
        XCTAssertNil(compactUsage.serverInputTokens)
        XCTAssertNil(compactUsage.serverOutputTokens)
        XCTAssertNil(compactUsage.serverTotalTokens)

        let maybeRecordedUsage = await events.lastContextUsage()
        let recordedUsage = try XCTUnwrap(maybeRecordedUsage)
        XCTAssertEqual(recordedUsage, compactUsage)

        _ = try await conversation.send("第二轮：你刚才看到了什么？")
        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    func testManualLocalCompactPreHookStopDoesNotStartItemOrInstallReplacement() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream()
        ])
        let hooks = StaticCompactionHookRuntime(preOutcome: .stop(reason: "pause before compact"))
        let conversation = harness.makeConversation(compactionHooks: hooks)
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let beforeCompact = await conversation.snapshotTranscriptItems()
        let result = try await conversation.compactLocal(onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        let afterCompact = await conversation.snapshotTranscriptItems()
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(afterCompact, beforeCompact)

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertNil(lifecycle.startedContextCompactionID)
        XCTAssertNil(lifecycle.completedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)
    }

    func testManualLocalCompactPostHookStopKeepsInstalledReplacement() async throws {
        let compactSummary = "任务已经完成第一轮，并保留用户原始目标。"
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = StaticCompactionHookRuntime(postOutcome: .stop(reason: "pause after compact"))
        let conversation = harness.makeConversation(compactionHooks: hooks)
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let result = try await conversation.compactLocal(onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send("第二轮：你刚才看到了什么？")

        let requestCount = await harness.requestCount()
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(requestCount, 3)

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let followupSignatures = Self.signatures(from: followupInput)
        XCTAssertEqual(followupSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(followupSignatures.contains("message:assistant:final_answer:第一轮完成。"))
    }

    func testManualLocalCompactModelFailureDoesNotCompleteOrInstallReplacement() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.compactFailureStream(message: "temporary compact failure"),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(compactionHooks: hooks)
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let beforeCompact = await conversation.snapshotTranscriptItems()
        do {
            _ = try await conversation.compactLocal(onEvent: { event in
                await events.append(event)
            })
            XCTFail("manual local compact should throw the model failure")
        } catch {
            XCTAssertTrue(
                (error as NSError).localizedDescription.contains("temporary compact failure"),
                "unexpected error: \(error)"
            )
        }
        let afterCompact = await conversation.snapshotTranscriptItems()
        XCTAssertEqual(afterCompact, beforeCompact)
        let requestCountAfterFailure = await harness.requestCount()
        XCTAssertEqual(requestCountAfterFailure, 2)

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertNotNil(lifecycle.startedContextCompactionID)
        XCTAssertNil(lifecycle.completedContextCompactionID)
        XCTAssertEqual(lifecycle.failedContextCompactionID, lifecycle.startedContextCompactionID)
        XCTAssertEqual(lifecycle.failedMessage, "temporary compact failure")
        XCTAssertEqual(lifecycle.warningCount, 0)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 0)

        _ = try await conversation.send("第二轮：你刚才看到了什么？")
        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let followupSignatures = Self.signatures(from: followupInput)
        XCTAssertEqual(followupSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(followupSignatures.joined(separator: "\n").contains(Self.codexSummaryPrefix))
    }

    func testManualLocalCompactRetriesAfterContextWindowExceededByDroppingOldestCompactInput() async throws {
        let compactSummary = "压缩重试成功，并保留第一轮用户目标。"
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.compactContextWindowExceededStream(),
            Self.compactSummaryStream(text: compactSummary),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(compactionHooks: hooks)
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        _ = try await conversation.compactLocal(onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send("第二轮：你刚才看到了什么？")

        let requestCount = await harness.requestCount()
        XCTAssertEqual(requestCount, 4)

        let compactBody = try await harness.capturedBody(at: 1)
        let retryBody = try await harness.capturedBody(at: 2)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        let retryInput = try XCTUnwrap(retryBody["input"] as? [[String: Any]])
        let compactSignatures = Self.signatures(from: compactInput)
        let retrySignatures = Self.signatures(from: retryInput)

        XCTAssertEqual(compactSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertEqual(retrySignatures.first, "message:developer")
        XCTAssertEqual(retrySignatures.last, "message:user:\(Self.codexSummarizationPrompt)")

        let compactHistory = Array(compactSignatures.dropFirst().dropLast())
        let retryHistory = Array(retrySignatures.dropFirst().dropLast())
        XCTAssertEqual(retryHistory.count, compactHistory.count - 1)
        XCTAssertEqual(retryHistory, Array(compactHistory.dropFirst()))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 1)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)

        let followupBody = try await harness.capturedBody(at: 3)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let followupSignatures = Self.signatures(from: followupInput)
        XCTAssertEqual(followupSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:user:\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(followupSignatures.contains("message:assistant:final_answer:第一轮完成。"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
    }

    func testManualLocalCompactContextWindowExceededWhenNoCompactInputRemainsFailsFull() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.compactContextWindowExceededStream(),
            Self.compactContextWindowExceededStream(),
            Self.compactContextWindowExceededStream(),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let conversation = harness.makeConversation(model: "gpt-5", compactionHooks: hooks)
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let beforeCompact = await conversation.snapshotTranscriptItems()
        do {
            _ = try await conversation.compactLocal(onEvent: { event in
                await events.append(event)
            })
            XCTFail("manual local compact should throw when no compact input remains")
        } catch let MSPAgentModelClientError.contextWindowExceeded(message) {
            XCTAssertTrue(message.contains("context window"))
        } catch {
            XCTFail("unexpected compact error: \(error)")
        }

        let afterCompact = await conversation.snapshotTranscriptItems()
        XCTAssertEqual(afterCompact, beforeCompact)
        let requestCountAfterFailure = await harness.requestCount()
        XCTAssertEqual(requestCountAfterFailure, 4)

        let firstCompactBody = try await harness.capturedBody(at: 1)
        let secondCompactBody = try await harness.capturedBody(at: 2)
        let finalCompactBody = try await harness.capturedBody(at: 3)
        let firstCompactInput = try XCTUnwrap(firstCompactBody["input"] as? [[String: Any]])
        let secondCompactInput = try XCTUnwrap(secondCompactBody["input"] as? [[String: Any]])
        let finalCompactInput = try XCTUnwrap(finalCompactBody["input"] as? [[String: Any]])
        let firstSignatures = Self.signatures(from: firstCompactInput)
        let secondSignatures = Self.signatures(from: secondCompactInput)
        let finalSignatures = Self.signatures(from: finalCompactInput)

        XCTAssertEqual(firstSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertEqual(secondSignatures, [
            "message:developer",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])
        XCTAssertEqual(finalSignatures, [
            "message:developer",
            "message:user:\(Self.codexSummarizationPrompt)"
        ])

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertNotNil(lifecycle.startedContextCompactionID)
        XCTAssertNil(lifecycle.completedContextCompactionID)
        XCTAssertEqual(lifecycle.failedContextCompactionID, lifecycle.startedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)

        let recordedFullUsage = await events.lastContextUsage()
        let fullUsage = try XCTUnwrap(recordedFullUsage)
        XCTAssertEqual(fullUsage.modelID, "gpt-5")
        XCTAssertEqual(fullUsage.currentTokens, fullUsage.contextWindowTokens)
        XCTAssertEqual(fullUsage.estimatedInputTokens, fullUsage.contextWindowTokens)
        XCTAssertNil(fullUsage.serverInputTokens)
        XCTAssertNil(fullUsage.serverOutputTokens)
        XCTAssertNil(fullUsage.serverTotalTokens)
        XCTAssertEqual(fullUsage.currentUsageLevel, .critical)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 0)

        _ = try await conversation.send("第二轮：你刚才看到了什么？")
        let followupBody = try await harness.capturedBody(at: 4)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        let followupSignatures = Self.signatures(from: followupInput)
        XCTAssertEqual(followupSignatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(followupSignatures.joined(separator: "\n").contains(Self.codexSummaryPrefix))
    }

}
