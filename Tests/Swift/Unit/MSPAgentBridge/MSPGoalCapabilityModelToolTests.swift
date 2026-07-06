import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

extension MSPGoalCapabilityTests {
    func testModelGoalToolsCreateUpdateRestrictionsAndReplacement() throws {
        let controller = MSPGoalController(capability: .enabled())
        let threadID = "thread-goal-tools"
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            startedAt: Date()
        )

        let created = try XCTUnwrap(controller.executeGoalTool(
            MSPAgentToolCall(
                id: "call_create",
                name: .createGoal,
                arguments: [
                    "objective": .string("ship owner"),
                    "token_budget": .number(25)
                ]
            ),
            turnID: turnID
        ))
        XCTAssertTrue(created.result.ok)
        XCTAssertEqual(created.events.count, 1)

        let duplicate = try XCTUnwrap(controller.executeGoalTool(
            MSPAgentToolCall(
                id: "call_create_again",
                name: .createGoal,
                arguments: ["objective": .string("duplicate")]
            ),
            turnID: turnID
        ))
        XCTAssertFalse(duplicate.result.ok)
        XCTAssertTrue(duplicate.result.errorMessage?.contains("unfinished goal") == true)

        let unsupported = try XCTUnwrap(controller.executeGoalTool(
            MSPAgentToolCall(
                id: "call_pause",
                name: .updateGoal,
                arguments: ["status": .string("paused")]
            ),
            turnID: turnID
        ))
        XCTAssertFalse(unsupported.result.ok)
        XCTAssertTrue(unsupported.result.errorMessage?.contains("update_goal cannot set") == true)

        let complete = try XCTUnwrap(controller.executeGoalTool(
            MSPAgentToolCall(
                id: "call_complete",
                name: .updateGoal,
                arguments: ["status": .string("complete")]
            ),
            turnID: turnID
        ))
        XCTAssertTrue(complete.result.ok)
        XCTAssertEqual(try controller.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        )?.status, .complete)

        let replacement = try XCTUnwrap(controller.executeGoalTool(
            MSPAgentToolCall(
                id: "call_replacement",
                name: .createGoal,
                arguments: ["objective": .string("replacement")]
            ),
            turnID: turnID
        ))
        XCTAssertTrue(replacement.result.ok)
        let goal = try XCTUnwrap(controller.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        ))
        XCTAssertEqual(goal.objective, "replacement")
        XCTAssertEqual(goal.tokensUsed, 0)
    }

    func testModelCreateGoalDoesNotAccountPreGoalUsage() throws {
        let controller = MSPGoalController(capability: .enabled())
        let threadID = "thread-create-goal-baseline"
        let turnID = UUID()
        controller.startTurn(
            id: turnID,
            threadID: threadID,
            kind: .user,
            startedAt: Date()
        )
        controller.recordTokenUsage(
            Self.contextUsage(input: 80, output: 20),
            turnID: turnID
        )

        let created = try XCTUnwrap(controller.executeGoalTool(
            MSPAgentToolCall(
                id: "call_create_after_usage",
                name: .createGoal,
                arguments: ["objective": .string("start accounting now")]
            ),
            turnID: turnID
        ))
        XCTAssertTrue(created.result.ok)

        _ = controller.finishTurn(id: turnID, status: .completed)
        let goal = try XCTUnwrap(controller.currentGoal(
            threadID: threadID,
            conversationThreadID: threadID
        ))
        XCTAssertEqual(goal.tokensUsed, 0)
        XCTAssertEqual(goal.status, .active)
    }
}
