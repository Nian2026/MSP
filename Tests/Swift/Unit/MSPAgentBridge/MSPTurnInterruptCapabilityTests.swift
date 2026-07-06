import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

final class MSPTurnInterruptCapabilityTests: XCTestCase {
    func testInterruptTurnByExactTurnIDSucceedsAndEmitsTurnAborted() async throws {
        let requests = RecordedModelRequests()
        let client = BlockingToolModelClient(requests: requests)
        let gate = BlockingCommandGate()
        let events = RecordedAgentEvents()
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge { _, _ in
                await gate.runUntilReleased()
                return .success(stdout: "late\n")
            }
        )
        let conversation = runtime.makeConversation(
            configuration: Self.configuration()
        )

        let runningTurn = Task {
            try await conversation.send(
                "第一轮：运行慢命令",
                onEvent: { await events.append($0) }
            )
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let currentTarget = await conversation.currentTurnInterruptTarget()
        let target = try XCTUnwrap(currentTarget)

        let response = try await conversation.interruptTurn(MSPTurnInterruptRequest(
            threadID: target.threadID,
            turnID: target.turnID
        ))

        XCTAssertEqual(response.turnID, target.turnID)
        XCTAssertEqual(response.reason, .interrupted)
        XCTAssertEqual(response.terminalEvent?.turnID, target.turnID)
        XCTAssertEqual(response.terminalEvent?.reason, .interrupted)
        let lifecycle = await events.turnLifecycleSignatures()
        XCTAssertTrue(lifecycle.contains("turnAborted:\(target.turnID):interrupted"))

        await gate.release()
        let result = try await runningTurn.value
        XCTAssertTrue(result.wasCancelled)
    }

    func testInterruptActiveTurnReturnsHandleWithStartedAndTerminalFacts() async throws {
        let requests = RecordedModelRequests()
        let client = BlockingToolModelClient(requests: requests)
        let gate = BlockingCommandGate()
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge { _, _ in
                await gate.runUntilReleased()
                return .success(stdout: "late\n")
            }
        )
        let conversation = runtime.makeConversation(
            configuration: Self.configuration()
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：运行慢命令")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let activeTarget = await conversation.currentTurnInterruptTarget()
        let currentTarget = try XCTUnwrap(activeTarget)

        let activeHandle = try await conversation.interruptActiveTurn()
        let handle = try XCTUnwrap(activeHandle)

        XCTAssertEqual(handle.target.threadID, currentTarget.threadID)
        XCTAssertEqual(handle.target.turnID, currentTarget.turnID)
        XCTAssertEqual(handle.target.status, .running)
        XCTAssertEqual(handle.target.startedAt, currentTarget.startedAt)
        XCTAssertGreaterThanOrEqual(
            handle.requestedAt.timeIntervalSince(handle.target.startedAt),
            0
        )
        let activeInterruptingTarget = await conversation.currentTurnInterruptTarget()
        let interruptingTarget = try XCTUnwrap(activeInterruptingTarget)
        XCTAssertEqual(interruptingTarget.turnID, handle.target.turnID)
        XCTAssertEqual(interruptingTarget.status, .interrupting)

        let response = try await handle.terminalResponse()
        XCTAssertEqual(response.turnID, handle.target.turnID)
        XCTAssertEqual(response.reason, .interrupted)
        XCTAssertEqual(response.terminalEvent?.turnID, handle.target.turnID)
        XCTAssertEqual(response.terminalEvent?.reason, .interrupted)
        XCTAssertNotNil(response.terminalEvent?.completedAt)
        XCTAssertNotNil(response.terminalEvent?.durationMilliseconds)

        await gate.release()
        let result = try await runningTurn.value
        XCTAssertTrue(result.wasCancelled)
    }

    func testInterruptTurnResponseWaitsForAbortBoundary() async throws {
        let requests = RecordedModelRequests()
        let client = BlockingToolModelClient(requests: requests)
        let gate = BlockingCommandGate()
        let probe = InterruptCompletionProbe()
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge { _, _ in
                await gate.runUntilReleased()
                return .success(stdout: "late\n")
            }
        )
        let conversation = runtime.makeConversation(
            configuration: Self.configuration(
                turnInterruptCapability: .enabled(
                    gracefulAbortTimeoutNanoseconds: 200_000_000
                )
            )
        )

