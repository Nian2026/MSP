@testable import MSPAgentBridge
import XCTest

final class MSPPlanModeCapabilityDeclarationTests: MSPAgentConversationRequestTestCase {
    func testCapabilityDisabledDeclarationAndAPIReject() async throws {
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeFinalPlanClient(),
            planModeCapability: .disabled
        )

        let declaration = await conversation.planModeCapabilityDeclaration()
        XCTAssertFalse(declaration.enabled)
        XCTAssertEqual(declaration.methods, [])
        XCTAssertEqual(declaration.modelTools, [])

        do {
            _ = try await conversation.submitPlanningTurn(
                threadID: conversation.threadID,
                prompt: "Plan this."
            )
            XCTFail("Expected disabled PlanMode capability to reject")
        } catch let error as MSPPlanModeError {
            XCTAssertEqual(error, .capabilityDisabled)
            XCTAssertEqual(error.reason, .capabilityDisabled)
        }
    }

    func testEnterPlanModeReturnsTypedStateWithoutRegisteringChecklistTool() async throws {
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeFinalPlanClient(),
            planModeCapability: .enabled
        )

        let declaration = await conversation.planModeCapabilityDeclaration()
        XCTAssertTrue(declaration.enabled)
        XCTAssertTrue(declaration.methods.contains("thread/plan_mode/enter"))
        XCTAssertEqual(declaration.modelTools, [])

        let response = try await conversation.enterPlanMode(threadID: conversation.threadID)
        XCTAssertEqual(response.snapshot.threadID, conversation.threadID)
        XCTAssertEqual(response.snapshot.status, .planning)
        XCTAssertNil(response.snapshot.currentProposal)
        XCTAssertNil(response.snapshot.approvedProposal)
        XCTAssertNil(response.snapshot.implementationHandoff)
        XCTAssertEqual(response.acceptedAt, response.snapshot.updatedAt)

        let state = try await conversation.currentPlanModeState(threadID: conversation.threadID)
        XCTAssertEqual(state.status, .planning)
    }
}
