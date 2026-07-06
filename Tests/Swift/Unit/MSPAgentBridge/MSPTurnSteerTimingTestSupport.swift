import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

actor ToolCompletedEventGate {
    private var isBlocked = false
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func handle(_ event: MSPAgentEvent) async {
        guard case .toolCompleted = event, !isBlocked else {
            return
        }
        isBlocked = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilBlocked() async throws {
        for _ in 0..<200 {
            if isBlocked {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for tool-completed event gate")
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

final class GatedCompactionModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests
    private let gate: ModelTurnReleaseGate

    init(requests: RecordedModelRequests, gate: ModelTurnReleaseGate) {
        self.requests = requests
        self.gate = gate
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        _ = await requests.append(request)
        await gate.waitUntilReleased()
        return MSPAgentModelTurnOutput(
            finalAnswer: "compaction summary",
            nativeOutputItems: [
                Self.assistantMessageItem(
                    id: "msg_compaction_summary",
                    phase: "final_answer",
                    text: "compaction summary"
                )
            ]
        )
    }

    private static func assistantMessageItem(
        id: String,
        phase: String,
        text: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "id": .string(id),
            "role": .string("assistant"),
            "phase": .string(phase),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }
}

final class GatedFirstToolCallModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests
    private let firstModelGate: ModelTurnReleaseGate

    init(
        requests: RecordedModelRequests,
        firstModelGate: ModelTurnReleaseGate
    ) {
        self.requests = requests
        self.firstModelGate = firstModelGate
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = await requests.append(request)
        if index == 0 {
            await firstModelGate.waitUntilReleased()
            return MSPAgentModelTurnOutput(
                assistantMessage: "我会先运行 pwd。",
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_pre_model",
                        name: .execCommand,
                        arguments: ["cmd": .string("pwd")]
                    )
                ],
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_pre_model",
                        phase: "assistant_message",
                        text: "我会先运行 pwd。"
                    ),
                    Self.functionCallItem(
                        id: "fc_pre_model",
                        callID: "call_pre_model",
                        command: "pwd"
                    )
                ]
            )
        }
        return MSPAgentModelTurnOutput(
            finalAnswer: "完成。",
            nativeOutputItems: [
                Self.assistantMessageItem(
                    id: "msg_pre_model_final",
                    phase: "final_answer",
                    text: "完成。"
                )
            ]
        )
    }

    private static func assistantMessageItem(
        id: String,
        phase: String,
        text: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "id": .string(id),
            "role": .string("assistant"),
            "phase": .string(phase),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private static func functionCallItem(
        id: String,
        callID: String,
        command: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("function_call"),
            "id": .string(id),
            "call_id": .string(callID),
            "name": .string(MSPAgentToolName.execCommand.rawValue),
            "arguments": .string(#"{"cmd":"\#(command)"}"#)
        ])
    }
}
