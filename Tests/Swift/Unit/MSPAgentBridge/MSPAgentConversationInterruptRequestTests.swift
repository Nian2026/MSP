import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationInterruptRequestTests: MSPAgentConversationRequestTestCase {
    func testCancelledTurnPersistsCompletedToolContextForNextTurn() async throws {
        let requests = RecordedModelRequests()
        let client = CancellingAfterToolResultModelClient(requests: requests)
        let bridge = MSPExecCommandBridge { call, _ in
            XCTAssertEqual(call.cmd, "pwd")
            return .success(stdout: "/\n")
        }
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: bridge
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "test-model",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ]
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：看看当前目录")
        }
        try await requests.waitForCount(2)
        runningTurn.cancel()
        let cancelledResult = try await runningTurn.value
        XCTAssertTrue(cancelledResult.wasCancelled)

        _ = try await conversation.send("第二轮：你刚才执行到了哪里？")

        let followupRequest = try await requests.request(at: 2)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_cancel",
            "function_call_output:call_cancel:exec_output;exit=0;output=/\n",
            "message:assistant:final_answer:我已经看到了 /。",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：你刚才执行到了哪里？"
        ])
        Self.assertProviderMessageIDsAreSafe(input)
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertMessage(
            containing: "我已经看到了 /。",
            in: input,
            hasID: false
        )
    }

    func testInterruptActiveTurnPersistsStoppedHistoryBeforeImmediateFollowup() async throws {
        let requests = RecordedModelRequests()
        let client = CancellingAfterToolResultModelClient(requests: requests)
        let bridge = MSPExecCommandBridge { call, _ in
            XCTAssertEqual(call.cmd, "pwd")
            return .success(stdout: "/\n")
        }
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: bridge
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "test-model",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ]
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：看看当前目录")
        }
        try await requests.waitForCount(2)
        _ = try await conversation.interruptActiveTurn()
        let followupTurn = Task {
            try await conversation.send("第二轮：你刚才执行到了哪里？")
        }

        let cancelledResult = try await runningTurn.value
        XCTAssertTrue(cancelledResult.wasCancelled)
        _ = try await followupTurn.value

        let followupRequest = try await requests.request(at: 2)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_cancel",
            "function_call_output:call_cancel:exec_output;exit=0;output=/\n",
            "message:assistant:final_answer:我已经看到了 /。",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：你刚才执行到了哪里？"
        ])
        Self.assertProviderMessageIDsAreSafe(input)
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertMessage(
            containing: "我已经看到了 /。",
            in: input,
            hasID: false
        )
    }

    func testRestoredInterruptedTranscriptRemovesLocalMessageIDsFromProviderPrompt() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()
        await conversation.replaceTranscriptItems([
            Self.transcriptMessage(
                id: "cancelled-restored",
                role: "assistant",
                phase: "final_answer",
                contentType: "output_text",
                text: "旧的取消 partial。"
            ),
            Self.transcriptMessage(
                id: "interrupted-final_answer",
                role: "assistant",
                phase: "final_answer",
                contentType: "output_text",
                text: "旧的中断 partial。"
            ),
            Self.transcriptMessage(
                id: "msg_provider_kept",
                role: "assistant",
                phase: "final_answer",
                contentType: "output_text",
                text: "provider 返回的消息。"
            )
        ])

        _ = try await conversation.send("继续")

        let body = try await harness.capturedBody(at: 0)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        Self.assertProviderMessageIDsAreSafe(input)
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertMessage(containing: "旧的取消 partial。", in: input, hasID: false)
        Self.assertMessage(containing: "旧的中断 partial。", in: input, hasID: false)
        Self.assertMessage(containing: "provider 返回的消息。", in: input, hasID: true)
        let providerMessage = try XCTUnwrap(Self.message(containing: "provider 返回的消息。", in: input))
        XCTAssertEqual(providerMessage["id"] as? String, "msg_provider_kept")
    }

    func testInterruptActiveTurnWithNonReturningToolReleasesFollowupAndNormalizesMissingToolOutput() async throws {
        let requests = RecordedModelRequests()
        let client = BlockingToolModelClient(requests: requests)
        let gate = BlockingCommandGate()
        let bridge = MSPExecCommandBridge { call, _ in
            XCTAssertEqual(call.cmd, "sleep 3000")
            await gate.runUntilReleased()
            return .success(stdout: "late\n")
        }
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: bridge
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "test-model",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ]
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：运行一个慢命令")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        _ = try await conversation.interruptActiveTurn()
        let followupTurn = Task {
            try await conversation.send("第二轮：这个命令太慢")
        }

        try await requests.waitForCount(2)
        let followupRequest = try await requests.request(at: 1)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:第一轮：运行一个慢命令",
            "message:assistant:commentary:我会运行一个慢命令。",
            "function_call:exec_command:call_blocked",
            "function_call_output:call_blocked:aborted",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：这个命令太慢"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)

        _ = try await followupTurn.value
        await gate.release()
        let cancelledResult = try await runningTurn.value
        XCTAssertTrue(cancelledResult.wasCancelled)
    }

    func testInterruptedTurnLateUsageDoesNotOverrideFollowupUsageForAutoCompaction() async throws {
        let requests = RecordedModelRequests()
        let firstTurnGate = ModelTurnReleaseGate()
        let client = LateUsageAfterInterruptModelClient(
            requests: requests,
            firstTurnGate: firstTurnGate
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge { _, _ in .success(stdout: "") }
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "gpt-5",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ],
                compactionPolicy: MSPCompactionPolicy(enabled: true)
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：会被中断但晚返回 usage")
        }
        try await requests.waitForCount(1)

        _ = try await conversation.interruptActiveTurn()
        _ = try await conversation.send("第二轮：完成后记录低 usage")

        await firstTurnGate.release()
        _ = try await runningTurn.value
        _ = try await conversation.send("第三轮：不能被旧 usage 触发压缩")

        try await requests.waitForCount(3)
        let thirdRequest = try await requests.request(at: 2)
        let input = thirdRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        let signatures = Self.signatures(from: input)
        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:第一轮：会被中断但晚返回 usage",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：完成后记录低 usage",
            "message:assistant:final_answer:第二轮完成。",
            "message:user:第三轮：不能被旧 usage 触发压缩"
        ])
        XCTAssertFalse(Self.messageTexts(from: input).contains(Self.codexSummarizationPrompt))
    }

    func testInterruptAfterMidTurnCompactionDoesNotRestoreCompactedAwayToolHistory() async throws {
        let requests = RecordedModelRequests()
        let client = MidTurnCompactionBlockingContinuationModelClient(requests: requests)
        let bridge = MSPExecCommandBridge { call, _ in
            XCTAssertEqual(call.cmd, "pwd")
            return .success(stdout: "/\n")
        }
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: bridge
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "gpt-5",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ],
                compactionPolicy: MSPCompactionPolicy(enabled: true)
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：触发中途压缩后中断")
        }
        try await requests.waitForCount(3)

        _ = try await conversation.interruptActiveTurn()
        let followupTurn = Task {
            try await conversation.send("第二轮：继续")
        }

        try await requests.waitForCount(4)
        let followupRequest = try await requests.request(at: 3)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        let signatures = Self.signatures(from: input)
        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:第一轮：触发中途压缩后中断",
            "message:user:\(Self.codexSummaryPrefix)\n中途工具结果已经压缩。",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：继续"
        ])
        XCTAssertFalse(signatures.contains("function_call:exec_command:call_mid_compact"))
        XCTAssertFalse(signatures.contains {
            $0.hasPrefix("function_call_output:call_mid_compact:")
        })
        XCTAssertEqual(
            signatures.filter { $0 == "message:user:第一轮：触发中途压缩后中断" }.count,
            1
        )
        Self.assertProviderMessagePhasesAreSafe(input)

        _ = try await followupTurn.value
        let cancelledResult = try await runningTurn.value
        XCTAssertTrue(cancelledResult.wasCancelled)
    }

    func testOuterTaskCancelPersistsStoppedHistoryBeforeImmediateFollowup() async throws {
        let requests = RecordedModelRequests()
        let client = CancellingAfterToolResultModelClient(requests: requests)
        let bridge = MSPExecCommandBridge { call, _ in
            XCTAssertEqual(call.cmd, "pwd")
            return .success(stdout: "/\n")
        }
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: bridge
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "test-model",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ]
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：看看当前目录")
        }
        try await requests.waitForCount(2)
        runningTurn.cancel()
        let followupTurn = Task {
            try await conversation.send("第二轮：你刚才执行到了哪里？")
        }

        let cancelledResult = try await runningTurn.value
        XCTAssertTrue(cancelledResult.wasCancelled)
        _ = try await followupTurn.value

        let followupRequest = try await requests.request(at: 2)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_cancel",
            "function_call_output:call_cancel:exec_output;exit=0;output=/\n",
            "message:assistant:final_answer:我已经看到了 /。",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：你刚才执行到了哪里？"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
    }

    func testInterruptAndOuterTaskCancelPersistStoppedHistoryBeforeImmediateFollowup() async throws {
        let requests = RecordedModelRequests()
        let client = CancellingAfterToolResultModelClient(requests: requests)
        let bridge = MSPExecCommandBridge { call, _ in
            XCTAssertEqual(call.cmd, "pwd")
            return .success(stdout: "/\n")
        }
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: bridge
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "test-model",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ]
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：看看当前目录")
        }
        try await requests.waitForCount(2)
        _ = try await conversation.interruptActiveTurn()
        runningTurn.cancel()
        let followupTurn = Task {
            try await conversation.send("第二轮：你刚才执行到了哪里？")
        }

        let cancelledResult = try await runningTurn.value
        XCTAssertTrue(cancelledResult.wasCancelled)
        _ = try await followupTurn.value

        let followupRequest = try await requests.request(at: 2)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_cancel",
            "function_call_output:call_cancel:exec_output;exit=0;output=/\n",
            "message:assistant:final_answer:我已经看到了 /。",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：你刚才执行到了哪里？"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
    }

}