        let runningTurn = Task {
            try await conversation.send("第一轮：运行慢命令")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let currentTarget = await conversation.currentTurnInterruptTarget()
        let target = try XCTUnwrap(currentTarget)

        let interruptTask = Task {
            let response = try await conversation.interruptTurn(MSPTurnInterruptRequest(
                threadID: target.threadID,
                turnID: target.turnID
            ))
            await probe.markCompleted()
            return response
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        let completedEarly = await probe.isCompleted()
        XCTAssertFalse(completedEarly)

        let response = try await interruptTask.value
        XCTAssertEqual(response.turnID, target.turnID)
        XCTAssertEqual(response.terminalEvent?.reason, .interrupted)

        await gate.release()
        let result = try await runningTurn.value
        XCTAssertTrue(result.wasCancelled)
    }

    func testInterruptTurnRejectsWrongActiveTurnID() async throws {
        let requests = RecordedModelRequests()
        let client = BlockingToolModelClient(requests: requests)
        let gate = BlockingCommandGate()
        let conversation = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge { _, _ in
                await gate.runUntilReleased()
                return .success(stdout: "late\n")
            }
        ).makeConversation(configuration: Self.configuration())

        let runningTurn = Task { try await conversation.send("第一轮") }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()
        let currentTarget = await conversation.currentTurnInterruptTarget()
        let target = try XCTUnwrap(currentTarget)
        let wrongTurnID = UUID().uuidString

        do {
            _ = try await conversation.interruptTurn(MSPTurnInterruptRequest(
                threadID: target.threadID,
                turnID: wrongTurnID
            ))
            XCTFail("Expected wrong turn id interrupt to fail")
        } catch let error as MSPTurnInterruptError {
            XCTAssertEqual(error, .activeTurnMismatch(
                requested: wrongTurnID,
                active: target.turnID
            ))
        }

        _ = try await conversation.interruptActiveTurn()
        await gate.release()
        _ = try await runningTurn.value
    }

    func testInterruptTurnRejectsNoActiveTurnAndTerminalTurn() async throws {
        let conversation = MSPAgentRuntime(
            modelClientFactory: { _ in OneShotFinalAnswerClient() },
            execCommandBridge: MSPExecCommandBridge { _, _ in .success(stdout: "") }
        ).makeConversation(configuration: Self.configuration())

        do {
            _ = try await conversation.interruptTurn(MSPTurnInterruptRequest(
                threadID: conversation.threadID,
                turnID: UUID().uuidString
            ))
            XCTFail("Expected interrupt without active turn to fail")
        } catch let error as MSPTurnInterruptError {
            guard case .noActiveTurn = error else {
                return XCTFail("Expected noActiveTurn, got \(error)")
            }
        }

        let events = RecordedAgentEvents()
        _ = try await conversation.send("完成", onEvent: { await events.append($0) })
        let lifecycle = await events.turnLifecycleSignatures()
        let started = try XCTUnwrap(lifecycle.first { $0.hasPrefix("turnStarted:") })
        let turnID = String(started.dropFirst("turnStarted:".count))

        do {
            _ = try await conversation.interruptTurn(MSPTurnInterruptRequest(
                threadID: conversation.threadID,
                turnID: turnID
            ))
            XCTFail("Expected terminal turn interrupt to fail")
        } catch let error as MSPTurnInterruptError {
            XCTAssertEqual(error, .terminalTurn(turnID: turnID, status: .completed))
        }
    }

    func testRepeatedInterruptWaitsForSameTerminalResponse() async throws {
        let controller = MSPTurnInterruptController(capability: .enabled())
        let threadID = "thread-test"
        let turnID = UUID()
        _ = controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            transcriptRecorder: nil,
            fallbackTranscriptItems: [],
            eventHandler: { _ in }
        )
        let request = MSPTurnInterruptRequest(
            threadID: threadID,
            turnID: turnID.uuidString
        )

