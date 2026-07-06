import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationRemoteCompactionV1Tests: MSPAgentConversationRequestTestCase {
    func testPreTurnAutoRemoteV1ExcludesIncomingUserInstallsFilteredHistoryAndContinues() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_remote_preturn_over_limit",
                messageID: "msg_remote_preturn_over_limit",
                text: "第一轮完成。",
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.remoteCompactResponse(encryptedContent: "REMOTE_PRETURN_SUMMARY"),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let persistence = RecordingCompactionPersistenceAdapter()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                remoteCompactionEnabled: true
            ),
            compactionHooks: hooks,
            compactionPersistenceAdapter: persistence
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
        XCTAssertEqual(compactPath, "/v1/responses/compact")
        XCTAssertEqual(followupPath, "/v1/responses")

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮：看看当前目录"))
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮完成。"))
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains("第二轮：继续"))
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(compactInput.contains { $0["type"] as? String == "compaction_trigger" })

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        let compaction = try XCTUnwrap(metadata["compaction"] as? [String: Any])
        XCTAssertEqual(compaction["trigger"] as? String, "auto")
        XCTAssertEqual(compaction["reason"] as? String, "context_limit")
        XCTAssertEqual(compaction["implementation"] as? String, "responses_compact")
        XCTAssertEqual(compaction["phase"] as? String, "pre_turn")
        XCTAssertEqual(compaction["strategy"] as? String, "memento")

        let checkpoints = await persistence.checkpoints()
        XCTAssertEqual(checkpoints.count, 1)
        let replacementHistory = try XCTUnwrap(checkpoints.first?.replacementHistory)
        XCTAssertEqual(replacementHistory.compactMap { $0.objectValue?["type"]?.stringValue }, [
            "compaction"
        ])

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertTrue(followupInput.contains { item in
            item["type"] as? String == "compaction"
                && item["encrypted_content"] as? String == "REMOTE_PRETURN_SUMMARY"
        })
        XCTAssertTrue(Self.messageTexts(from: followupInput).contains("第二轮：继续"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains("第一轮完成。"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(followupInput.contains { $0["type"] as? String == "compaction_trigger" })

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }

    func testMidTurnAutoRemoteV1CompactsToolArtifactsAndContinuesWithInstalledHistory() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStreamWithUsage(
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            ),
            Self.remoteCompactResponse(encryptedContent: "REMOTE_MIDTURN_SUMMARY"),
            Self.secondTurnFinalAnswerStream()
        ])
        let hooks = RecordingCompactionHookRuntime()
        let persistence = RecordingCompactionPersistenceAdapter()
        let conversation = harness.makeConversation(
            model: "gpt-5",
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                remoteCompactionEnabled: true
            ),
            compactionHooks: hooks,
            compactionPersistenceAdapter: persistence
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：触发 remote v1 mid-turn 压缩", onEvent: { event in
            await events.append(event)
        })

        let requestCount = await harness.requestCount()
        let firstPath = await harness.capturedPath(at: 0)
        let compactPath = await harness.capturedPath(at: 1)
        let followupPath = await harness.capturedPath(at: 2)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(firstPath, "/v1/responses")
        XCTAssertEqual(compactPath, "/v1/responses/compact")
        XCTAssertEqual(followupPath, "/v1/responses")

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertEqual(Self.signatures(from: compactInput), [
            "message:developer",
            "message:user:第一轮：触发 remote v1 mid-turn 压缩",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_1",
            "function_call_output:call_1:exec_output;exit=0;output=/\n"
        ])
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(compactInput.contains { $0["type"] as? String == "compaction_trigger" })

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        let compaction = try XCTUnwrap(metadata["compaction"] as? [String: Any])
        XCTAssertEqual(compaction["trigger"] as? String, "auto")
        XCTAssertEqual(compaction["reason"] as? String, "context_limit")
        XCTAssertEqual(compaction["implementation"] as? String, "responses_compact")
        XCTAssertEqual(compaction["phase"] as? String, "mid_turn")
        XCTAssertEqual(compaction["strategy"] as? String, "memento")

        let checkpoints = await persistence.checkpoints()
        XCTAssertEqual(checkpoints.count, 1)
        let replacementHistory = try XCTUnwrap(checkpoints.first?.replacementHistory)
        XCTAssertEqual(replacementHistory.compactMap { $0.objectValue?["type"]?.stringValue }, [
            "compaction"
        ])

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertTrue(followupInput.contains { item in
            item["type"] as? String == "compaction"
                && item["encrypted_content"] as? String == "REMOTE_MIDTURN_SUMMARY"
        })
        XCTAssertFalse(Self.signatures(from: followupInput).contains("function_call:exec_command:call_1"))
        XCTAssertFalse(Self.signatures(from: followupInput).contains {
            $0.hasPrefix("function_call_output:call_1:")
        })
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))
        XCTAssertFalse(followupInput.contains { $0["type"] as? String == "compaction_trigger" })

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 0)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)

        let hookCounts = await hooks.counts()
        XCTAssertEqual(hookCounts.preCompact, 1)
        XCTAssertEqual(hookCounts.postCompact, 1)
    }

    func testManualRemoteV1CallsCompactEndpointInstallsFilteredHistoryAndContinues() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.remoteCompactResponse(encryptedContent: "REMOTE_COMPACT_SUMMARY"),
            Self.secondTurnFinalAnswerStream()
        ])
        let persistence = RecordingCompactionPersistenceAdapter()
        let conversation = harness.makeConversation(
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                remoteCompactionEnabled: true
            ),
            compactionPersistenceAdapter: persistence
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        _ = try await conversation.compact(onEvent: { event in
            await events.append(event)
        })
        _ = try await conversation.send("第二轮：继续")

        let requestCount = await harness.requestCount()
        let firstPath = await harness.capturedPath(at: 0)
        let compactPath = await harness.capturedPath(at: 1)
        let followupPath = await harness.capturedPath(at: 2)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(firstPath, "/v1/responses")
        XCTAssertEqual(compactPath, "/v1/responses/compact")
        XCTAssertEqual(followupPath, "/v1/responses")

        let compactBody = try await harness.capturedBody(at: 1)
        let compactInput = try XCTUnwrap(compactBody["input"] as? [[String: Any]])
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮：看看当前目录"))
        XCTAssertTrue(Self.messageTexts(from: compactInput).contains("第一轮完成。"))
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains("第二轮：继续"))
        XCTAssertFalse(Self.messageTexts(from: compactInput).contains(Self.codexSummarizationPrompt))

        let metadata = try XCTUnwrap(compactBody["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["request_kind"] as? String, "compaction")
        let compaction = try XCTUnwrap(metadata["compaction"] as? [String: Any])
        XCTAssertEqual(compaction["trigger"] as? String, "manual")
        XCTAssertEqual(compaction["reason"] as? String, "user_requested")
        XCTAssertEqual(compaction["implementation"] as? String, "responses_compact")
        XCTAssertEqual(compaction["phase"] as? String, "standalone_turn")
        XCTAssertEqual(compaction["strategy"] as? String, "memento")

        let checkpoints = await persistence.checkpoints()
        XCTAssertEqual(checkpoints.count, 1)
        let replacementHistory = try XCTUnwrap(checkpoints.first?.replacementHistory)
        XCTAssertEqual(replacementHistory.compactMap { $0.objectValue?["type"]?.stringValue }, [
            "compaction"
        ])

        let followupBody = try await harness.capturedBody(at: 2)
        let followupInput = try XCTUnwrap(followupBody["input"] as? [[String: Any]])
        XCTAssertTrue(followupInput.contains { item in
            item["type"] as? String == "compaction"
                && item["encrypted_content"] as? String == "REMOTE_COMPACT_SUMMARY"
        })
        XCTAssertTrue(Self.messageTexts(from: followupInput).contains("第二轮：继续"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains("第一轮完成。"))
        XCTAssertFalse(Self.messageTexts(from: followupInput).contains(Self.codexSummarizationPrompt))

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertEqual(lifecycle.startedContextCompactionID, lifecycle.completedContextCompactionID)
        XCTAssertNil(lifecycle.failedContextCompactionID)
        XCTAssertEqual(lifecycle.warningCount, 0)
    }

    func testManualRemoteV1FailureDoesNotCompleteOrInstallReplacement() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            #"{"error":{"message":"remote compact failed"}}"#
        ])
        let persistence = RecordingCompactionPersistenceAdapter()
        let conversation = harness.makeConversation(
            compactionPolicy: MSPCompactionPolicy(
                enabled: true,
                remoteCompactionEnabled: true
            ),
            compactionPersistenceAdapter: persistence
        )
        let events = RecordedAgentEvents()

        _ = try await conversation.send("第一轮：看看当前目录")
        let beforeCompact = await conversation.snapshotTranscriptItems()
        await XCTAssertThrowsErrorAsync(try await conversation.compact(onEvent: { event in
            await events.append(event)
        }))
        let afterCompact = await conversation.snapshotTranscriptItems()

        let requestCount = await harness.requestCount()
        let compactPath = await harness.capturedPath(at: 1)
        let checkpoints = await persistence.checkpoints()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(compactPath, "/v1/responses/compact")
        XCTAssertEqual(afterCompact, beforeCompact)
        XCTAssertEqual(checkpoints, [])

        let lifecycle = await events.compactionLifecycle()
        XCTAssertEqual(lifecycle.compactTurnStartedCount, 1)
        XCTAssertNotNil(lifecycle.startedContextCompactionID)
        XCTAssertNil(lifecycle.completedContextCompactionID)
        XCTAssertEqual(lifecycle.failedContextCompactionID, lifecycle.startedContextCompactionID)
        XCTAssertTrue(lifecycle.failedMessage?.hasPrefix("Error running remote compact task:") == true)
        XCTAssertEqual(lifecycle.warningCount, 0)
    }
}
