import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPAgentToolLoopPendingInputCompactionTests: XCTestCase {
    func testStreamingTextDeltasEmitVisibleEventsWithoutDuplicateAssistantProgress() async throws {
        let requests = ToolLoopRecordedRequests()
        let events = ToolLoopRecordedEvents()
        let client = ToolLoopStepModelClient(
            requests: requests,
            steps: [
                .output(
                    MSPAgentModelTurnOutput(
                        assistantMessage: "Thinking",
                        finalAnswer: "Done"
                    ),
                    deltas: [
                        MSPAgentModelStreamDelta(text: "Think", phase: .assistantMessage),
                        MSPAgentModelStreamDelta(text: "ing", phase: .assistantMessage),
                        MSPAgentModelStreamDelta(text: "Do", phase: .finalAnswer),
                        MSPAgentModelStreamDelta(text: "ne", phase: .finalAnswer)
                    ]
                )
            ]
        )
        let loop = MSPAgentToolLoop(modelClient: client)

        let result = try await loop.run(
            request: Self.envelope(input: [
                Self.message(role: "developer", text: "developer context"),
                Self.message(role: "user", text: "stream please")
            ]),
            initialTranscriptAppendItems: [],
            onEvent: { event in
                await events.append(event)
            },
            executeTool: { call in
                XCTFail("streaming text scenario should not execute tool \(call.name.rawValue)")
                return MSPAgentToolResult(
                    callID: call.id,
                    name: call.name,
                    ok: false,
                    content: nil,
                    errorMessage: "unexpected tool call"
                )
            }
        )

        XCTAssertEqual(result.finalAnswer, "Done")
        let assistantDeltas = await events.assistantProgressDeltas()
        let finalDeltas = await events.finalAnswerDeltas()
        let assistantMessages = await events.assistantProgressMessages()
        let finalAnswers = await events.finalAnswers()
        let assistantStartCount = await events.assistantProgressSegmentStartCount()
        let finalStartCount = await events.finalAnswerStartCount()
        XCTAssertEqual(assistantDeltas, ["Think", "ing"])
        XCTAssertEqual(finalDeltas, ["Do", "ne"])
        XCTAssertEqual(assistantMessages, [])
        XCTAssertEqual(finalAnswers, ["Done"])
        XCTAssertEqual(assistantStartCount, 1)
        XCTAssertEqual(finalStartCount, 1)
    }

    func testStructuredStreamingJSONDeltasAreSuppressed() async throws {
        let requests = ToolLoopRecordedRequests()
        let events = ToolLoopRecordedEvents()
        let client = ToolLoopStepModelClient(
            requests: requests,
            steps: [
                .output(
                    MSPAgentModelTurnOutput(finalAnswer: "fallback answer"),
                    deltas: [
                        MSPAgentModelStreamDelta(text: #"{"hidden":"#, phase: .assistantMessage),
                        MSPAgentModelStreamDelta(text: #""assistant"}"#, phase: .assistantMessage),
                        MSPAgentModelStreamDelta(text: #"{"hidden":"#, phase: .finalAnswer),
                        MSPAgentModelStreamDelta(text: #""final"}"#, phase: .finalAnswer)
                    ]
                )
            ]
        )
        let loop = MSPAgentToolLoop(modelClient: client)

        let result = try await loop.run(
            request: Self.envelope(input: [
                Self.message(role: "developer", text: "developer context"),
                Self.message(role: "user", text: "structured stream")
            ]),
            initialTranscriptAppendItems: [],
            onEvent: { event in
                await events.append(event)
            },
            executeTool: { call in
                XCTFail("structured streaming scenario should not execute tool \(call.name.rawValue)")
                return MSPAgentToolResult(
                    callID: call.id,
                    name: call.name,
                    ok: false,
                    content: nil,
                    errorMessage: "unexpected tool call"
                )
            }
        )

        XCTAssertEqual(result.finalAnswer, "fallback answer")
        let assistantDeltas = await events.assistantProgressDeltas()
        let finalDeltas = await events.finalAnswerDeltas()
        let assistantStartCount = await events.assistantProgressSegmentStartCount()
        let finalStartCount = await events.finalAnswerStartCount()
        let finalAnswers = await events.finalAnswers()
        XCTAssertEqual(assistantDeltas, [])
        XCTAssertEqual(finalDeltas, [])
        XCTAssertEqual(assistantStartCount, 0)
        XCTAssertEqual(finalStartCount, 0)
        XCTAssertEqual(finalAnswers, ["fallback answer"])
    }

    func testTransientStreamRetryDoesNotDuplicatePendingToolOutput() async throws {
        let requests = ToolLoopRecordedRequests()
        let events = ToolLoopRecordedEvents()
        let toolCall = MSPAgentToolCall(
            id: "call_retry",
            name: .execCommand,
            arguments: ["cmd": .string("pwd")]
        )
        let client = ToolLoopStepModelClient(
            requests: requests,
            steps: [
                .output(
                    MSPAgentModelTurnOutput(
                        assistantMessage: "Need pwd",
                        toolCalls: [toolCall],
                        nativeOutputItems: [
                            Self.message(role: "assistant", text: "Need pwd"),
                            Self.functionCall(callID: toolCall.id)
                        ]
                    )
                ),
                .failure(NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorNetworkConnectionLost
                )),
                .output(MSPAgentModelTurnOutput(finalAnswer: "retry complete"))
            ]
        )
        let loop = MSPAgentToolLoop(
            modelClient: client,
            maximumTransientModelStreamRetries: 1
        )

        let result = try await loop.run(
            request: Self.envelope(input: [
                Self.message(role: "developer", text: "developer context"),
                Self.message(role: "user", text: "run pwd")
            ]),
            initialTranscriptAppendItems: [],
            onEvent: { event in
                await events.append(event)
            },
            executeTool: { call in
                MSPAgentToolResult(
                    callID: call.id,
                    name: call.name,
                    ok: true,
                    content: .string("/\n"),
                    errorMessage: nil
                )
            }
        )

        XCTAssertEqual(result.finalAnswer, "retry complete")
        let retryCount = await events.modelStreamRetryCount()
        XCTAssertEqual(retryCount, 1)
        let captured = await requests.inputs()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(Self.functionCallOutputCount(in: captured[1]), 1)
        XCTAssertEqual(Self.functionCallOutputCount(in: captured[2]), 1)
    }

    func testPendingInputOnlyCompactionDrainsQueuedInputImmediatelyAfterCompaction() async throws {
        let initialInput = [
            Self.message(role: "developer", text: "developer context"),
            Self.message(role: "user", text: "initial user")
        ]
        let pendingInput = Self.message(role: "user", text: "queued user")
        let requests = ToolLoopRecordedRequests()
        let client = ToolLoopScriptedModelClient(
            requests: requests,
            outputs: [
                MSPAgentModelTurnOutput(
                    finalAnswer: "ready for queued input",
                    responseID: "resp_initial",
                    tokenUsage: MSPAgentTokenUsage(
                        inputTokens: 260_000,
                        outputTokens: 20_000,
                        totalTokens: 280_000
                    )
                ),
                MSPAgentModelTurnOutput(
                    finalAnswer: "queued input answered",
                    responseID: "resp_queued"
                )
            ]
        )
        let pendingQueue = ToolLoopPendingInputQueue(items: [pendingInput])
        let compaction = ToolLoopD02CompactionRecorder(
            compactedInput: [
                Self.message(role: "developer", text: "developer context"),
                Self.message(role: "user", text: "compacted summary")
            ]
        )
        let loop = MSPAgentToolLoop(
            modelClient: client,
            modelID: "gpt-5",
            modelDisplayName: "gpt-5"
        )

        let result = try await loop.run(
            request: Self.envelope(input: initialInput),
            initialTranscriptAppendItems: [initialInput[1]],
            pendingInputProvider: { request in
                await pendingQueue.handle(request)
            },
            midTurnCompaction: { context in
                await compaction.handle(context)
            },
            onEvent: { _ in },
            executeTool: { call in
                XCTFail("pending-input-only scenario should not execute tool \(call.name.rawValue)")
                return MSPAgentToolResult(
                    callID: call.id,
                    name: call.name,
                    ok: false,
                    content: nil,
                    errorMessage: "unexpected tool call"
                )
            }
        )

        XCTAssertEqual(result.finalAnswer, "queued input answered")
        let captured = await requests.inputs()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(Self.messageTexts(from: captured[0]), ["developer context", "initial user"])
        XCTAssertEqual(Self.messageTexts(from: captured[1]), [
            "developer context",
            "compacted summary",
            "queued user"
        ])
        let pendingQueueIsEmpty = await pendingQueue.isEmpty()
        XCTAssertTrue(pendingQueueIsEmpty)

        let contexts = await compaction.contexts()
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].modelNeedsFollowUp, false)
        XCTAssertEqual(contexts[0].hasPendingInput, true)
        let compactionCount = await compaction.compactionCount()
        XCTAssertEqual(compactionCount, 1)
    }

    func testModelFollowUpCompactionDefersQueuedInputUntilFollowUpCompletes() async throws {
        let initialInput = [
            Self.message(role: "developer", text: "developer context"),
            Self.message(role: "user", text: "initial tool request")
        ]
        let pendingInput = Self.message(role: "user", text: "queued user")
        let requests = ToolLoopRecordedRequests()
        let toolCall = MSPAgentToolCall(
            id: "call_1",
            name: .execCommand,
            arguments: ["cmd": .string("pwd")]
        )
        let client = ToolLoopScriptedModelClient(
            requests: requests,
            outputs: [
                MSPAgentModelTurnOutput(
                    assistantMessage: "I need a tool.",
                    toolCalls: [toolCall],
                    responseID: "resp_tool",
                    nativeOutputItems: [
                        Self.message(role: "assistant", text: "I need a tool."),
                        Self.functionCall(callID: toolCall.id)
                    ],
                    tokenUsage: MSPAgentTokenUsage(
                        inputTokens: 260_000,
                        outputTokens: 20_000,
                        totalTokens: 280_000
                    )
                ),
                MSPAgentModelTurnOutput(
                    finalAnswer: "tool follow-up complete",
                    responseID: "resp_followup"
                ),
                MSPAgentModelTurnOutput(
                    finalAnswer: "queued input answered",
                    responseID: "resp_queued"
                )
            ]
        )
        let pendingQueue = ToolLoopPendingInputQueue(items: [pendingInput])
        let compaction = ToolLoopD02CompactionRecorder(
            compactedInput: [
                Self.message(role: "developer", text: "developer context"),
                Self.message(role: "user", text: "compacted summary")
            ]
        )
        let loop = MSPAgentToolLoop(
            modelClient: client,
            modelID: "gpt-5",
            modelDisplayName: "gpt-5"
        )

        let result = try await loop.run(
            request: Self.envelope(input: initialInput),
            initialTranscriptAppendItems: [initialInput[1]],
            pendingInputProvider: { request in
                await pendingQueue.handle(request)
            },
            midTurnCompaction: { context in
                await compaction.handle(context)
            },
            onEvent: { _ in },
            executeTool: { call in
                MSPAgentToolResult(
                    callID: call.id,
                    name: call.name,
                    ok: true,
                    content: .string("/\n"),
                    errorMessage: nil
                )
            }
        )

        XCTAssertEqual(result.finalAnswer, "queued input answered")
        let captured = await requests.inputs()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(Self.messageTexts(from: captured[0]), [
            "developer context",
            "initial tool request"
        ])
        XCTAssertEqual(
            Self.messageTexts(from: captured[1]),
            ["developer context", "compacted summary"],
            "queued input must not drain before the model follow-up continuation request."
        )
        XCTAssertEqual(Self.messageTexts(from: captured[2]), [
            "developer context",
            "compacted summary",
            "queued user"
        ])
        let pendingQueueIsEmpty = await pendingQueue.isEmpty()
        XCTAssertTrue(pendingQueueIsEmpty)

        let contexts = await compaction.contexts()
        XCTAssertGreaterThanOrEqual(contexts.count, 2)
        XCTAssertEqual(contexts[0].modelNeedsFollowUp, true)
        XCTAssertEqual(contexts[0].hasPendingInput, true)
        XCTAssertEqual(contexts[1].modelNeedsFollowUp, false)
        XCTAssertEqual(contexts[1].hasPendingInput, true)
        let compactionCount = await compaction.compactionCount()
        XCTAssertEqual(compactionCount, 1)
    }

    private static func envelope(input: [MSPAgentJSONValue]) -> MSPAgentRequestEnvelope {
        MSPAgentRequestEnvelope(
            payload: [
                "model": .string("gpt-5"),
                "input": .array(input)
            ],
            input: input
        )
    }

    private static func message(role: String, text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .array([
                .object([
                    "type": .string(role == "user" ? "input_text" : "output_text"),
                    "text": .string(text)
                ])
            ])
        ])
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

    private static func messageTexts(from input: [MSPAgentJSONValue]) -> [String] {
        input.flatMap { item -> [String] in
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "message",
                  let content = object["content"]?.arrayValue else {
                return []
            }
            return content.compactMap { contentItem in
                contentItem.objectValue?["text"]?.stringValue
            }
        }
    }

    private static func functionCallOutputCount(in input: [MSPAgentJSONValue]) -> Int {
        input.filter { item in
            item.objectValue?["type"]?.stringValue == "function_call_output"
        }.count
    }
}