        let begin = try controller.beginInterrupt(
            request: request,
            conversationThreadID: threadID
        )
        let commit: MSPTurnInterruptCommit
        if case .perform(let value) = begin {
            commit = value
        } else {
            return XCTFail("Expected first interrupt to perform")
        }
        let repeated = try controller.beginInterrupt(
            request: request,
            conversationThreadID: threadID
        )
        guard case .waitForPending(let pendingTurnID) = repeated else {
            return XCTFail("Expected repeated interrupt to wait")
        }
        XCTAssertEqual(pendingTurnID, turnID.uuidString)

        let waiter = Task {
            try await controller.waitForPendingInterrupt(turnID: turnID.uuidString)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let response = controller.completeInterrupt(commit, reason: .interrupted)
        let waited = try await waiter.value
        XCTAssertEqual(waited, response)
    }

    func testCapabilityDisabledDoesNotDeclareOrAllowInterrupt() async throws {
        let conversation = MSPAgentRuntime(
            modelClientFactory: { _ in OneShotFinalAnswerClient() },
            execCommandBridge: MSPExecCommandBridge { _, _ in .success(stdout: "") }
        ).makeConversation(configuration: Self.configuration(
            turnInterruptCapability: .disabled
        ))

        let declaration = await conversation.turnInterruptCapabilityDeclaration()
        XCTAssertFalse(declaration.enabled)
        XCTAssertEqual(declaration.methods, [])

        do {
            _ = try await conversation.interruptTurn(MSPTurnInterruptRequest(
                threadID: conversation.threadID,
                turnID: ""
            ))
            XCTFail("Expected disabled capability to reject interrupt")
        } catch let error as MSPTurnInterruptError {
            XCTAssertEqual(error, .capabilityDisabled)
        }
    }

    func testStartupInterruptUsesImmediateAckBoundary() async throws {
        let conversation = MSPAgentRuntime(
            modelClientFactory: { _ in OneShotFinalAnswerClient() },
            execCommandBridge: MSPExecCommandBridge { _, _ in .success(stdout: "") }
        ).makeConversation(configuration: Self.configuration())

        let response = try await conversation.interruptTurn(MSPTurnInterruptRequest(
            threadID: conversation.threadID,
            turnID: ""
        ))

        XCTAssertNil(response.turnID)
        XCTAssertNil(response.terminalEvent)
        XCTAssertEqual(response.reason, .interrupted)
    }

    func testChatMappingWritesCanonicalTurnAbortedShape() {
        let event = MSPTurnInterruptTurnAbortedEvent(
            threadID: "thread",
            turnID: "turn-1",
            reason: .interrupted,
            completedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 12
        )

        let reference = MSPTurnInterruptChatMapping.referenceContextEvent(for: event)
        let object = reference.objectValue
        XCTAssertEqual(object?["kind"]?.stringValue, "turn_aborted")
        XCTAssertEqual(object?["id"]?.stringValue, "turn-1")
        XCTAssertEqual(object?["reason"]?.stringValue, "interrupted")

        let payload = MSPTurnInterruptChatMapping.timelinePayload(for: event)
        XCTAssertEqual(payload["turn_id"]?.stringValue, "turn-1")
        XCTAssertEqual(payload["reason"]?.stringValue, "interrupted")
        XCTAssertEqual(payload["duration_ms"]?.intValue, 12)
    }

    private static func configuration(
        turnInterruptCapability: MSPTurnInterruptCapability = .enabled()
    ) -> MSPAgentConversationConfiguration {
        MSPAgentConversationConfiguration(
            model: "test-model",
            environmentNotes: [
                "Execution surface: unit test.",
                "Workspace root visible to you: /"
            ],
            turnInterruptCapability: turnInterruptCapability
        )
    }
}

private actor InterruptCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class OneShotFinalAnswerClient: MSPAgentModelTurnClient, @unchecked Sendable {
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
                    "id": .string("msg_one_shot"),
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
