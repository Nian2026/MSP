@testable import MSPAgentBridge
import XCTest

final class MSPPlanModePlanningTurnTests: MSPAgentConversationRequestTestCase {
    func testPlanningTurnProducesProposedPlanWithoutFinalAnswerTranscript() async throws {
        let requests = RecordedModelRequests()
        let events = MSPPlanModeEventLog()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeFinalPlanClient(requests: requests),
            planModeCapability: .enabled
        )

        let response = try await conversation.submitPlanningTurn(
            threadID: conversation.threadID,
            prompt: "Plan the implementation.",
            onEvent: { event in
                await events.append(event)
            }
        )

        let proposal = try XCTUnwrap(response.proposedPlan)
        XCTAssertEqual(proposal.proposalVersion, 1)
        XCTAssertEqual(proposal.proposedPlanContent, "- Step 1\n- Step 2")
        XCTAssertEqual(response.runResult.finalAnswer, "")
        XCTAssertEqual(response.snapshot.status, .proposed)

        let request = try await requests.request(at: 0)
        let input = request.input.compactMap { $0.jsonObject as? [String: Any] }
        XCTAssertTrue(Self.developerText(from: input).contains("You are in Plan Mode."))
        XCTAssertFalse(Self.developerText(from: input).contains("Latest task progress from update_plan"))
        XCTAssertFalse(MSPPlanModeTestSupport.toolNames(in: request).contains("update_plan"))

        let transcript = await conversation.snapshotTranscriptItems()
        let transcriptObjects = transcript.compactMap(\.objectValue)
        XCTAssertFalse(transcriptObjects.contains { object in
            object["role"]?.stringValue == "assistant"
                && MSPPlanModeTestSupport.text(in: object).contains("<proposed_plan>")
        })
        XCTAssertTrue(transcriptObjects.contains { object in
            object["metadata"]?.objectValue?["msp_internal_context_source"]?.stringValue == "plan_mode"
                && MSPPlanModeTestSupport.text(in: object).contains("Proposal ID:")
        })
        let eventSignatures = await events.signatures()
        XCTAssertEqual(eventSignatures, [
            "proposed:1:- Step 1\n- Step 2"
        ])
    }

    func testPlanningTurnDoesNotExposeUpdatePlanWhenPlanProgressIsEnabled() async throws {
        let requests = RecordedModelRequests()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeFinalPlanClient(requests: requests),
            planModeCapability: .enabled,
            planProgressCapability: .enabled()
        )

        _ = try await conversation.submitPlanningTurn(
            threadID: conversation.threadID,
            prompt: "Plan with checklist capability also configured."
        )

        let request = try await requests.request(at: 0)
        XCTAssertFalse(MSPPlanModeTestSupport.toolNames(in: request).contains("update_plan"))
    }

    func testPlanningTurnRejectsForgedUpdatePlanCallWithoutProgressEvent() async throws {
        let requests = RecordedModelRequests()
        let events = MSPPlanModeEventLog()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeUpdatePlanToolClient(requests: requests),
            planModeCapability: .enabled,
            planProgressCapability: .enabled()
        )

        let response = try await conversation.submitPlanningTurn(
            threadID: conversation.threadID,
            prompt: "Plan despite a forged update_plan call.",
            onEvent: { event in
                await events.append(event)
            }
        )

        XCTAssertEqual(response.proposedPlan?.proposedPlanContent, "- Planned after rejected tool")
        let followup = try await requests.request(at: 1)
        let output = try XCTUnwrap(followup.input.first { item in
            item.objectValue?["type"]?.stringValue == "function_call_output"
                && item.objectValue?["call_id"]?.stringValue == "call_plan_mode"
        })
        XCTAssertEqual(
            output.objectValue?["output"]?.stringValue,
            "update_plan is a TODO/checklist tool and is not allowed in Plan mode"
        )
        let eventSignatures = await events.signatures()
        XCTAssertEqual(eventSignatures, [
            "proposed:1:- Planned after rejected tool"
        ])
    }

    func testStreamingProposedPlanTagsAreParsedAcrossChunkBoundaries() async throws {
        let events = MSPPlanModeEventLog()
        let conversation = MSPPlanModeTestSupport.makeConversation(
            modelClient: MSPPlanModeStreamingClient(),
            planModeCapability: .enabled
        )

        let response = try await conversation.submitPlanningTurn(
            threadID: conversation.threadID,
            prompt: "Stream a plan.",
            onEvent: { event in
                await events.append(event)
            }
        )

        XCTAssertEqual(response.proposedPlan?.proposedPlanContent, "- streamed step")
        XCTAssertEqual(response.runResult.finalAnswer, "")
        let eventSignatures = await events.signatures()
        XCTAssertEqual(eventSignatures, [
            "delta:- streamed",
            "delta: step\n",
            "proposed:1:- streamed step"
        ])
    }
}
