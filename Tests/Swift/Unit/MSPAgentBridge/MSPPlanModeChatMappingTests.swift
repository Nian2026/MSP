import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPPlanModeChatMappingTests: XCTestCase {
    func testChatMappingWritesCanonicalPlanModeShapes() {
        let proposalEvent = MSPPlanModeProposedEvent(
            threadID: "thread",
            planningTurnID: "turn-plan",
            proposalID: "proposal-1",
            proposalVersion: 2,
            proposedPlanContent: "- Step",
            source: .model,
            eventID: "event-proposed",
            proposedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(
            MSPPlanModeChatMapping.timelinePayload(for: proposalEvent)["proposal_id"]?.stringValue,
            "proposal-1"
        )
        XCTAssertEqual(
            MSPPlanModeChatMapping.timelinePayload(for: proposalEvent)["proposal_version"]?.intValue,
            2
        )

        let decision = MSPPlanModeDecisionEvent(
            threadID: "thread",
            proposalID: "proposal-1",
            proposalVersion: 2,
            decision: .approved,
            source: .user,
            eventID: "event-approved",
            decidedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            MSPPlanModeChatMapping.timelinePayload(for: decision)["decision"]?.stringValue,
            "approved"
        )

        let modified = MSPPlanModeDecisionEvent(
            threadID: "thread",
            proposalID: "proposal-1",
            proposalVersion: 2,
            decision: .modified,
            source: .user,
            eventID: "event-modified",
            decidedAt: Date(timeIntervalSince1970: 3),
            reason: "tighten scope"
        )
        XCTAssertEqual(
            MSPPlanModeChatMapping.timelinePayload(for: modified)["decision"]?.stringValue,
            "modified"
        )
        XCTAssertEqual(
            MSPPlanModeChatMapping.timelinePayload(for: modified)["reason"]?.stringValue,
            "tighten scope"
        )

        let rejected = MSPPlanModeDecisionEvent(
            threadID: "thread",
            proposalID: "proposal-1",
            proposalVersion: 2,
            decision: .rejected,
            source: .user,
            eventID: "event-rejected",
            decidedAt: Date(timeIntervalSince1970: 4)
        )
        XCTAssertEqual(
            MSPPlanModeChatMapping.timelinePayload(for: rejected)["decision"]?.stringValue,
            "rejected"
        )
    }
}
