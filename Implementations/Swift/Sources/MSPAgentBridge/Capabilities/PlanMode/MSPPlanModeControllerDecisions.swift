import Foundation

extension MSPPlanModeController {
    func approve(
        _ request: MSPPlanModeDecisionRequest,
        conversationThreadID: String
    ) throws -> MSPPlanModeDecisionResponse {
        try withLock {
            try validateDecisionRequest(request, conversationThreadID: conversationThreadID)
            let key = decisionKey(request.proposalID, request.proposalVersion)
            if let response = approvedResponses[key] {
                return response
            }
            if rejectedResponses[key] != nil {
                throw MSPPlanModeError.proposalAlreadyRejected(proposalID: request.proposalID)
            }
            let proposal = try currentProposal(
                proposalID: request.proposalID,
                proposalVersion: request.proposalVersion
            )
            let approvedAt = Date()
            let event = MSPPlanModeDecisionEvent(
                threadID: request.threadID,
                proposalID: proposal.proposalID,
                proposalVersion: proposal.proposalVersion,
                decision: .approved,
                source: request.source,
                eventID: "\(proposal.proposalID):approved",
                decidedAt: approvedAt,
                reason: request.reason
            )
            let handoff = makeHandoff(for: proposal, approvedAt: approvedAt)
            var state = snapshot ?? MSPPlanModeSnapshot(threadID: request.threadID)
            state.status = .implementing
            state.approvedProposal = proposal
            state.rejectedProposal = nil
            state.implementationHandoff = handoff
            state.updatedAt = handoff.handoffAt
            snapshot = state
            let response = MSPPlanModeDecisionResponse(
                proposal: proposal,
                snapshot: state,
                decisionEvent: event,
                handoff: handoff,
                runtimeEvents: [
                    .planModeApproved(event),
                    .planModeHandoff(handoff.handoffEvent)
                ]
            )
            approvedResponses[key] = response
            return response
        }
    }

    func reject(
        _ request: MSPPlanModeDecisionRequest,
        conversationThreadID: String
    ) throws -> MSPPlanModeDecisionResponse {
        try withLock {
            try validateDecisionRequest(request, conversationThreadID: conversationThreadID)
            let key = decisionKey(request.proposalID, request.proposalVersion)
            if let response = rejectedResponses[key] {
                return response
            }
            if approvedResponses[key] != nil {
                throw MSPPlanModeError.proposalAlreadyApproved(proposalID: request.proposalID)
            }
            let proposal = try currentProposal(
                proposalID: request.proposalID,
                proposalVersion: request.proposalVersion
            )
            let event = MSPPlanModeDecisionEvent(
                threadID: request.threadID,
                proposalID: proposal.proposalID,
                proposalVersion: proposal.proposalVersion,
                decision: .rejected,
                source: request.source,
                eventID: "\(proposal.proposalID):rejected",
                decidedAt: Date(),
                reason: request.reason
            )
            var state = snapshot ?? MSPPlanModeSnapshot(threadID: request.threadID)
            state.status = .rejected
            state.rejectedProposal = proposal
            state.approvedProposal = nil
            state.implementationHandoff = nil
            state.updatedAt = event.decidedAt
            snapshot = state
            let response = MSPPlanModeDecisionResponse(
                proposal: proposal,
                snapshot: state,
                decisionEvent: event,
                runtimeEvents: [.planModeRejected(event)]
            )
            rejectedResponses[key] = response
            return response
        }
    }

    func modify(
        _ request: MSPPlanModeModifyRequest,
        conversationThreadID: String
    ) throws -> MSPPlanModeModifyResponse {
        try withLock {
            try validateCapability()
            try validateThread(request.threadID, conversationThreadID)
            let previous = try currentProposal(
                proposalID: request.baseProposalID,
                proposalVersion: request.baseProposalVersion
            )
            let trimmed = request.revisedPlanContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MSPPlanModeError.emptyProposedPlan
            }
            let decidedAt = Date()
            let decision = MSPPlanModeDecisionEvent(
                threadID: request.threadID,
                proposalID: previous.proposalID,
                proposalVersion: previous.proposalVersion,
                decision: .modified,
                source: request.source,
                eventID: "\(previous.proposalID):modified",
                decidedAt: decidedAt,
                reason: request.reason
            )
            let proposal = MSPPlanModeProposalSnapshot(
                threadID: request.threadID,
                planningTurnID: previous.planningTurnID,
                proposalVersion: nextProposalVersion,
                proposedPlanContent: trimmed,
                createdAt: decidedAt,
                updatedAt: decidedAt,
                source: request.source,
                eventID: "\(previous.planningTurnID):plan-modified-\(nextProposalVersion)"
            )
            nextProposalVersion += 1
            approvedResponses.removeAll(keepingCapacity: false)
            rejectedResponses.removeAll(keepingCapacity: false)
            var state = snapshot ?? MSPPlanModeSnapshot(threadID: request.threadID)
            state.status = .proposed
            state.currentProposal = proposal
            state.approvedProposal = nil
            state.rejectedProposal = nil
            state.implementationHandoff = nil
            state.updatedAt = decidedAt
            snapshot = state
            return MSPPlanModeModifyResponse(
                previousProposal: previous,
                proposal: proposal,
                snapshot: state,
                decisionEvent: decision,
                proposedEvent: proposal.proposedEvent,
                runtimeEvents: [
                    .planModeModified(decision),
                    .planModeProposed(proposal.proposedEvent)
                ]
            )
        }
    }

    func currentProposal(
        proposalID: String,
        proposalVersion: Int
    ) throws -> MSPPlanModeProposalSnapshot {
        guard let current = snapshot?.currentProposal else {
            throw MSPPlanModeError.noProposedPlan
        }
        guard current.proposalID == proposalID,
              current.proposalVersion == proposalVersion else {
            throw MSPPlanModeError.staleProposal(
                expectedID: proposalID,
                expectedVersion: proposalVersion,
                actualID: current.proposalID,
                actualVersion: current.proposalVersion
            )
        }
        return current
    }

    func validateDecisionRequest(
        _ request: MSPPlanModeDecisionRequest,
        conversationThreadID: String
    ) throws {
        try validateCapability()
        try validateThread(request.threadID, conversationThreadID)
    }

    func makeHandoff(
        for proposal: MSPPlanModeProposalSnapshot,
        approvedAt: Date
    ) -> MSPPlanModeImplementationHandoff {
        MSPPlanModeImplementationHandoff(
            threadID: proposal.threadID,
            proposalID: proposal.proposalID,
            proposalVersion: proposal.proposalVersion,
            approvedAt: approvedAt,
            handoffAt: Date(),
            implementationPrompt: MSPPlanModeChatMapping.implementationPrompt,
            modelVisibleItems: MSPPlanModeChatMapping.implementationHandoffItems(for: proposal),
            eventID: "\(proposal.proposalID):handoff"
        )
    }

    func decisionKey(_ proposalID: String, _ version: Int) -> String {
        "\(proposalID)#\(version)"
    }
}
