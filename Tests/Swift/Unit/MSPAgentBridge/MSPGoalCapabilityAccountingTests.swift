import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

extension MSPGoalCapabilityTests {
    func testBudgetLimitedGoalPreservesTerminalStatusForPauseAndBlock() throws {
        let controller = MSPGoalController(capability: .enabled())
        let threadID = "thread-budget-terminal"
        _ = try controller.createGoal(
            MSPGoalCreateRequest(
                threadID: threadID,
                objective: "preserve budget terminal",
                tokenBudget: 20
            ),
            conversationThreadID: threadID
        )
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            startedAt: Date()
        )
        controller.recordTokenUsage(
            Self.contextUsage(input: 25, output: 0),
            turnID: turnID
        )

        let blocked = try controller.updateGoal(
            MSPGoalUpdateRequest(
                threadID: threadID,
                status: .blocked,
                source: .modelTool,
                sourceTurnID: turnID.uuidString
            ),
            conversationThreadID: threadID
        )
        XCTAssertEqual(blocked.response.goal.status, MSPGoalStatus.budgetLimited)
        XCTAssertEqual(blocked.response.goal.tokensUsed, 25)

        let paused = try controller.setGoal(
            MSPGoalSetRequest(
                threadID: threadID,
                status: .paused
            ),
            conversationThreadID: threadID
        )
        XCTAssertEqual(paused.response.goal.status, MSPGoalStatus.budgetLimited)

        let usageLimitedController = MSPGoalController(capability: .enabled())
        let usageThreadID = "thread-budget-usage-limit"
        _ = try usageLimitedController.createGoal(
            MSPGoalCreateRequest(
                threadID: usageThreadID,
                objective: "usage limit can supersede budget",
                tokenBudget: 20
            ),
            conversationThreadID: usageThreadID
        )
        let usageTurnID = UUID()
        usageLimitedController.startTurn(
            id: usageTurnID,
            threadID: usageThreadID,
            kind: .user,
            startedAt: Date()
        )
        usageLimitedController.recordTokenUsage(
            Self.contextUsage(input: 25, output: 0),
            turnID: usageTurnID
        )
        _ = usageLimitedController.finishTurn(id: usageTurnID, status: .usageLimited)
        let usageLimited = try XCTUnwrap(usageLimitedController.currentGoal(
            threadID: usageThreadID,
            conversationThreadID: usageThreadID
        ))
        XCTAssertEqual(usageLimited.status, .usageLimited)
        XCTAssertEqual(usageLimited.tokensUsed, 25)

