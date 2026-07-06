import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

final class MSPAgentConversationPendingInputCompactionTests: MSPAgentConversationRequestTestCase {
    func testConversationPendingInputOnlyCompactionDrainsQueuedSendAfterCompaction() async throws {
        let compactSummary = "queued input boundary compacted"
        let client = ConversationPendingInputScriptedModelClient(
            outputs: [
                MSPAgentModelTurnOutput(
                    finalAnswer: "ready for queued input",
                    responseID: "resp_initial",
                    nativeOutputItems: [
                        Self.transcriptMessage(
                            id: "msg_initial",
                            role: "assistant",
                            phase: "final_answer",
                            contentType: "output_text",
                            text: "ready for queued input"
                        )
                    ],
                    tokenUsage: MSPAgentTokenUsage(
                        inputTokens: 260_000,
                        outputTokens: 20_000,
                        totalTokens: 280_000
                    )
                ),
                MSPAgentModelTurnOutput(
                    assistantMessage: compactSummary,
                    responseID: "resp_compact"
                ),
                MSPAgentModelTurnOutput(
                    finalAnswer: "queued input answered",
                    responseID: "resp_queued"
                )
            ],
            blockedRequestIndexes: [0]
        )
        let conversation = Self.makeConversation(modelClient: client)

        let firstSend = Task {
            try await conversation.send("initial user")
        }
        await client.waitForRequestCount(1)

        let queuedSend = Task {
            try await conversation.send("queued user")
        }
        try await waitForPendingInput(in: conversation)
        await client.releaseRequest(at: 0)

        let firstResult = try await firstSend.value
        let queuedResult = try await queuedSend.value
        XCTAssertEqual(firstResult.finalAnswer, "queued input answered")
        XCTAssertEqual(queuedResult.finalAnswer, "queued input answered")

        let captured = await client.inputs()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(Self.messageTexts(from: captured[0]), [
            Self.developerText(from: captured[0]),
            "initial user"
        ])
        XCTAssertFalse(Self.messageTexts(from: captured[1]).contains("queued user"))
        XCTAssertTrue(Self.messageTexts(from: captured[1]).contains(Self.codexSummarizationPrompt))
        XCTAssertEqual(Self.messageTexts(from: captured[2]).suffix(2), [
            "\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "queued user"
        ])
    }

    func testConversationModelFollowUpCompactionDefersQueuedSendUntilFollowUpCompletes() async throws {
        let compactSummary = "tool follow-up compacted"
        let toolCall = MSPAgentToolCall(
            id: "call_1",
            name: .execCommand,
            arguments: ["cmd": .string("pwd")]
        )
        let client = ConversationPendingInputScriptedModelClient(
            outputs: [
                MSPAgentModelTurnOutput(
                    assistantMessage: "I need a tool.",
                    toolCalls: [toolCall],
                    responseID: "resp_tool",
                    nativeOutputItems: [
                        Self.transcriptMessage(
                            id: "msg_tool",
                            role: "assistant",
                            phase: "commentary",
                            contentType: "output_text",
                            text: "I need a tool."
                        ),
                        Self.functionCall(callID: toolCall.id)
                    ],
                    tokenUsage: MSPAgentTokenUsage(
                        inputTokens: 260_000,
                        outputTokens: 20_000,
                        totalTokens: 280_000
                    )
                ),
                MSPAgentModelTurnOutput(
                    assistantMessage: compactSummary,
                    responseID: "resp_compact"
                ),
                MSPAgentModelTurnOutput(
                    finalAnswer: "tool follow-up complete",
                    responseID: "resp_followup"
                ),
                MSPAgentModelTurnOutput(
                    finalAnswer: "queued input answered",
                    responseID: "resp_queued"
                )
            ],
            blockedRequestIndexes: [0]
        )
        let conversation = Self.makeConversation(modelClient: client)

        let firstSend = Task {
            try await conversation.send("initial tool request")
        }
        await client.waitForRequestCount(1)

        let queuedSend = Task {
            try await conversation.send("queued user")
        }
        try await waitForPendingInput(in: conversation)
        await client.releaseRequest(at: 0)

        let firstResult = try await firstSend.value
        let queuedResult = try await queuedSend.value
        XCTAssertEqual(firstResult.finalAnswer, "queued input answered")
        XCTAssertEqual(queuedResult.finalAnswer, "queued input answered")

        let captured = await client.inputs()
        XCTAssertEqual(captured.count, 4)
        XCTAssertFalse(
            Self.messageTexts(from: captured[1]).contains("queued user"),
            "queued user must not be included in the compact request itself."
        )
        XCTAssertFalse(
            Self.messageTexts(from: captured[2]).contains("queued user"),
            "queued user must not drain before the model follow-up continuation."
        )
        XCTAssertEqual(Self.messageTexts(from: captured[3]).suffix(2), [
            "\(Self.codexSummaryPrefix)\n\(compactSummary)",
            "queued user"
        ])
    }

    private static func makeConversation(
        modelClient: any MSPAgentModelTurnClient
    ) -> MSPAgentConversation {
        MSPAgentConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "gpt-5",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ],
                compactionPolicy: MSPCompactionPolicy(enabled: true)
            ),
            modelClient: modelClient,
            execCommandBridge: MSPExecCommandBridge(runCommand: { command in
                XCTAssertEqual(command, "pwd")
                return .success(stdout: "/\n")
            }),
            requestBuilder: MSPAgentRequestBuilder(),
            toolCallLimit: .unlimited
        )
    }

    private func waitForPendingInput(
        in conversation: MSPAgentConversation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if await !conversation.activeTurnSteerPendingInput(.peek).isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for queued pending input", file: file, line: line)
    }

    private static func functionCall(callID: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call"),
            "id": .string("fc_\(callID)"),
            "call_id": .string(callID),
            "name": .string(MSPAgentToolName.execCommand.rawValue),
            "arguments": .string(#"{"cmd":"pwd"}"#)
        ])
    }
}

private actor ConversationPendingInputScriptedModelClient: MSPAgentModelTurnClient {
    private var capturedInputs: [[MSPAgentJSONValue]] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedRequestIndexes: Set<Int> = []
    private let outputs: [MSPAgentModelTurnOutput]
    private let blockedRequestIndexes: Set<Int>

    init(
        outputs: [MSPAgentModelTurnOutput],
        blockedRequestIndexes: Set<Int> = []
    ) {
        self.outputs = outputs
        self.blockedRequestIndexes = blockedRequestIndexes
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = capturedInputs.count
        capturedInputs.append(request.input)
        resumeRequestCountWaiters()
        if blockedRequestIndexes.contains(index),
           !releasedRequestIndexes.contains(index) {
            await withCheckedContinuation { continuation in
                releaseWaiters[index, default: []].append(continuation)
            }
        }
        guard outputs.indices.contains(index) else {
            throw MSPAgentModelClientError.apiError("missing scripted output for request \(index)")
        }
        return outputs[index]
    }

    func waitForRequestCount(_ count: Int) async {
        guard capturedInputs.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func releaseRequest(at index: Int) {
        releasedRequestIndexes.insert(index)
        let waiters = releaseWaiters.removeValue(forKey: index) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func inputs() -> [[[String: Any]]] {
        capturedInputs.map { input in
            input.compactMap { item in
                item.jsonObject as? [String: Any]
            }
        }
    }

    private func resumeRequestCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if capturedInputs.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }
}
