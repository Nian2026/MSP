import Foundation

public enum MSPPlanModeChatMapping {
    public static let proposedTimelineType = "plan_mode_proposed"
    public static let modifiedTimelineType = "plan_mode_modified"
    public static let approvedTimelineType = "plan_mode_approved"
    public static let rejectedTimelineType = "plan_mode_rejected"
    public static let handoffTimelineType = "plan_mode_handoff"

    public static let implementationPrompt = "Implement the plan."

    public static var developerInstructions: String {
        """
        <collaboration_mode>
        You are in Plan Mode.

        Plan Mode is a planning collaboration mode, not the update_plan checklist tool.
        Do not call or rely on update_plan while in Plan Mode.

        Plan Mode may inspect the environment and run non-mutating checks that improve the plan.
        Do not edit files, apply patches, run migrations, or perform mutating implementation work.

        When the plan is decision-complete, output exactly one proposed plan block:
        <proposed_plan>
        concise implementation-ready plan
        </proposed_plan>

        Keep the tags exactly as <proposed_plan> and </proposed_plan>.
        Text inside the block is the official proposed plan.
        Text outside the block is ordinary planning discussion.
        </collaboration_mode>
        """
    }

    public static func proposedPlanTranscriptItem(
        for proposal: MSPPlanModeProposalSnapshot
    ) -> MSPAgentJSONValue {
        internalPlanContextItem("""
        <proposed_plan_fact>
        Proposal ID: \(proposal.proposalID)
        Proposal version: \(proposal.proposalVersion)
        Planning turn ID: \(proposal.planningTurnID)
        Proposed plan:
        \(escapeXML(proposal.proposedPlanContent))
        </proposed_plan_fact>
        """)
    }

    public static func implementationHandoffItems(
        for proposal: MSPPlanModeProposalSnapshot
    ) -> [MSPAgentJSONValue] {
        [
            internalPlanContextItem("""
            <approved_plan_handoff>
            The user approved the proposed plan below. Switch out of Plan Mode and implement it.
            Proposal ID: \(proposal.proposalID)
            Proposal version: \(proposal.proposalVersion)
            Proposed plan:
            \(escapeXML(proposal.proposedPlanContent))
            </approved_plan_handoff>
            """),
            .object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string(implementationPrompt)
                    ])
                ])
            ])
        ]
    }

    public static func timelinePayload(
        for event: MSPPlanModeProposedEvent
    ) -> [String: MSPAgentJSONValue] {
        [
            "thread_id": .string(event.threadID),
            "planning_turn_id": .string(event.planningTurnID),
            "proposal_id": .string(event.proposalID),
            "proposal_version": .number(Double(event.proposalVersion)),
            "content": .string(event.proposedPlanContent),
            "source": .string(event.source.rawValue),
            "event_id": .string(event.eventID),
            "proposed_at": .string(isoString(event.proposedAt))
        ]
    }

    public static func timelinePayload(
        for event: MSPPlanModeDecisionEvent
    ) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "thread_id": .string(event.threadID),
            "proposal_id": .string(event.proposalID),
            "proposal_version": .number(Double(event.proposalVersion)),
            "decision": .string(event.decision.rawValue),
            "source": .string(event.source.rawValue),
            "event_id": .string(event.eventID),
            "decided_at": .string(isoString(event.decidedAt))
        ]
        if let reason = event.reason {
            payload["reason"] = .string(reason)
        }
        return payload
    }

    public static func timelinePayload(
        for event: MSPPlanModeHandoffEvent
    ) -> [String: MSPAgentJSONValue] {
        [
            "thread_id": .string(event.threadID),
            "proposal_id": .string(event.proposalID),
            "proposal_version": .number(Double(event.proposalVersion)),
            "event_id": .string(event.eventID),
            "handoff_at": .string(isoString(event.handoffAt)),
            "implementation_prompt": .string(event.implementationPrompt),
            "model_input_item_count": .number(Double(event.modelInputItemCount))
        ]
    }

    public static func referenceContextEvent(
        for proposal: MSPPlanModeProposalSnapshot
    ) -> MSPAgentJSONValue {
        .object([
            "kind": .string(proposedTimelineType),
            "id": .string(proposal.proposalID),
            "planning_turn_id": .string(proposal.planningTurnID),
            "proposal_version": .number(Double(proposal.proposalVersion))
        ])
    }

    private static func internalPlanContextItem(_ text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text)
                ])
            ]),
            "metadata": .object([
                "msp_internal_context_source": .string("plan_mode")
            ])
        ])
    }

    static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