private actor ToolLoopRecordedRequests {
    private var capturedInputs: [[MSPAgentJSONValue]] = []

    func append(_ request: MSPAgentRequestEnvelope) -> Int {
        let index = capturedInputs.count
        capturedInputs.append(request.input)
        return index
    }

    func inputs() -> [[MSPAgentJSONValue]] {
        capturedInputs
    }
}

private final class ToolLoopScriptedModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: ToolLoopRecordedRequests
    private let outputs: [MSPAgentModelTurnOutput]

    init(
        requests: ToolLoopRecordedRequests,
        outputs: [MSPAgentModelTurnOutput]
    ) {
        self.requests = requests
        self.outputs = outputs
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = await requests.append(request)
        guard outputs.indices.contains(index) else {
            throw MSPAgentModelClientError.apiError("missing scripted output for request \(index)")
        }
        return outputs[index]
    }
}

private enum ToolLoopModelStep {
    case output(MSPAgentModelTurnOutput, deltas: [MSPAgentModelStreamDelta] = [])
    case failure(Error)
}

private final class ToolLoopStepModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: ToolLoopRecordedRequests
    private let steps: [ToolLoopModelStep]

    init(
        requests: ToolLoopRecordedRequests,
        steps: [ToolLoopModelStep]
    ) {
        self.requests = requests
        self.steps = steps
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = await requests.append(request)
        guard steps.indices.contains(index) else {
            throw MSPAgentModelClientError.apiError("missing scripted step for request \(index)")
        }
        switch steps[index] {
        case .output(let output, let deltas):
            for delta in deltas {
                await onDelta(delta)
            }
            return output
        case .failure(let error):
            throw error
        }
    }
}

