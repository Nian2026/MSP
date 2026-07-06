@testable import MSPAgentBridge
import XCTest

final class MSPPlanModeProposalDecisionTests: XCTestCase {
    func testApproveRejectModifyAndStaleDecisionsAreTypedAndStable() async throws {
        let requests = RecordedModelRequests()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeFinalPlanClient(requests: requests),
            planModeCapability: .enabled
        )
        let planned = try await conversation.submitPlanningTurn(
            threadID: conversation.threadID,
            prompt: "Plan."
        )
        try await requests.waitForCount(1)
        let proposal = try XCTUnwrap(planned.proposedPlan)

        let rejected = try await conversation.rejectProposedPlan(
            threadID: conversation.threadID,
            proposalID: proposal.proposalID,
            proposalVersion: proposal.proposalVersion,
            reason: "needs revision"
        )
        XCTAssertEqual(rejected.snapshot.status, .rejected)
        XCTAssertEqual(rejected.decisionEvent.decision, .rejected)
        XCTAssertNil(rejected.handoff)
        XCTAssertEqual(rejected.runtimeEvents, [.planModeRejected(rejected.decisionEvent)])

        let repeatedReject = try await conversation.rejectProposedPlan(
            threadID: conversation.threadID,
            proposalID: proposal.proposalID,
            proposalVersion: proposal.proposalVersion
        )
        XCTAssertEqual(repeatedReject.decisionEvent.eventID, rejected.decisionEvent.eventID)

        do {
            _ = try await conversation.approveProposedPlan(
                threadID: conversation.threadID,
                proposalID: proposal.proposalID,
                proposalVersion: proposal.proposalVersion
            )
            XCTFail("Expected opposite decision after reject to fail")
        } catch let error as MSPPlanModeError {
            XCTAssertEqual(error.reason, .proposalAlreadyRejected)
        }

        let modified = try await conversation.modifyProposedPlan(MSPPlanModeModifyRequest(
            threadID: conversation.threadID,
            baseProposalID: proposal.proposalID,
            baseProposalVersion: proposal.proposalVersion,
            revisedPlanContent: "- Revised step"
        ))
        XCTAssertEqual(modified.proposal.proposalVersion, 2)
        XCTAssertNotEqual(modified.proposal.proposalID, proposal.proposalID)
        XCTAssertEqual(modified.snapshot.status, .proposed)

        do {
            _ = try await conversation.approveProposedPlan(
                threadID: conversation.threadID,
                proposalID: proposal.proposalID,
                proposalVersion: proposal.proposalVersion
            )
            XCTFail("Expected stale proposal approval to fail")
        } catch let error as MSPPlanModeError {
            XCTAssertEqual(error.reason, .staleProposal)
        }

        let approved = try await conversation.approveProposedPlan(
            threadID: conversation.threadID,
            proposalID: modified.proposal.proposalID,
            proposalVersion: modified.proposal.proposalVersion
        )
        XCTAssertEqual(approved.snapshot.status, .implementing)
        XCTAssertEqual(approved.decisionEvent.decision, .approved)
        XCTAssertEqual(approved.handoff?.implementationPrompt, "Implement the plan.")
        XCTAssertEqual(approved.runtimeEvents.count, 2)
        let modelRequestCountAfterApproval = await requests.count()
        XCTAssertEqual(modelRequestCountAfterApproval, 1)
        let handoff = try XCTUnwrap(approved.handoff)
        let handoffText = handoff.modelVisibleItems
            .compactMap(\.objectValue)
            .map(MSPPlanModeTestSupport.text(in:))
            .joined(separator: "\n")
        XCTAssertTrue(handoffText.contains("<approved_plan_handoff>"))
        XCTAssertTrue(handoffText.contains("Implement the plan."))

        let repeatedApprove = try await conversation.approveProposedPlan(
            threadID: conversation.threadID,
            proposalID: modified.proposal.proposalID,
            proposalVersion: modified.proposal.proposalVersion
        )
        XCTAssertEqual(repeatedApprove.decisionEvent.eventID, approved.decisionEvent.eventID)
    }
}
