import Foundation
import MSPAgentBridge
import MSPCore
import XCTest

final class MSPAgentConversationInterruptTests: XCTestCase {
    func testInterruptBeforeRequestBuildPersistsUserPromptForFollowup() async throws {
        let client = CapturingFinalAnswerModelClient()
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge { _, _ in
                .success(stdout: "")
            }
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
        let gate = DynamicContextGate()

        let runningTurn = Task {
            try await conversation.send(
                "第一轮：这个输入不能丢",
                dynamicDeveloperContextBlocks: [
                    MSPAgentDynamicDeveloperContextBlock(id: "blocked-context") {
                        await gate.waitUntilReleased()
                    }
                ]
            )
        }
        try await gate.waitUntilStarted()

        _ = try await conversation.interruptActiveTurn()

        let followupTurn = Task {
            try await conversation.send("第二轮：继续")
        }
        try await client.waitForRequestCount(1)

        let followupRequest = try await client.request(at: 0)
        XCTAssertEqual(Self.signatures(from: followupRequest.input), [
            "message:developer",
            "message:user:第一轮：这个输入不能丢",
            Self.interruptedMarkerSignature,
            "message:user:第二轮：继续"
        ])

        _ = try await followupTurn.value
        await gate.release()
        let interruptedResult = try await runningTurn.value
        XCTAssertTrue(interruptedResult.wasCancelled)
    }

    private static func signatures(from input: [MSPAgentJSONValue]) -> [String] {
        input.map { item in
            guard let object = item.objectValue else {
                return ""
            }
            let role = object["role"]?.stringValue ?? ""
            let text = messageText(object)
            if role == "developer" {
                return "message:developer"
            }
            return [
                "message",
                role,
                text
            ].joined(separator: ":")
        }
    }

    private static func messageText(_ object: [String: MSPAgentJSONValue]) -> String {
        guard let content = object["content"]?.arrayValue else {
            return ""
        }
        return content.compactMap { item in
            item.objectValue?["text"]?.stringValue
        }.joined(separator: "\n")
    }

    private static var interruptedMarkerSignature: String {
        [
            "message",
            "user",
            MSPAgentInterruptedTurnMarker.text
        ].joined(separator: ":")
    }
}

private actor DynamicContextGate {
    private var isStarted = false
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<String, Never>] = []

    func waitUntilReleased() async -> String {
        isStarted = true
        guard !isReleased else {
            return "released dynamic context"
        }
        return await withCheckedContinuation { continuation in
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
        XCTFail("Timed out waiting for dynamic context refresh to start")
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: "released dynamic context")
        }
    }
}

private final class CapturingFinalAnswerModelClient: MSPAgentModelTurnClient, @unchecked Sendable {
    private let requests = CapturedAgentRequests()

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        await requests.append(request)
        return MSPAgentModelTurnOutput(finalAnswer: "继续。")
    }

    func waitForRequestCount(_ count: Int) async throws {
        try await requests.waitForCount(count)
    }

    func request(at index: Int) async throws -> MSPAgentRequestEnvelope {
        try await requests.request(at: index)
    }
}

private actor CapturedAgentRequests {
    private var requests: [MSPAgentRequestEnvelope] = []

    func append(_ request: MSPAgentRequestEnvelope) {
        requests.append(request)
    }

    func request(at index: Int) throws -> MSPAgentRequestEnvelope {
        guard requests.indices.contains(index) else {
            throw XCTSkip("missing captured request at index \(index)")
        }
        return requests[index]
    }

    func waitForCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if requests.count >= count {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(count) captured requests")
    }
}