private actor ToolLoopRecordedEvents {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func assistantProgressDeltas() -> [String] {
        events.compactMap { event in
            if case .assistantProgressDelta(let text) = event {
                return text
            }
            return nil
        }
    }

    func finalAnswerDeltas() -> [String] {
        events.compactMap { event in
            if case .finalAnswerDelta(let text) = event {
                return text
            }
            return nil
        }
    }

    func assistantProgressMessages() -> [String] {
        events.compactMap { event in
            if case .assistantProgress(let text) = event {
                return text
            }
            return nil
        }
    }

    func finalAnswers() -> [String] {
        events.compactMap { event in
            if case .finalAnswer(let text) = event {
                return text
            }
            return nil
        }
    }

    func assistantProgressSegmentStartCount() -> Int {
        events.filter { event in
            if case .assistantProgressSegmentStarted = event {
                return true
            }
            return false
        }.count
    }

    func finalAnswerStartCount() -> Int {
        events.filter { event in
            if case .finalAnswerStarted = event {
                return true
            }
            return false
        }.count
    }

    func modelStreamRetryCount() -> Int {
        events.filter { event in
            if case .modelStreamRetrying = event {
                return true
            }
            return false
        }.count
    }

}

private actor ToolLoopPendingInputQueue {
    private var items: [MSPAgentJSONValue]

    init(items: [MSPAgentJSONValue]) {
        self.items = items
    }

    func handle(_ request: MSPAgentToolLoop.PendingInputRequest) -> [MSPAgentJSONValue] {
        switch request {
        case .peek:
            return items
        case .drain:
            let drained = items
            items.removeAll(keepingCapacity: false)
            return drained
        }
    }

    func isEmpty() -> Bool {
        items.isEmpty
    }
}

