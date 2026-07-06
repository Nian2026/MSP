import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationRequestHistoryTests: MSPAgentConversationRequestTestCase {
    func testAdditionalDeveloperContextBlocksArePerTurnOnly() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream(),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()

        _ = try await conversation.send(
            "第一轮",
            additionalDeveloperContextBlocks: ["dynamic photo tree: version 1"]
        )
        _ = try await conversation.send(
            "第二轮",
            additionalDeveloperContextBlocks: ["dynamic photo tree: version 2"]
        )

        let firstBody = try await harness.capturedBody(at: 0)
        let firstInput = try XCTUnwrap(firstBody["input"] as? [[String: Any]])
        let firstDeveloperText = Self.developerText(from: firstInput)
        XCTAssertTrue(firstDeveloperText.contains("dynamic photo tree: version 1"))
        XCTAssertFalse(firstDeveloperText.contains("dynamic photo tree: version 2"))

        let secondBody = try await harness.capturedBody(at: 1)
        let secondInput = try XCTUnwrap(secondBody["input"] as? [[String: Any]])
        let secondDeveloperText = Self.developerText(from: secondInput)
        XCTAssertTrue(secondDeveloperText.contains("dynamic photo tree: version 2"))
        XCTAssertFalse(secondDeveloperText.contains("dynamic photo tree: version 1"))
    }

    func testDefaultRequestDoesNotExposeGoalTools() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()

        _ = try await conversation.send("第一轮")

        let body = try await harness.capturedBody(at: 0)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertFalse(toolNames.contains(MSPGoalTools.getGoalName))
        XCTAssertFalse(toolNames.contains(MSPGoalTools.createGoalName))
        XCTAssertFalse(toolNames.contains(MSPGoalTools.updateGoalName))

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let developerText = Self.developerText(from: input)
        XCTAssertFalse(developerText.contains(MSPGoalTools.getGoalName))
        XCTAssertFalse(developerText.contains(MSPGoalTools.createGoalName))
        XCTAssertFalse(developerText.contains(MSPGoalTools.updateGoalName))
    }

    func testDynamicDeveloperContextBlocksAreReplacedBeforeEachModelRequest() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStream(),
            Self.firstTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()
        let counter = DynamicDeveloperContextCounter()

        _ = try await conversation.send(
            "第一轮：看看当前目录",
            dynamicDeveloperContextBlocks: [
                MSPAgentDynamicDeveloperContextBlock(id: "workspace-tree") {
                    await counter.next()
                }
            ]
        )

        let firstBody = try await harness.capturedBody(at: 0)
        let firstInput = try XCTUnwrap(firstBody["input"] as? [[String: Any]])
        let firstDeveloperText = Self.developerText(from: firstInput)
        XCTAssertTrue(firstDeveloperText.contains("dynamic tree version 2"))
        XCTAssertFalse(firstDeveloperText.contains("dynamic tree version 1"))

        let continuationBody = try await harness.capturedBody(at: 1)
        let continuationInput = try XCTUnwrap(continuationBody["input"] as? [[String: Any]])
        let continuationDeveloperText = Self.developerText(from: continuationInput)
        XCTAssertTrue(continuationDeveloperText.contains("dynamic tree version 3"))
        XCTAssertFalse(continuationDeveloperText.contains("dynamic tree version 1"))
        XCTAssertFalse(continuationDeveloperText.contains("dynamic tree version 2"))
    }

    func testSecondTurnHTTPBodyContainsPriorToolCallToolOutputAndFinalAnswerBeforeNewUser() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStream(),
            Self.firstTurnFinalAnswerStream(),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()

        _ = try await conversation.send("第一轮：看看当前目录")
        _ = try await conversation.send("第二轮：你刚才看到了什么？")

        let body = try await harness.capturedBody(at: 2)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_1",
            "function_call_output:call_1:exec_output;exit=0;output=/\n",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testProviderRequestRemovesOrphanToolOutputsFromStoredTranscript() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()
        await conversation.replaceTranscriptItems([
            .object([
                "type": .string("function_call_output"),
                "call_id": .string("call_missing"),
                "output": .string("orphan output")
            ]),
            .object([
                "type": .string("custom_tool_call_output"),
                "call_id": .string("call_custom_missing"),
                "output": .string("orphan custom output")
            ]),
            .object([
                "type": .string("function_call"),
                "id": .string("fc_call_kept"),
                "call_id": .string("call_kept"),
                "name": .string(MSPAgentToolName.execCommand.rawValue),
                "arguments": .string(#"{"cmd":"pwd"}"#)
            ]),
            .object([
                "type": .string("function_call_output"),
                "call_id": .string("call_kept"),
                "output": .string("ok")
            ]),
            .object([
                "type": .string("custom_tool_call"),
                "id": .string("ctc_call_custom_kept"),
                "call_id": .string("call_custom_kept"),
                "name": .string(MSPAgentToolName.applyPatch.rawValue),
                "input": .string("*** Begin Patch\n*** End Patch\n")
            ]),
            .object([
                "type": .string("custom_tool_call_output"),
                "call_id": .string("call_custom_kept"),
                "output": .string("custom ok")
            ])
        ])

        _ = try await conversation.send("继续")

        let body = try await harness.capturedBody(at: 0)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "function_call:exec_command:call_kept",
            "function_call_output:call_kept:ok",
            "custom_tool_call:apply_patch:call_custom_kept:*** Begin Patch\n*** End Patch\n",
            "custom_tool_call_output:call_custom_kept:custom ok",
            "message:user:继续"
        ])
        XCTAssertFalse(signatures.contains {
            $0.contains("call_missing") || $0.contains("call_custom_missing")
        })
    }

    func testProviderFailurePreservesPartialTurnTranscriptBeforeNextUser() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStream(),
            Self.compactFailureStream(message: "rate limit exceeded"),
            Self.secondTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()

        do {
            _ = try await conversation.send("第一轮：看看当前目录")
            XCTFail("first turn should fail after the tool result is sent back to the model")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rate limit exceeded"))
        }
        _ = try await conversation.send("第二轮：继续")

        let body = try await harness.capturedBody(at: 2)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_1",
            "function_call_output:call_1:exec_output;exit=0;output=/\n",
            "message:user:第二轮：继续"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testThirdTurnKeepsEarlierTurnsWithoutSummaryOrReordering() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.firstTurnToolCallStream(),
            Self.firstTurnFinalAnswerStream(),
            Self.secondTurnFinalAnswerStream(),
            Self.thirdTurnFinalAnswerStream()
        ])
        let conversation = harness.makeConversation()

        _ = try await conversation.send("第一轮：看看当前目录")
        _ = try await conversation.send("第二轮：你刚才看到了什么？")
        _ = try await conversation.send("第三轮：继续沿用刚才的信息")

        let body = try await harness.capturedBody(at: 3)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:commentary:我先看一下工作区。",
            "function_call:exec_command:call_1",
            "function_call_output:call_1:exec_output;exit=0;output=/\n",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：你刚才看到了什么？",
            "message:assistant:final_answer:第二轮回答。",
            "message:user:第三轮：继续沿用刚才的信息"
        ])
        XCTAssertFalse(signatures.joined(separator: "\n").lowercased().contains("summary"))
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testResponseUsagePublishesContextUsageEventForGPT5() async throws {
        let harness = try RequestCaptureHarness(streams: [
            Self.finalAnswerStreamWithUsage(
                id: "resp_usage",
                messageID: "msg_usage",
                text: "完成。",
                inputTokens: 12_345,
                outputTokens: 678,
                totalTokens: 13_023
            )
        ])
        let conversation = harness.makeConversation(model: "gpt-5")
        let events = RecordedAgentEvents()

        let result = try await conversation.send("看看上下文用量", onEvent: { event in
            await events.append(event)
        })

        let resultUsage = try XCTUnwrap(result.contextUsage)
        XCTAssertEqual(resultUsage.modelID, "gpt-5")
        XCTAssertEqual(resultUsage.contextWindowTokens, 272_000)
        XCTAssertEqual(resultUsage.currentTokens, 13_023)
        XCTAssertEqual(resultUsage.serverInputTokens, 12_345)
        XCTAssertEqual(resultUsage.serverOutputTokens, 678)
        XCTAssertEqual(resultUsage.serverTotalTokens, 13_023)

        let recordedEventUsage = await events.lastContextUsage()
        let eventUsage = try XCTUnwrap(recordedEventUsage)
        XCTAssertEqual(eventUsage, resultUsage)
    }

    func testUsageOverAutoCompactLimitDoesNotChangeNextRequestWhenCompactionIsDisabled() async throws {
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
        let conversation = harness.makeConversation(model: "gpt-5")

        let firstResult = try await conversation.send("第一轮：看看当前目录")
        _ = try await conversation.send("第二轮：你刚才看到了什么？")

        let usage = try XCTUnwrap(firstResult.contextUsage)
        XCTAssertGreaterThanOrEqual(usage.currentTokens, usage.autoCompactTokenLimit)

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:第一轮：看看当前目录",
            "message:assistant:final_answer:第一轮完成。",
            "message:user:第二轮：你刚才看到了什么？"
        ])
        XCTAssertFalse(signatures.joined(separator: "\n").lowercased().contains("summary"))
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

}
