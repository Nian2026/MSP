@testable import MSPAgentBridge
import MSPCore

enum MSPPlanModeTestSupport {
    static func makeConversation(
        modelClient: any MSPAgentModelTurnClient,
        planModeCapability: MSPPlanModeCapability,
        goalCapability: MSPGoalCapability = .disabled,
        planProgressCapability: MSPPlanProgressCapability = .disabled,
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
                model: "test-model",
                environmentNotes: [
                    "Execution surface: unit test.",
                    "Workspace root visible to you: /"
                ],
                compactionPolicy: .disabled,
                goalCapability: goalCapability,
                planProgressCapability: planProgressCapability,
                planModeCapability: planModeCapability
            )
        )
    }

    static func toolNames(in request: MSPAgentRequestEnvelope) -> [String] {
        request.payload["tools"]?.arrayValue?.compactMap {
            $0.objectValue?["name"]?.stringValue
        } ?? []
    }

    static func text(in object: [String: MSPAgentJSONValue]) -> String {
        object["content"]?.arrayValue?.compactMap {
            $0.objectValue?["text"]?.stringValue
        }.joined(separator: "\n") ?? ""
    }
}

actor MSPPlanModeEventLog {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func signatures() -> [String] {
        events.compactMap { event in
            switch event {
            case .planModeProposalDelta(let event):
                return "delta:\(event.delta)"
            case .planModeProposed(let event):
                return "proposed:\(event.proposalVersion):\(event.proposedPlanContent)"
            default:
                return nil
            }
        }
    }
}

final class MSPPlanModeFinalPlanClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests?
    private let usage: MSPAgentTokenUsage?

    init(
        requests: RecordedModelRequests? = nil,
        usage: MSPAgentTokenUsage? = nil
    ) {
        self.requests = requests
        self.usage = usage
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        if let requests {
            _ = await requests.append(request)
        }
        let text = """
        <proposed_plan>
        - Step 1
        - Step 2
        </proposed_plan>
        """
        return MSPAgentModelTurnOutput(
            finalAnswer: text,
            nativeOutputItems: [
                Self.assistantMessageItem(id: "msg_plan", text: text)
            ],
            tokenUsage: usage
        )
    }

    static func assistantMessageItem(id: String, text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "id": .string(id),
            "role": .string("assistant"),
            "phase": .string("final_answer"),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }
}

final class MSPPlanModeStreamingClient: MSPAgentModelTurnClient, @unchecked Sendable {
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        await onDelta(MSPAgentModelStreamDelta(text: "<pro", phase: .finalAnswer))
        await onDelta(MSPAgentModelStreamDelta(text: "posed_plan>\n- streamed", phase: .finalAnswer))
        await onDelta(MSPAgentModelStreamDelta(text: " step\n</proposed_plan>", phase: .finalAnswer))
        return MSPAgentModelTurnOutput()
    }
}

final class MSPPlanModeUpdatePlanToolClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
                        id: "call_plan_mode",
                        name: .updatePlan,
                        arguments: [
                            "plan": .array([
                                .object([
                                    "step": .string("Should not update"),
                                    "status": .string("in_progress")
                                ])
                            ])
                        ]
                    )
                ],
                nativeOutputItems: [
                    .object([
                        "type": .string("function_call"),
                        "id": .string("fc_plan_mode"),
                        "call_id": .string("call_plan_mode"),
                        "name": .string(MSPAgentToolName.updatePlan.rawValue),
                        "arguments": .string(#"{"plan":[{"step":"Should not update","status":"in_progress"}]}"#)
                    ])
                ]
            )
        }

        let text = "<proposed_plan>\n- Planned after rejected tool\n</proposed_plan>"
        return MSPAgentModelTurnOutput(
            finalAnswer: text,
            nativeOutputItems: [
                MSPPlanModeFinalPlanClient.assistantMessageItem(
                    id: "msg_plan_after_rejected_update_plan",
                    text: text
                )
            ]
        )
    }
}

final class MSPPlanModeBlockingPlanningToolClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
                        id: "call_check",
                        name: .execCommand,
                        arguments: ["cmd": .string("pwd")]
                    )
                ],
                nativeOutputItems: [
                    .object([
                        "type": .string("function_call"),
                        "id": .string("fc_check"),
                        "call_id": .string("call_check"),
                        "name": .string(MSPAgentToolName.execCommand.rawValue),
                        "arguments": .string(#"{"cmd":"pwd"}"#)
                    ])
                ]
            )
        }
        let text = "<proposed_plan>\n- Checked step\n</proposed_plan>"
        return MSPAgentModelTurnOutput(
            finalAnswer: text,
            nativeOutputItems: [
                MSPPlanModeFinalPlanClient.assistantMessageItem(
                    id: "msg_checked_plan",
                    text: text
                )
            ]
        )
    }
}