private actor ToolLoopD02CompactionRecorder {
    private let compactedInput: [MSPAgentJSONValue]
    private var capturedContexts: [MSPAgentToolLoop.MidTurnCompactionContext] = []
    private var installedCompactions = 0

    init(compactedInput: [MSPAgentJSONValue]) {
        self.compactedInput = compactedInput
    }

    func handle(
        _ context: MSPAgentToolLoop.MidTurnCompactionContext
    ) -> MSPAgentToolLoop.MidTurnCompactionUpdate? {
        capturedContexts.append(context)
        guard let usage = context.latestContextUsage,
              usage.currentTokens >= usage.autoCompactTokenLimit else {
            return nil
        }
        installedCompactions += 1
        return MSPAgentToolLoop.MidTurnCompactionUpdate(
            liveInput: compactedInput,
            transcriptAppendItems: [],
            contextUsage: MSPAgentContextUsageRecord(
                modelID: "gpt-5",
                modelDisplayName: "gpt-5",
                contextWindowTokens: 272_000,
                effectiveContextWindowTokens: 258_400,
                autoCompactTokenLimit: 244_800,
                estimatedInputTokens: 120,
                currentTokens: 120,
                serverInputTokens: nil,
                serverOutputTokens: nil,
                serverTotalTokens: nil
            ),
            canDrainPendingInput: !context.modelNeedsFollowUp
        )
    }

    func contexts() -> [MSPAgentToolLoop.MidTurnCompactionContext] {
        capturedContexts
    }

    func compactionCount() -> Int {
        installedCompactions
    }
}
