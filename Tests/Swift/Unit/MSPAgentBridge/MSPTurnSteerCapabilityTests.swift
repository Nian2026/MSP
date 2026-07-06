import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

final class MSPTurnSteerCapabilityTests: MSPAgentConversationRequestTestCase {
    func testCapabilityDisabledDeclarationAndAPIReject() async throws {
        let conversation = Self.makeConversation(
            modelClient: SteerOneShotFinalAnswerClient(),
            turnSteerCapability: .disabled
        )

        let declaration = await conversation.turnSteerCapabilityDeclaration()
        XCTAssertFalse(declaration.enabled)
        XCTAssertEqual(declaration.methods, [])
        let currentTarget = await conversation.currentTurnSteerTarget()
        XCTAssertNil(currentTarget)

        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: conversation.threadID,
                turnID: "turn-1",
                input: MSPTurnSteerInput(text: "steer")
            ))
            XCTFail("Expected disabled steer capability to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .capabilityDisabled)
            XCTAssertEqual(error.reason, .capabilityDisabled)
        }
    }

    func testNoActiveTurnSteerFails() async throws {
        let conversation = Self.makeConversation(
            modelClient: SteerOneShotFinalAnswerClient()
        )

        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: conversation.threadID,
                turnID: "turn-missing",
                input: MSPTurnSteerInput(text: "steer")
            ))
            XCTFail("Expected no-active-turn steer to fail")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .noActiveTurn(turnID: "turn-missing"))
            XCTAssertEqual(error.reason, .noActiveTurn)
        }
    }

    func testWrongTurnIDSteerFails() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { command in
                XCTAssertEqual(command, "sleep 3000")
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行慢命令")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        let active = try await Self.waitForActiveSteerTarget(in: conversation)
        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: active.threadID,
                turnID: "wrong-turn",
                input: MSPTurnSteerInput(text: "steer")
            ))
            XCTFail("Expected wrong expected turn id to fail")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .expectedTurnMismatch(
                expected: "wrong-turn",
                actual: active.turnID
            ))
            XCTAssertEqual(error.reason, .expectedTurnMismatch)
        }

        _ = try await conversation.interruptActiveTurn()
        await gate.release()
        _ = try await runningTurn.value
    }

    func testTerminalTurnSteerFails() async throws {
        let events = SteerEventLog()
        let conversation = Self.makeConversation(
            modelClient: SteerOneShotFinalAnswerClient()
        )

        _ = try await conversation.send("完成这一轮", onEvent: { event in
            await events.append(event)
        })
        let startedIDs = await events.turnStartedIDs()
        let turnID = try XCTUnwrap(startedIDs.first)

        do {
            _ = try await conversation.steerTurn(MSPTurnSteerRequest(
                threadID: conversation.threadID,
                turnID: turnID,
                input: MSPTurnSteerInput(text: "too late")
            ))
            XCTFail("Expected terminal turn steer to fail")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error, .terminalTurn(turnID: turnID, status: .completed))
            XCTAssertEqual(error.reason, .terminalTurn)
        }
    }

    func testActiveTurnSteerReturnsTypedHandleAndAppliesToToolLoop() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let events = SteerEventLog()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { command in
                XCTAssertEqual(command, "sleep 3000")
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行慢命令", onEvent: { event in
                await events.append(event)
            })
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let active = try await Self.waitForActiveSteerTarget(in: conversation)

        let handle = try await conversation.steerActiveTurn(
            "请把后续回答缩短",
            clientUserMessageID: "client-steer-1"
        )
        XCTAssertEqual(handle.target.turnID, active.turnID)
        XCTAssertEqual(handle.target.startedAt, active.startedAt)
        XCTAssertEqual(handle.sequenceNumber, 1)
        XCTAssertLessThanOrEqual(handle.requestedAt, handle.acceptedAt)

        await gate.release()
        try await requests.waitForCount(2)
        let applied = try await handle.appliedEvent()
        XCTAssertEqual(applied.boundary, .modelInput)
        XCTAssertEqual(applied.sequenceNumber, 1)
        XCTAssertEqual(applied.clientUserMessageID, "client-steer-1")

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input).suffix(2), [
            "function_call_output:call_blocked:exec_output;exit=0;output=/\n",
            "message:user:请把后续回答缩短"
        ])
        let steerSignatures = await events.steerSignatures()
        XCTAssertEqual(steerSignatures, [
            "accepted:1:请把后续回答缩短",
            "applied:1:model_input:请把后续回答缩短"
        ])

        _ = try await runningTurn.value
    }

    func testMultipleSteersPreserveFIFOOrderAndDoNotCreateNewTurn() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let events = SteerEventLog()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("先执行工具", onEvent: { event in
                await events.append(event)
            })
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let active = try await Self.waitForActiveSteerTarget(in: conversation)

        let first = try await conversation.steerTurn(MSPTurnSteerRequest(
            threadID: active.threadID,
            turnID: active.turnID,
            input: MSPTurnSteerInput(text: "第一条 steer")
        ))
        let second = try await conversation.steerTurn(MSPTurnSteerRequest(
            threadID: active.threadID,
            turnID: active.turnID,
            input: MSPTurnSteerInput(text: "第二条 steer")
        ))
        XCTAssertEqual(first.sequenceNumber, 1)
        XCTAssertEqual(second.sequenceNumber, 2)
        let turnStartedIDs = await events.turnStartedIDs()
        XCTAssertEqual(turnStartedIDs.count, 1)

        await gate.release()
        try await requests.waitForCount(2)

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input).suffix(3), [
            "function_call_output:call_blocked:exec_output;exit=0;output=/\n",
            "message:user:第一条 steer",
            "message:user:第二条 steer"
        ])

        _ = try await runningTurn.value
    }

    func testSteerDuringStreamingAssistantPartialDoesNotCommitPartialAsHistory() async throws {
        let requests = RecordedModelRequests()
        let firstModelGate = ModelTurnReleaseGate()
        let client = StreamingPartialThenSteerClient(
            requests: requests,
            firstModelGate: firstModelGate
        )
        let conversation = Self.makeConversation(modelClient: client)

        let runningTurn = Task {
            try await conversation.send("开始")
        }
        try await requests.waitForCount(1)
        let handle = try await conversation.steerActiveTurn("补充 steer")
        await firstModelGate.release()

        try await requests.waitForCount(2)
        let applied = try await handle.appliedEvent()
        XCTAssertEqual(applied.boundary, .modelInput)

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:开始",
            "message:user:补充 steer"
        ])
        XCTAssertFalse(Self.messageTexts(from: input).contains("partial assistant"))

        _ = try await runningTurn.value
    }

    func testSteerThenInterruptPreservesSteerAndRejectsPostInterruptSteer() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: BlockingToolModelClient(requests: requests),
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "late\n")
            }
        )

        let runningTurn = Task {
            try await conversation.send("运行会被停止的命令")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        let steerHandle = try await conversation.steerActiveTurn("停止前保留这条 steer")
        _ = try await conversation.interruptActiveTurn()
        do {
            _ = try await conversation.steerActiveTurn("stop 后不该写入")
            XCTFail("Expected steer after interrupt to fail")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error.reason, .interruptedTurn)
        }

        let followupTurn = Task {
            try await conversation.send("继续")
        }
        try await requests.waitForCount(2)
        let applied = try await steerHandle.appliedEvent()
        XCTAssertEqual(applied.boundary, .interruptedTranscript)

        let followupRequest = try await requests.request(at: 1)
        let input = followupRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertEqual(Self.signatures(from: input), [
            "message:developer",
            "message:user:运行会被停止的命令",
            "message:assistant:commentary:我会运行一个慢命令。",
            "function_call:exec_command:call_blocked",
            "function_call_output:call_blocked:aborted",
            "message:user:停止前保留这条 steer",
            Self.interruptedMarkerSignature,
            "message:user:继续"
        ])

        _ = try await followupTurn.value
        await gate.release()
        let cancelled = try await runningTurn.value
        XCTAssertTrue(cancelled.wasCancelled)
    }

    func testChatMappingWritesCanonicalTurnSteeredShape() {
        let event = MSPTurnSteerAppliedEvent(
            threadID: "thread",
            turnID: "turn-1",
            sequenceNumber: 3,
            contentText: "steer text",
            clientUserMessageID: "client-1",
            requestedAt: Date(timeIntervalSince1970: 1),
            acceptedAt: Date(timeIntervalSince1970: 2),
            appliedAt: Date(timeIntervalSince1970: 3),
            boundary: .modelInput,
            modelInputItemCount: 1
        )

        let reference = MSPTurnSteerChatMapping.referenceContextEvent(for: event)
        let object = reference.objectValue
        XCTAssertEqual(object?["kind"]?.stringValue, "turn_steered")
        XCTAssertEqual(object?["id"]?.stringValue, "turn-1#3")
        XCTAssertEqual(object?["sequence"]?.intValue, 3)

        let payload = MSPTurnSteerChatMapping.timelinePayload(for: event)
        XCTAssertEqual(payload["turn_id"]?.stringValue, "turn-1")
        XCTAssertEqual(payload["sequence"]?.intValue, 3)
        XCTAssertEqual(payload["content"]?.stringValue, "steer text")
        XCTAssertEqual(payload["boundary"]?.stringValue, "model_input")
        XCTAssertEqual(payload["client_user_message_id"]?.stringValue, "client-1")
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

private actor SteerEventLog {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func turnStartedIDs() -> [String] {
        events.compactMap { event in
            if case .turnStarted(let event) = event {
                return event.turnID
            }
            return nil
        }
    }

    func steerSignatures() -> [String] {
        events.compactMap { event in
            switch event {
            case .turnSteerAccepted(let accepted):
                return "accepted:\(accepted.sequenceNumber):\(accepted.contentText)"
            case .turnSteerApplied(let applied):
                return "applied:\(applied.sequenceNumber):\(applied.boundary.rawValue):\(applied.contentText)"
            default:
                return nil
            }
        }
    }
}

private final class SteerOneShotFinalAnswerClient: MSPAgentModelTurnClient, @unchecked Sendable {
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        MSPAgentModelTurnOutput(
            finalAnswer: "完成。",
            nativeOutputItems: [
                .object([
                    "type": .string("message"),
                    "id": .string("msg_steer_one_shot"),
                    "role": .string("assistant"),
                    "phase": .string("final_answer"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string("完成。")
                        ])
                    ])
                ])
            ]
        )
    }
}

private final class StreamingPartialThenSteerClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
            await onDelta(MSPAgentModelStreamDelta(
                text: "partial assistant",
                phase: .assistantMessage
            ))
            await firstModelGate.waitUntilReleased()
            return MSPAgentModelTurnOutput(finalAnswer: "would finish")
        }
        return MSPAgentModelTurnOutput(
            finalAnswer: "steered final",
            nativeOutputItems: [
                .object([
                    "type": .string("message"),
                    "id": .string("msg_steered_final"),
                    "role": .string("assistant"),
                    "phase": .string("final_answer"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string("steered final")
                        ])
                    ])
                ])
            ]
        )
    }
}
