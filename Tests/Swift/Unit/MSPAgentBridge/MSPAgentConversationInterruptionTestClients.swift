import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


actor RecordedModelRequests {
    private var requests: [MSPAgentRequestEnvelope] = []

    func append(_ request: MSPAgentRequestEnvelope) -> Int {
        let index = requests.count
        requests.append(request)
        return index
    }

    func count() -> Int {
        requests.count
    }

    func request(at index: Int) throws -> MSPAgentRequestEnvelope {
        guard requests.indices.contains(index) else {
            return try XCTUnwrap(nil as MSPAgentRequestEnvelope?)
        }
        return requests[index]
    }

    func waitForCount(_ targetCount: Int) async throws {
        for _ in 0..<200 {
            if requests.count >= targetCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(targetCount) model requests; saw \(requests.count)")
    }
}

actor BlockingCommandGate {
    private var isStarted = false
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func runUntilReleased() async {
        isStarted = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<200 {
            if isStarted {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for blocking command to start")
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

actor ModelTurnReleaseGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pendingContinuations = continuations
        self.continuations.removeAll(keepingCapacity: true)
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}

final class BlockingToolModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
                assistantMessage: "我会运行一个慢命令。",
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_blocked",
                        name: .execCommand,
                        arguments: ["cmd": .string("sleep 3000")]
                    )
                ],
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_blocked",
                        phase: "assistant_message",
                        text: "我会运行一个慢命令。"
                    ),
                    Self.functionCallItem(
                        id: "fc_blocked",
                        callID: "call_blocked",
                        command: "sleep 3000"
                    )
                ]
            )
        }
        return MSPAgentModelTurnOutput(
            finalAnswer: "继续。",
            nativeOutputItems: [
                Self.assistantMessageItem(
                    id: "msg_followup_after_blocked",
                    phase: "final_answer",
                    text: "继续。"
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

final class LateUsageAfterInterruptModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests: RecordedModelRequests
    private let firstTurnGate: ModelTurnReleaseGate

    init(requests: RecordedModelRequests, firstTurnGate: ModelTurnReleaseGate) {
        self.requests = requests
        self.firstTurnGate = firstTurnGate
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
            await firstTurnGate.waitUntilReleased()
            return Self.finalAnswer(
                id: "msg_late_usage",
                text: "旧 turn 晚返回。",
                inputTokens: 260_000,
                outputTokens: 20_000,
                totalTokens: 280_000
            )

        case 1:
            return Self.finalAnswer(
                id: "msg_followup_low_usage",
                text: "第二轮完成。",
                inputTokens: 10,
                outputTokens: 10,
                totalTokens: 20
            )

        default:
            return Self.finalAnswer(
                id: "msg_third_after_interrupt",
                text: "第三轮完成。",
                inputTokens: 10,
                outputTokens: 10,
                totalTokens: 20
            )
        }
    }

    private static func finalAnswer(
        id: String,
        text: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) -> MSPAgentModelTurnOutput {
        MSPAgentModelTurnOutput(
            finalAnswer: text,
            responseID: "resp_\(id)",
            nativeOutputItems: [
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
            ],
            tokenUsage: MSPAgentTokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens
            )
        )
    }
}

final class CancellingAfterToolResultModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
                assistantMessage: "我先看一下工作区。",
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_cancel",
                        name: .execCommand,
                        arguments: ["cmd": .string("pwd")]
                    )
                ],
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_cancel",
                        phase: "assistant_message",
                        text: "我先看一下工作区。"
                    ),
                    Self.functionCallItem(
                        id: "fc_cancel",
                        callID: "call_cancel",
                        command: "pwd"
                    )
                ]
            )
        case 1:
            await onDelta(MSPAgentModelStreamDelta(
                text: "我已经看到了 /。",
                phase: .finalAnswer
            ))
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        default:
            return MSPAgentModelTurnOutput(
                finalAnswer: "继续。",
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_followup",
                        phase: "final_answer",
                        text: "继续。"
                    )
                ]
            )
        }
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

final class MidTurnCompactionBlockingContinuationModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
                assistantMessage: "我先看一下工作区。",
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_mid_compact",
                        name: .execCommand,
                        arguments: ["cmd": .string("pwd")]
                    )
                ],
                responseID: "resp_mid_compact_tool",
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_mid_compact",
                        phase: "assistant_message",
                        text: "我先看一下工作区。"
                    ),
                    Self.functionCallItem(
                        id: "fc_mid_compact",
                        callID: "call_mid_compact",
                        command: "pwd"
                    )
                ],
                tokenUsage: MSPAgentTokenUsage(
                    inputTokens: 260_000,
                    outputTokens: 20_000,
                    totalTokens: 280_000
                )
            )

        case 1:
            return MSPAgentModelTurnOutput(
                assistantMessage: "中途工具结果已经压缩。",
                responseID: "resp_mid_compact_summary",
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_mid_compact_summary",
                        phase: "assistant_message",
                        text: "中途工具结果已经压缩。"
                    )
                ]
            )

        case 2:
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()

        default:
            return MSPAgentModelTurnOutput(
                finalAnswer: "继续。",
                responseID: "resp_mid_compact_followup",
                nativeOutputItems: [
                    Self.assistantMessageItem(
                        id: "msg_mid_compact_followup",
                        phase: "final_answer",
                        text: "继续。"
                    )
                ]
            )
        }
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
