import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

extension MSPGoalCapabilityTests {
    static func makeConversation(
        modelClient: any MSPAgentModelTurnClient,
        model: String = "test-model",
        goalCapability: MSPGoalCapability,
        commandRunner: @escaping @Sendable (String) async -> MSPCommandResult = { _ in
            .success(stdout: "")
        }
    ) -> MSPAgentConversation {
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in modelClient },
            execCommandBridge: MSPExecCommandBridge(runCommand: commandRunner)
        )
        return runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: model,
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ],
                compactionPolicy: .disabled,
                goalCapability: goalCapability
            )
        )
    }

    static func makeConversation(
        threadID: String,
        modelClient: any MSPAgentModelTurnClient,
        model: String = "test-model",
        goalCapability: MSPGoalCapability,
        commandRunner: @escaping @Sendable (String) async -> MSPCommandResult = { _ in
            .success(stdout: "")
        }
    ) -> MSPAgentConversation {
        MSPAgentConversation(
            configuration: MSPAgentConversationConfiguration(
                model: model,
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ],
                compactionPolicy: .disabled,
                goalCapability: goalCapability
            ),
            modelClient: modelClient,
            execCommandBridge: MSPExecCommandBridge(runCommand: commandRunner),
            requestBuilder: MSPAgentRequestBuilder(),
            toolCallLimit: .unlimited,
            chatID: threadID
        )
    }

    static func firstRequest(
        for modelClient: any MSPAgentModelTurnClient,
        goalCapability: MSPGoalCapability
    ) throws -> MSPAgentRequestEnvelope {
        let configuration = MSPAgentConversationConfiguration(
            model: "test-model",
            environmentNotes: [
                "Execution surface: unit test.",
                "Workspace root visible to you: /"
            ],
            compactionPolicy: .disabled,
            goalCapability: goalCapability
        )
        let body = MSPAgentRequestBuilder().build(
            context: configuration.requestContext(prompt: "hello")
        )
        return try MSPAgentRequestBuilder().envelope(from: body)
    }

    static func toolNames(in request: MSPAgentRequestEnvelope) -> [String] {
        request.payload["tools"]?.arrayValue?.compactMap {
            $0.objectValue?["name"]?.stringValue
        } ?? []
    }

    static func contextUsage(
        input: Int,
        cachedInput: Int = 0,
        output: Int
    ) -> MSPAgentContextUsageRecord {
        MSPAgentContextUsageRecord(
            modelID: "gpt-5-test",
            modelDisplayName: "gpt-5-test",
            contextWindowTokens: 272_000,
            effectiveContextWindowTokens: 258_400,
            autoCompactTokenLimit: 244_800,
            estimatedInputTokens: 0,
            currentTokens: input + output,
            serverInputTokens: input,
            serverCachedInputTokens: cachedInput,
            serverOutputTokens: output,
            serverTotalTokens: input + output
        )
    }
}

actor GoalEventLog {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func goalSignatures() -> [String] {
        events.compactMap { event in
            switch event {
            case .threadGoalUpdated(let event):
                return "updated:\(event.reason.rawValue):\(event.goal.status.rawValue)"
            case .threadGoalAccounted(let event):
                return "accounted:\(event.tokenDelta):\(event.status.rawValue)"
            case .threadGoalCleared(let event):
                return "cleared:\(event.clearedGoal != nil)"
            default:
                return nil
            }
        }
    }
}

final class GoalFinalAnswerClient: MSPAgentModelTurnClient, @unchecked Sendable {
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        MSPAgentModelTurnOutput(finalAnswer: "done")
    }
}

final class GoalRecordingFinalAnswerClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests

    init(requests: RecordedModelRequests) {
        self.requests = requests
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        _ = await requests.append(request)
        return MSPAgentModelTurnOutput(finalAnswer: "done")
    }
}

final class GoalBudgetModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests

    init(requests: RecordedModelRequests) {
        self.requests = requests
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = await requests.append(request)
        switch index {
        case 0:
            return MSPAgentModelTurnOutput(
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_create_goal",
                        name: .createGoal,
                        arguments: [
                            "objective": .string("budget-limited test"),
                            "token_budget": .number(25)
                        ]
                    )
                ],
                nativeOutputItems: [
                    Self.functionCallItem(
                        id: "fc_goal",
                        callID: "call_create_goal",
                        name: MSPGoalTools.createGoalName,
                        argumentsJSON: #"{"objective":"budget-limited test","token_budget":25}"#
                    )
                ]
            )
        case 1:
            return MSPAgentModelTurnOutput(
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_pwd",
                        name: .execCommand,
                        arguments: ["cmd": .string("pwd")]
                    )
                ],
                nativeOutputItems: [
                    Self.functionCallItem(
                        id: "fc_pwd",
                        callID: "call_pwd",
                        name: MSPAgentToolName.execCommand.rawValue,
                        argumentsJSON: #"{"cmd":"pwd"}"#
                    )
                ],
                tokenUsage: MSPAgentTokenUsage(
                    inputTokens: 40,
                    outputTokens: 10,
                    totalTokens: 50
                )
            )
        default:
            return MSPAgentModelTurnOutput(finalAnswer: "done")
        }
    }

    static func functionCallItem(
        id: String,
        callID: String,
        name: String,
        argumentsJSON: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call"),
            "id": .string(id),
            "call_id": .string(callID),
            "name": .string(name),
            "arguments": .string(argumentsJSON)
        ])
    }
}

final class GoalBlockingToolModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests

    init(requests: RecordedModelRequests) {
        self.requests = requests
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = await requests.append(request)
        if index == 0 {
            return MSPAgentModelTurnOutput(
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_blocked",
                        name: .execCommand,
                        arguments: ["cmd": .string("sleep 3000")]
                    )
                ],
                nativeOutputItems: [
                    .object([
                        "type": .string("function_call"),
                        "id": .string("fc_blocked"),
                        "call_id": .string("call_blocked"),
                        "name": .string(MSPAgentToolName.execCommand.rawValue),
                        "arguments": .string(#"{"cmd":"sleep 3000"}"#)
                    ])
                ]
            )
        }
        return MSPAgentModelTurnOutput(finalAnswer: "done")
    }
}
