import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

extension MSPGoalCapabilityTests {
    func testObjectiveUpdateDuringActiveTurnInjectsGoalContext() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = Self.makeConversation(
            modelClient: GoalBlockingToolModelClient(requests: requests),
            goalCapability: .enabled(),
            commandRunner: { command in
                XCTAssertEqual(command, "sleep 3000")
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )
        let threadID = conversation.threadID
        _ = try await conversation.createGoal(
            threadID: threadID,
            objective: "original objective"
        )

        let runningTurn = Task {
            try await conversation.send("run slow command")
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        _ = try await conversation.setGoal(
            threadID: threadID,
            objective: "updated objective"
        )
        await gate.release()
        try await requests.waitForCount(2)

        let secondRequest = try await requests.request(at: 1)
        let input = secondRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertTrue(Self.messageTexts(from: input).contains {
            $0.contains("<goal_objective_updated>")
                && $0.contains("updated objective")
        })

        _ = try await runningTurn.value
    }

    func testRestoredActiveGoalIsVisibleAsInitialGoalContext() async throws {
        let requests = RecordedModelRequests()
        let threadID = "thread-restored-goal"
        let restored = MSPGoalSnapshot(
            threadID: threadID,
            goalID: "goal-restored",
            objective: "resume restored objective",
            status: .active,
            tokenBudget: 100,
            tokensUsed: 40,
            timeUsedSeconds: 12,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let conversation = Self.makeConversation(
            threadID: threadID,
            modelClient: GoalRecordingFinalAnswerClient(requests: requests),
            goalCapability: .enabled(restoredGoal: restored)
        )

        _ = try await conversation.send("continue this thread")
        try await requests.waitForCount(1)
        let request = try await requests.request(at: 0)
        let input = request.input.compactMap { $0.jsonObject as? [String: Any] }
        let texts = Self.messageTexts(from: input)

        XCTAssertTrue(texts.contains {
            $0.contains("<goal_continuation>")
                && $0.contains("resume restored objective")
                && $0.contains("Remaining tokens: 60")
        })
        XCTAssertTrue(texts.contains("continue this thread"))
    }

    func testIdleActiveGoalContinuationRunsWithoutCreatingUserMessage() async throws {
        let requests = RecordedModelRequests()
        let conversation = Self.makeConversation(
            modelClient: GoalRecordingFinalAnswerClient(requests: requests),
            goalCapability: .enabled()
        )
        let threadID = conversation.threadID
        _ = try await conversation.createGoal(
            threadID: threadID,
            objective: "continue while idle"
        )

        let result = try await conversation.continueActiveGoalIfIdle()
        XCTAssertEqual(result?.finalAnswer, "done")
        try await requests.waitForCount(1)

        let request = try await requests.request(at: 0)
        let messages = request.input.compactMap { $0.jsonObject as? [String: Any] }
        let userMessages = messages.filter { $0["role"] as? String == "user" }
        let goalContextMessages = userMessages.filter { message in
            let metadata = message["metadata"] as? [String: Any]
            return metadata?["msp_internal_context_source"] as? String == "goal"
        }
        XCTAssertEqual(goalContextMessages.count, 1)
        XCTAssertTrue(Self.messageTexts(from: goalContextMessages).contains {
            $0.contains("<goal_continuation>")
                && $0.contains("continue while idle")
        })
        XCTAssertFalse(Self.messageTexts(from: userMessages).contains(""))

        let transcript = await conversation.snapshotTranscriptItems()
        let transcriptMessages = transcript.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertFalse(Self.messageTexts(from: transcriptMessages).contains {
            $0.contains("continue while idle")
        })

        let second = try await conversation.continueActiveGoalIfIdle()
        XCTAssertNotNil(second)
    }

    func testIdleGoalContinuationReturnsNilWhenNoActiveGoalCanContinue() async throws {
        let conversation = Self.makeConversation(
            modelClient: GoalRecordingFinalAnswerClient(requests: RecordedModelRequests()),
            goalCapability: .enabled()
        )
        let emptyContinuation = try await conversation.continueActiveGoalIfIdle()
        XCTAssertNil(emptyContinuation)

        let threadID = conversation.threadID
        _ = try await conversation.createGoal(
            threadID: threadID,
            objective: "pause before continuing"
        )
        _ = try await conversation.setGoal(
            threadID: threadID,
            status: .paused
        )
        let pausedContinuation = try await conversation.continueActiveGoalIfIdle()
        XCTAssertNil(pausedContinuation)
    }

    func testIdleGoalContinuationRejectsDisabledAndNonPersistentGoalCapability() async throws {
        let disabled = Self.makeConversation(
            modelClient: GoalRecordingFinalAnswerClient(requests: RecordedModelRequests()),
            goalCapability: .disabled
        )
        do {
            _ = try await disabled.continueActiveGoalIfIdle()
            XCTFail("disabled Goal capability should reject idle continuation")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error, .capabilityDisabled)
        }

        let nonPersistent = Self.makeConversation(
            modelClient: GoalRecordingFinalAnswerClient(requests: RecordedModelRequests()),
            goalCapability: .enabled(persistentThreadStateAvailable: false)
        )
        do {
            _ = try await nonPersistent.continueActiveGoalIfIdle()
            XCTFail("non-persistent Goal capability should reject idle continuation")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error.reason, .nonPersistentThread)
        }
    }

    func testRestoredGoalFromAnotherThreadDoesNotEnterProviderPrompt() throws {
        let restored = MSPGoalSnapshot(
            threadID: "thread-other",
            goalID: "goal-other",
            objective: "do not leak",
            status: .active
        )
        let controller = MSPGoalController(capability: .enabled(restoredGoal: restored))
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: "thread-current",
            kind: .user,
            startedAt: Date()
        )

        XCTAssertTrue(controller.initialInput(turnID: turnID).isEmpty)
        do {
            _ = try controller.currentGoal(
                threadID: "thread-current",
                conversationThreadID: "thread-current"
            )
            XCTFail("mismatched restored goal should be rejected")
        } catch let error as MSPGoalError {
            XCTAssertEqual(
                error,
                .threadMismatch(expected: "thread-current", actual: "thread-other")
            )
        }
    }
}
