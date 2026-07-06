@testable import MSPAgentBridge
import XCTest

final class MSPPlanModeCrossCapabilityTests: XCTestCase {
    func testPlanModeTurnDoesNotAccountGoalUsage() async throws {
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeFinalPlanClient(
                usage: MSPAgentTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150)
            ),
            planModeCapability: .enabled,
            goalCapability: .enabled()
        )
        _ = try await conversation.createGoal(
            threadID: conversation.threadID,
            objective: "ship plan mode",
            tokenBudget: 200
        )

        _ = try await conversation.submitPlanningTurn(
            threadID: conversation.threadID,
            prompt: "Plan without accounting."
        )

        let currentGoal = try await conversation.currentGoal(threadID: conversation.threadID)
        let goal = try XCTUnwrap(currentGoal)
        XCTAssertEqual(goal.tokensUsed, 0)
        XCTAssertEqual(goal.remainingTokens, 200)
    }

    func testSteerPlanningTurnRejectsAsNotSteerable() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeBlockingPlanningToolClient(requests: requests),
            planModeCapability: .enabled,
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let planningTurn = Task {
            try await conversation.submitPlanningTurn(
                threadID: conversation.threadID,
                prompt: "Plan with a check."
            )
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        do {
            _ = try await conversation.steerActiveTurn("Do this instead")
            XCTFail("Expected planning turn steer to reject")
        } catch let error as MSPTurnSteerError {
            XCTAssertEqual(error.reason, .activeTurnNotSteerable)
        }

        await gate.release()
        _ = try await planningTurn.value
    }

    func testInterruptPlanningTurnPreservesAbortFactWithoutApprovingPlan() async throws {
        let requests = RecordedModelRequests()
        let gate = BlockingCommandGate()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeBlockingPlanningToolClient(requests: requests),
            planModeCapability: .enabled,
            commandRunner: { _ in
                await gate.runUntilReleased()
                return .success(stdout: "/\n")
            }
        )

        let planningTurn = Task {
            try await conversation.submitPlanningTurn(
                threadID: conversation.threadID,
                prompt: "Plan with a slow check."
            )
        }
        try await requests.waitForCount(1)
        try await gate.waitUntilStarted()

        let handle = try await conversation.interruptActiveTurn()
        let interruptHandle = try XCTUnwrap(handle)
        let terminal = try await interruptHandle.terminalResponse()
        XCTAssertEqual(terminal.reason, .interrupted)
        XCTAssertEqual(terminal.terminalEvent?.turnID, interruptHandle.target.turnID)

        await gate.release()
        let response = try await planningTurn.value
        XCTAssertTrue(response.runResult.wasCancelled)
        XCTAssertNil(response.proposedPlan)

        let state = try await conversation.currentPlanModeState(threadID: conversation.threadID)
        XCTAssertEqual(state.status, .planning)
        XCTAssertNil(state.currentProposal)
        XCTAssertNil(state.approvedProposal)
        XCTAssertNil(state.implementationHandoff)

        let transcript = await conversation.snapshotTranscriptItems()
        let transcriptText = transcript
            .compactMap(\.objectValue)
            .map(MSPPlanModeTestSupport.text(in:))
            .joined(separator: "\n")
        XCTAssertTrue(transcriptText.contains("Plan with a slow check."))
        XCTAssertTrue(transcriptText.contains("<turn_aborted>"))
        XCTAssertFalse(transcriptText.contains("Proposal ID:"))
        XCTAssertFalse(transcriptText.contains("<approved_plan_handoff>"))
    }
}
