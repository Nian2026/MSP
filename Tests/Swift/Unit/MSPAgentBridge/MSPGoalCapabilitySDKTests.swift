import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

extension MSPGoalCapabilityTests {
    func testCapabilityDisabledDeclarationAPIAndToolsClosed() async throws {
        let conversation = Self.makeConversation(
            modelClient: GoalFinalAnswerClient(),
            goalCapability: .disabled
        )

        let declaration = await conversation.goalCapabilityDeclaration()
        XCTAssertFalse(declaration.enabled)
        XCTAssertEqual(declaration.methods, [])
        XCTAssertEqual(declaration.modelTools, [])

        let threadID = conversation.threadID
        do {
            _ = try await conversation.createGoal(
                threadID: threadID,
                objective: "finish the migration"
            )
            XCTFail("disabled Goal capability should reject createGoal")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error, .capabilityDisabled)
        }

        let request = try Self.firstRequest(
            for: GoalFinalAnswerClient(),
            goalCapability: .disabled
        )
        XCTAssertFalse(Self.toolNames(in: request).contains(MSPGoalTools.createGoalName))
    }

    func testTypedSDKCreateGetSetUpdateClear() async throws {
        let conversation = Self.makeConversation(
            modelClient: GoalFinalAnswerClient(),
            goalCapability: .enabled()
        )
        let threadID = conversation.threadID

        let empty = try await conversation.currentGoal(threadID: threadID)
        XCTAssertNil(empty)

        let created = try await conversation.createGoal(
            threadID: threadID,
            objective: "  ship Goal capability  ",
            tokenBudget: 100
        )
        XCTAssertEqual(created.goal.objective, "ship Goal capability")
        XCTAssertEqual(created.goal.status, .active)
        XCTAssertEqual(created.goal.tokenBudget, 100)
        XCTAssertEqual(created.goal.tokensUsed, 0)
        XCTAssertEqual(created.goal.remainingTokens, 100)
        XCTAssertEqual(created.reason, .created)
        XCTAssertEqual(created.runtimeEvents.count, 1)
        guard case .threadGoalUpdated(let createdEvent) = created.runtimeEvents.first else {
            return XCTFail("createGoal should return a canonical threadGoalUpdated event")
        }
        XCTAssertEqual(createdEvent.reason, .created)
        XCTAssertEqual(createdEvent.goal.goalID, created.goal.goalID)

        do {
            _ = try await conversation.createGoal(
                threadID: threadID,
                objective: "duplicate"
            )
            XCTFail("unfinished goal should reject model/tool-style create")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error, .unfinishedGoalExists(goalID: created.goal.goalID))
        }

        let updated = try await conversation.setGoal(
            threadID: threadID,
            objective: "ship final Goal capability",
            status: .paused,
            tokenBudget: .set(200)
        )
        XCTAssertEqual(updated.goal.objective, "ship final Goal capability")
        XCTAssertEqual(updated.goal.status, .paused)
        XCTAssertEqual(updated.goal.tokenBudget, 200)
        XCTAssertEqual(updated.previousGoal?.goalID, created.goal.goalID)
        XCTAssertEqual(updated.runtimeEvents.count, 1)
        guard case .threadGoalUpdated(let updatedEvent) = updated.runtimeEvents.first else {
            return XCTFail("setGoal should return a canonical threadGoalUpdated event")
        }
        XCTAssertEqual(updatedEvent.reason, .updated)
        XCTAssertEqual(updatedEvent.previousGoal?.goalID, created.goal.goalID)

        let complete = try await conversation.updateGoal(
            threadID: threadID,
            status: .complete
        )
        XCTAssertEqual(complete.goal.status, .complete)
        XCTAssertEqual(complete.runtimeEvents.count, 1)

        let replacement = try await conversation.createGoal(
            threadID: threadID,
            objective: "replacement goal",
            tokenBudget: 50
        )
        XCTAssertNotEqual(replacement.goal.goalID, created.goal.goalID)
        XCTAssertEqual(replacement.goal.tokensUsed, 0)
        XCTAssertEqual(replacement.goal.remainingTokens, 50)

        let clear = try await conversation.clearGoal(threadID: threadID)
        XCTAssertTrue(clear.cleared)
        XCTAssertEqual(clear.clearedGoal?.goalID, replacement.goal.goalID)
        XCTAssertEqual(clear.runtimeEvents.count, 1)
        guard case .threadGoalCleared(let clearEvent) = clear.runtimeEvents.first else {
            return XCTFail("clearGoal should return a canonical threadGoalCleared event")
        }
        XCTAssertEqual(clearEvent.clearedGoal?.goalID, replacement.goal.goalID)
        let afterClear = try await conversation.currentGoal(threadID: threadID)
        XCTAssertNil(afterClear)
    }

    func testInvalidObjectiveBudgetAndNonPersistentThreadReject() async throws {
        let conversation = Self.makeConversation(
            modelClient: GoalFinalAnswerClient(),
            goalCapability: .enabled(persistentThreadStateAvailable: false)
        )
        let nonPersistentThreadID = conversation.threadID

        do {
            _ = try await conversation.currentGoal(threadID: nonPersistentThreadID)
            XCTFail("non-persistent thread should reject Goal")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error.reason, .nonPersistentThread)
        }

        let persistent = Self.makeConversation(
            modelClient: GoalFinalAnswerClient(),
            goalCapability: .enabled()
        )
        let persistentThreadID = persistent.threadID
        do {
            _ = try await persistent.createGoal(
                threadID: persistentThreadID,
                objective: " "
            )
            XCTFail("empty objective should reject")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error, .emptyObjective)
        }
        do {
            _ = try await persistent.createGoal(
                threadID: persistentThreadID,
                objective: "budget",
                tokenBudget: 0
            )
            XCTFail("non-positive budget should reject")
        } catch let error as MSPGoalError {
            XCTAssertEqual(error, .invalidTokenBudget)
        }
    }

    func testClearWithoutGoalAndRepeatedUpdatesAreStable() async throws {
        let conversation = Self.makeConversation(
            modelClient: GoalFinalAnswerClient(),
            goalCapability: .enabled()
        )
        let threadID = conversation.threadID

        let emptyClear = try await conversation.clearGoal(threadID: threadID)
        XCTAssertFalse(emptyClear.cleared)
        XCTAssertNil(emptyClear.clearedGoal)
        XCTAssertTrue(emptyClear.runtimeEvents.isEmpty)

        let created = try await conversation.createGoal(
            threadID: threadID,
            objective: "stable repeated updates"
        )
        let paused = try await conversation.setGoal(
            threadID: threadID,
            status: .paused
        )
        let active = try await conversation.setGoal(
            threadID: threadID,
            status: .active
        )
        let blocked = try await conversation.updateGoal(
            threadID: threadID,
            status: .blocked
        )

        XCTAssertEqual(created.goal.status, .active)
        XCTAssertEqual(paused.previousGoal?.status, .active)
        XCTAssertEqual(paused.goal.status, .paused)
        XCTAssertEqual(active.previousGoal?.status, .paused)
        XCTAssertEqual(active.goal.status, .active)
        XCTAssertEqual(blocked.previousGoal?.status, .active)
        XCTAssertEqual(blocked.goal.status, .blocked)
        XCTAssertEqual(
            [created, paused, active, blocked].map(\.reason),
            [.created, .updated, .updated, .statusChanged]
        )
    }
}
