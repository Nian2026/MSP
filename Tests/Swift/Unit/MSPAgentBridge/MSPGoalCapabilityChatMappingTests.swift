import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

extension MSPGoalCapabilityTests {
    func testChatMappingWritesCanonicalGoalPayloads() {
        let goal = MSPGoalSnapshot(
            threadID: "thread",
            goalID: "goal-1",
            objective: "ship goal",
            status: .active,
            tokenBudget: 100,
            tokensUsed: 25,
            timeUsedSeconds: 12,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let updated = MSPGoalUpdatedEvent(
            threadID: "thread",
            turnID: nil,
            goal: goal,
            previousGoal: nil,
            source: .sdk,
            reason: .created,
            eventID: "event-goal"
        )
        XCTAssertEqual(
            MSPGoalChatMapping.timelinePayload(for: updated)["goal_id"]?.stringValue,
            "goal-1"
        )
        XCTAssertEqual(
            MSPGoalChatMapping.timelinePayload(for: updated)["status"]?.stringValue,
            "active"
        )

        let accounted = MSPGoalAccountedEvent(
            threadID: "thread",
            turnID: "turn-1",
            goalID: "goal-1",
            tokenDelta: 10,
            timeDeltaSeconds: 2,
            tokensUsed: 35,
            timeUsedSeconds: 14,
            status: .active,
            eventID: "event-accounted"
        )
        XCTAssertEqual(
            MSPGoalChatMapping.timelinePayload(for: accounted)["token_delta"]?.intValue,
            10
        )
    }
}
