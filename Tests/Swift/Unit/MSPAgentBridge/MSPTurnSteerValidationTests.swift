import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

final class MSPTurnSteerValidationTests: MSPAgentConversationRequestTestCase {
    func testEmptyExpectedTurnIDFailsBeforeWritingPendingInput() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行工具")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: conversation.threadID,
                turnID: "",
                input: MSPTurnSteerInput(text: "steer")
            ))
            XCTFail("Expected empty expected turn id to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .emptyExpectedTurnID)
            XCTAssertEqual(error.reason, .emptyExpectedTurnID)
        }

        await gate.release()
        _ = try await runningTurn.value
    }

    func testEmptyInputFailsWithoutMergingAdditionalContext() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行工具")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let active = try await Self.waitForActiveSteerTarget(in: conversation)

        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: active.threadID,
                turnID: active.turnID,
                input: MSPTurnSteerInput(
                    content: [],
                    additionalContextItems: [Self.syntheticUserMessage("context only")]
                )
            ))
            XCTFail("Expected empty steer input to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .emptyInput)
            XCTAssertEqual(error.reason, .emptyInput)
        }

        await gate.release()
        try await requests.waitForCount(2)
        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertFalse(Self.messageTexts(from: input).contains("context only"))

        _ = try await runningTurn.value
    }

    func testWrongThreadIDFailsWithoutAcceptingSteer() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行工具")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let active = try await Self.waitForActiveSteerTarget(in: conversation)

        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: "wrong-thread",
                turnID: active.turnID,
                input: MSPTurnSteerInput(text: "steer")
            ))
            XCTFail("Expected wrong thread id to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .threadMismatch(
                expected: "wrong-thread",
                actual: active.threadID
            ))
            XCTAssertEqual(error.reason, .threadMismatch)
        }

        await gate.release()
        _ = try await runningTurn.value
    }

    func testAdditionalContextItemsPrecedeSteerUserInput() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行工具")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        let handle = try await conversation.steerActiveTurn(MSPTurnSteerInput(
            text: "带 context 的 steer",
            additionalContextItems: [
                Self.syntheticUserMessage("steer additional context")
            ]
        ))
        await gate.release()
        try await requests.waitForCount(2)
        _ = try await handle.appliedEvent()

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input).suffix(3), [
            "function_call_output:call_blocked:exec_output;exit=0;output=/\n",
            "message:user:steer additional context",
            "message:user:带 context 的 steer"
        ])

        _ = try await runningTurn.value
    }

    private static func makeConversation(
        modelClient: any MSPAgentModelTurnClient,
        commandRunner: @escaping @Sendable (String) async -> MSPCommandResult
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
                ]
            )
        )
    }

    private static func waitForActiveSteerTarget(
        in conversation: MSPAgentConversation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> MSPTurnSteerActiveTurn {
        for _ in 0..<100 {
            if let active = await conversation.currentTurnSteerTarget() {
                return active
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for active steer target", file: file, line: line)
        throw MSPTurnSteerError.noActiveTurn(turnID: "")
    }

    private static func syntheticUserMessage(_ text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }
}
