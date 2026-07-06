import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

final class MSPTurnSteerTimingTests: MSPAgentConversationRequestTestCase {
    func testDisabledSteerActiveTurnRejectsCapabilityDisabled() async throws {
        let conversation = Self.makeConversation(
            modelClient: GatedCompactionModelClient(
                requests: RecordedModelRequests(),
                gate: ModelTurnReleaseGate()
            ),
            turnSteerCapability: .disabled
        )

        do {
            _ = try await conversation.steerActiveTurn("disabled steer")
            XCTFail("Expected disabled active-turn steer to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .capabilityDisabled)
            XCTAssertEqual(error.reason, .capabilityDisabled)
        }
    }

    func testMaintenanceTurnSteerIsRejectedAsNonSteerable() async throws {
        let requests = RecordedModelRequests()
        let gate = ModelTurnReleaseGate()
        let conversation = Self.makeConversation(
            modelClient: GatedCompactionModelClient(
                requests: requests,
                gate: gate
            )
        )

        let compactTurn = Task {
            try await conversation.compactLocal()
        }
        try await requests.waitForCount(1)
        let active = try await Self.waitForActiveSteerTarget(in: conversation)
        XCTAssertEqual(active.kind, .maintenance)

        do {
            _ = try await conversation.steerActiveTurn("compact turn steer")
            XCTFail("Expected maintenance turn steer to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .activeTurnNotSteerable(
                turnID: active.turnID,
                kind: .maintenance
            ))
            XCTAssertEqual(error.reason, .activeTurnNotSteerable)
        }

        await gate.release()
        _ = try await compactTurn.value
    }

    func testSteerBeforeFirstModelOutputAppliesToSameTurnContinuation() async throws {
        let requests = RecordedModelRequests()
        let firstModelGate = ModelTurnReleaseGate()
        let conversation = Self.makeConversation(
            modelClient: GatedFirstToolCallModelClient(
                requests: requests,
                firstModelGate: firstModelGate
            ),
            commandRunner: { command in
                XCTAssertEqual(command, "pwd")
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("先决定要不要用工具")
        }
        try await requests.waitForCount(1)

        let handle = try await conversation.steerActiveTurn("模型返回工具调用前的 steer")
        await firstModelGate.release()
        try await requests.waitForCount(2)

        let applied = try await handle.appliedEvent()
        XCTAssertEqual(applied.boundary, .modelInput)

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input).suffix(2), [
            "function_call_output:call_pre_model:exec_output;exit=0;output=/\n",
            "message:user:模型返回工具调用前的 steer"
        ])

        _ = try await runningTurn.value
    }

    func testSteerAfterToolResultBeforeNextModelRequestAppliesInOrder() async throws {
        let requests = RecordedModelRequests()
        let toolCompletedGate = ToolCompletedEventGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { command in
                XCTAssertEqual(command, "sleep 3000")
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("工具完成后再 steering", onEvent: { event in
                await toolCompletedGate.handle(event)
            })
        }
        try await requests.waitForCount(1)
        try await toolCompletedGate.waitUntilBlocked()

        let handle = try await conversation.steerActiveTurn("工具结果已经有了之后的 steer")
        await toolCompletedGate.release()
        try await requests.waitForCount(2)

        let applied = try await handle.appliedEvent()
        XCTAssertEqual(applied.boundary, .modelInput)

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input).suffix(2), [
            "function_call_output:call_blocked:exec_output;exit=0;output=/\n",
            "message:user:工具结果已经有了之后的 steer"
        ])

        _ = try await runningTurn.value
    }

    func testAppliedSteerBecomesHistoryWithoutPendingDuplicateOnNextTurn() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let firstTurn = Task {
            try await conversation.send("第一轮要用工具")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        let handle = try await conversation.steerActiveTurn("只保留一次的 steer")
        await gate.release()
        try await requests.waitForCount(2)
        _ = try await handle.appliedEvent()
        _ = try await firstTurn.value

        _ = try await conversation.send("第二轮 unrelated prompt")
        try await requests.waitForCount(3)

        let thirdRequest = try await requests.request(at: 2)
        let input = thirdRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        let texts = Self.messageTexts(from: input)
        XCTAssertEqual(texts.filter { $0 == "只保留一次的 steer" }.count, 1)
        XCTAssertTrue(texts.contains("第二轮 unrelated prompt"))
        XCTAssertFalse(Self.signatures(from: input).suffix(2).allSatisfy {
            $0 == "message:user:只保留一次的 steer"
        })
    }

    private static func makeConversation(
        modelClient: any MSPAgentModelTurnClient,
        turnSteerCapability: MSPTurnSteerCapability = .enabled,
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
                turnSteerCapability: turnSteerCapability
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
}