        let failedController = MSPGoalController(capability: .enabled())
        let failedThreadID = "thread-budget-failed"
        _ = try failedController.createGoal(
            MSPGoalCreateRequest(
                threadID: failedThreadID,
                objective: "failed turn must not block budget-limited goal",
                tokenBudget: 20
            ),
            conversationThreadID: failedThreadID
        )
        let failedTurnID = UUID()
        failedController.startTurn(
            id: failedTurnID,
            threadID: failedThreadID,
            kind: .user,
            startedAt: Date()
        )
        failedController.recordTokenUsage(
            Self.contextUsage(input: 25, output: 0),
            turnID: failedTurnID
        )
        let toolOutcome = failedController.toolFinished(
            MSPAgentToolCall(id: "call-shell", name: .execCommand),
            result: MSPAgentToolResult(
                callID: "call-shell",
                name: .execCommand,
                ok: true,
                content: .string("done"),
                errorMessage: nil
            ),
            turnID: failedTurnID
        )
        XCTAssertTrue(toolOutcome.events.contains {
            if case .threadGoalUpdated(let event) = $0 {
                return event.goal.status == .budgetLimited
            }
            return false
        })
        let failedOutcome = failedController.finishTurn(id: failedTurnID, status: .failed)
        let failedSnapshot = try XCTUnwrap(failedController.currentGoal(
            threadID: failedThreadID,
            conversationThreadID: failedThreadID
        ))
        XCTAssertEqual(failedSnapshot.status, .budgetLimited)
        XCTAssertFalse(failedOutcome.events.contains {
            if case .threadGoalUpdated(let event) = $0 {
                return event.reason == .statusChanged
            }
            return false
        })
    }

    func testAccountingBudgetLimitAndProviderPromptContext() async throws {
        let requests = RecordedModelRequests()
        let events = GoalEventLog()
        let conversation = Self.makeConversation(
            modelClient: GoalBudgetModelClient(requests: requests),
            model: "gpt-5-test",
            goalCapability: .enabled(),
            commandRunner: { command in
                XCTAssertEqual(command, "pwd")
                return .success(stdout: "/\n")
            }
        )

        _ = try await conversation.send("work", onEvent: { event in
            await events.append(event)
        })
        try await requests.waitForCount(3)

        let firstRequest = try await requests.request(at: 0)
        XCTAssertTrue(Self.toolNames(in: firstRequest).contains(MSPGoalTools.createGoalName))

        let thirdRequest = try await requests.request(at: 2)
        let input = thirdRequest.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertTrue(Self.messageTexts(from: input).contains {
            $0.contains("<goal_budget_limited>")
                && $0.contains("budget-limited test")
        })

        let budgetThreadID = conversation.threadID
        let budgetSnapshot = try await conversation.currentGoal(threadID: budgetThreadID)
        let snapshot = try XCTUnwrap(budgetSnapshot)
        XCTAssertEqual(snapshot.status, .budgetLimited)
        XCTAssertEqual(snapshot.tokensUsed, 50)
        XCTAssertEqual(snapshot.remainingTokens, 0)

        let goalEvents = await events.goalSignatures()
        XCTAssertTrue(goalEvents.contains("updated:created:active"))
        XCTAssertTrue(goalEvents.contains("accounted:50:budgetLimited"))
        XCTAssertTrue(goalEvents.contains("updated:accounted:budgetLimited"))
    }

    func testMaintenanceTurnDoesNotAccountGoalUsage() throws {
        let controller = MSPGoalController(capability: .enabled())
        let threadID = "thread-maintenance"
        _ = try controller.createGoal(
            MSPGoalCreateRequest(
                threadID: threadID,
                objective: "do not count maintenance"
            ),
            conversationThreadID: threadID
        )
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .maintenance,
            startedAt: Date(timeIntervalSinceNow: -5)
        )
        controller.recordTokenUsage(Self.contextUsage(input: 100, output: 50), turnID: turnID)
        _ = controller.finishTurn(id: turnID, status: .completed)

        let snapshot = try XCTUnwrap(controller.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        ))
        XCTAssertEqual(snapshot.tokensUsed, 0)
        XCTAssertEqual(snapshot.timeUsedSeconds, 0)
        XCTAssertEqual(snapshot.status, .active)
    }

    func testExternalActiveSetReattachesCurrentTurnAccountingAfterMutation() throws {
        let controller = MSPGoalController(capability: .enabled())
        let threadID = "thread-active-set-accounting"
        _ = try controller.createGoal(
            MSPGoalCreateRequest(
                threadID: threadID,
                objective: "original active goal"
            ),
            conversationThreadID: threadID
        )
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            startedAt: Date()
        )
        controller.recordTokenUsage(Self.contextUsage(input: 20, output: 0), turnID: turnID)

        let updated = try controller.setGoal(
            MSPGoalSetRequest(
                threadID: threadID,
                objective: "updated active goal",
                status: .active
            ),
            conversationThreadID: threadID
        )
        XCTAssertEqual(updated.response.goal.tokensUsed, 20)

        controller.recordTokenUsage(Self.contextUsage(input: 10, output: 0), turnID: turnID)
        let finish = controller.finishTurn(id: turnID, status: .completed)
        let snapshot = try XCTUnwrap(controller.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        ))

        XCTAssertEqual(snapshot.objective, "updated active goal")
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertEqual(snapshot.tokensUsed, 30)
        XCTAssertTrue(finish.events.contains {
            if case .threadGoalAccounted(let event) = $0 {
                return event.tokenDelta == 10 && event.tokensUsed == 30
            }
            return false
        })
    }

    func testExecutedFailedToolCountsButUnexecutedFailureDoesNotAccountGoalProgress() throws {
        let executedFailure = MSPGoalController(capability: .enabled())
        let threadID = "thread-executed-failure"
        _ = try executedFailure.createGoal(
            MSPGoalCreateRequest(
                threadID: threadID,
                objective: "count failed executed tool"
            ),
            conversationThreadID: threadID
        )
        let turnID = UUID()
        executedFailure.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            startedAt: Date()
        )
        executedFailure.recordTokenUsage(Self.contextUsage(input: 20, output: 5), turnID: turnID)
        _ = executedFailure.toolFinished(
            MSPAgentToolCall(id: "call_failed_exec", name: .execCommand, arguments: [:]),
            result: MSPAgentToolResult(
                callID: "call_failed_exec",
                name: .execCommand,
                ok: false,
                content: .string("exit 1"),
                internalContent: .object(["exit_code": .number(1)]),
                errorMessage: "exit 1"
            ),
            turnID: turnID
        )
        let executedSnapshot = try XCTUnwrap(executedFailure.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        ))
        XCTAssertEqual(executedSnapshot.tokensUsed, 25)

        let unexecutedFailure = MSPGoalController(capability: .enabled())
        let unexecutedThreadID = "thread-unexecuted-failure"
        _ = try unexecutedFailure.createGoal(
            MSPGoalCreateRequest(
                threadID: unexecutedThreadID,
                objective: "ignore rejected tool"
            ),
            conversationThreadID: unexecutedThreadID
        )
        let unexecutedTurnID = UUID()
        unexecutedFailure.startTurn(
            id: unexecutedTurnID,
            threadID: unexecutedThreadID,
            kind: .user,
            startedAt: Date()
        )
        unexecutedFailure.recordTokenUsage(Self.contextUsage(input: 20, output: 5), turnID: unexecutedTurnID)
        _ = unexecutedFailure.toolFinished(
            MSPAgentToolCall(id: "call_rejected", name: .execCommand, arguments: [:]),
            result: MSPAgentToolResult(
                callID: "call_rejected",
                name: .execCommand,
                ok: false,
                content: .string("missing command"),
                errorMessage: "missing command"
            ),
            turnID: unexecutedTurnID
        )
        let unexecutedSnapshot = try XCTUnwrap(unexecutedFailure.currentGoal(
            threadID: unexecutedThreadID,
            conversationThreadID: unexecutedThreadID
        ))
        XCTAssertEqual(unexecutedSnapshot.tokensUsed, 0)
    }

    func testGoalAccountingSubtractsCachedInputTokens() throws {
        let controller = MSPGoalController(capability: .enabled())
        let threadID = "thread-cached-input"
        _ = try controller.createGoal(
            MSPGoalCreateRequest(
                threadID: threadID,
                objective: "count uncached tokens"
            ),
            conversationThreadID: threadID
        )
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            startedAt: Date()
        )
        controller.recordTokenUsage(
            Self.contextUsage(input: 100, cachedInput: 40, output: 15),
            turnID: turnID
        )
        _ = controller.toolFinished(
            MSPAgentToolCall(id: "call_shell", name: .execCommand, arguments: [:]),
            result: MSPAgentToolResult(
                callID: "call_shell",
                name: .execCommand,
                ok: true,
                content: .string("ok"),
                errorMessage: nil
            ),
            turnID: turnID
        )

        let snapshot = try XCTUnwrap(controller.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        ))
        XCTAssertEqual(snapshot.tokensUsed, 75)
    }

    func testUsageLimitAndTurnErrorStopActiveGoal() throws {
        let usageLimitedController = MSPGoalController(capability: .enabled())
        let usageThreadID = "thread-usage-limited"
        _ = try usageLimitedController.createGoal(
            MSPGoalCreateRequest(
                threadID: usageThreadID,
                objective: "stop on usage limit"
            ),
            conversationThreadID: usageThreadID
        )
        let usageTurnID = UUID()
        usageLimitedController.startTurn(
            id: usageTurnID,
            threadID: usageThreadID,
            kind: .user,
            startedAt: Date()
        )
        usageLimitedController.recordTokenUsage(
            Self.contextUsage(input: 20, output: 5),
            turnID: usageTurnID
        )
        let usageOutcome = usageLimitedController.finishTurn(
            id: usageTurnID,
            status: .usageLimited
        )
        let usageSnapshot = try XCTUnwrap(usageLimitedController.currentGoal(
            threadID: usageThreadID,
            conversationThreadID: usageThreadID
        ))
        XCTAssertEqual(usageSnapshot.status, .usageLimited)
        XCTAssertEqual(usageSnapshot.tokensUsed, 25)
        XCTAssertTrue(usageOutcome.events.contains {
            if case .threadGoalUpdated(let event) = $0 {
                return event.goal.status == .usageLimited
            }
            return false
        })

        let blockedController = MSPGoalController(capability: .enabled())
        let blockedThreadID = "thread-turn-error"
        _ = try blockedController.createGoal(
            MSPGoalCreateRequest(
                threadID: blockedThreadID,
                objective: "block on terminal error"
            ),
            conversationThreadID: blockedThreadID
        )
        let blockedTurnID = UUID()
        blockedController.startTurn(
            id: blockedTurnID,
            threadID: blockedThreadID,
            kind: .user,
            startedAt: Date()
        )
        blockedController.recordTokenUsage(
            Self.contextUsage(input: 12, output: 3),
            turnID: blockedTurnID
        )
        _ = blockedController.finishTurn(id: blockedTurnID, status: .failed)
        let blockedSnapshot = try XCTUnwrap(blockedController.currentGoal(
            threadID: blockedThreadID,
            conversationThreadID: blockedThreadID
        ))
        XCTAssertEqual(blockedSnapshot.status, .blocked)
        XCTAssertEqual(blockedSnapshot.tokensUsed, 15)
    }
}
