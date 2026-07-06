import Foundation

final class MSPPlanModeController {
    let lock = NSRecursiveLock()
    let capability: MSPPlanModeCapability
    var snapshot: MSPPlanModeSnapshot?
    var activePlanningTurn: MSPPlanModeRuntimeTurn?
    var approvedResponses: [String: MSPPlanModeDecisionResponse] = [:]
    var rejectedResponses: [String: MSPPlanModeDecisionResponse] = [:]
    var nextProposalVersion = 1

    init(capability: MSPPlanModeCapability) {
        self.capability = capability
    }

    var declaration: MSPPlanModeCapabilityDeclaration {
        withLock { capability.declaration }
    }

    func currentState(
        threadID: String,
        conversationThreadID: String
    ) throws -> MSPPlanModeSnapshot {
        try withLock {
            try validateCapability()
            try validateThread(threadID, conversationThreadID)
            return snapshot ?? MSPPlanModeSnapshot(threadID: conversationThreadID)
        }
    }

    func enterPlanMode(
        _ request: MSPPlanModeEnterRequest,
        conversationThreadID: String
    ) throws -> MSPPlanModeStateResponse {
        try withLock {
            try validateCapability()
            try validateThread(request.threadID, conversationThreadID)
            var state = snapshot ?? MSPPlanModeSnapshot(threadID: conversationThreadID)
            state.status = .planning
            state.updatedAt = Date()
            snapshot = state
            return MSPPlanModeStateResponse(snapshot: state, acceptedAt: state.updatedAt)
        }
    }

    func startPlanningTurn(
        id turnID: UUID,
        threadID: String,
        startedAt: Date,
        eventHandler: @escaping MSPAgentConversation.EventHandler
    ) throws {
        try withLock {
            try validateCapability()
            activePlanningTurn = MSPPlanModeRuntimeTurn(
                id: turnID,
                threadID: threadID,
                startedAt: startedAt,
                eventHandler: eventHandler
            )
            var state = snapshot ?? MSPPlanModeSnapshot(threadID: threadID)
            state.status = .planning
            state.updatedAt = startedAt
            snapshot = state
        }
    }

    func completePlanningTurn(
        id turnID: UUID
    ) {
        withLock {
            guard activePlanningTurn?.id == turnID else {
                return
            }
            activePlanningTurn = nil
        }
    }

    func recordProposedPlan(
        content: String,
        planningTurnID: UUID,
        source: MSPPlanModeSource
    ) throws -> MSPPlanModeProposalOutcome {
        try withLock {
            try validateCapability()
            guard let turn = activePlanningTurn, turn.id == planningTurnID else {
                throw MSPPlanModeError.noActivePlanningTurn
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MSPPlanModeError.emptyProposedPlan
            }

            let proposedAt = Date()
            let proposal = MSPPlanModeProposalSnapshot(
                threadID: turn.threadID,
                planningTurnID: turn.id.uuidString,
                proposalVersion: nextProposalVersion,
                proposedPlanContent: trimmed,
                createdAt: proposedAt,
                updatedAt: proposedAt,
                source: source,
                eventID: "\(turn.id.uuidString):plan-proposed-\(nextProposalVersion)"
            )
            nextProposalVersion += 1
            approvedResponses.removeAll(keepingCapacity: false)
            rejectedResponses.removeAll(keepingCapacity: false)
            var state = snapshot ?? MSPPlanModeSnapshot(threadID: turn.threadID)
            state.status = .proposed
            state.currentProposal = proposal
            state.approvedProposal = nil
            state.rejectedProposal = nil
            state.implementationHandoff = nil
            state.updatedAt = proposedAt
            snapshot = state

            let event = proposal.proposedEvent
            return MSPPlanModeProposalOutcome(
                proposal: proposal,
                snapshot: state,
                event: event,
                runtimeEvents: [.planModeProposed(event)]
            )
        }
    }

    func validateCapability() throws {
        guard capability.isEnabled else {
            throw MSPPlanModeError.capabilityDisabled
        }
    }

    func validateThread(_ requested: String, _ actual: String) throws {
        guard requested == actual else {
            throw MSPPlanModeError.threadMismatch(expected: requested, actual: actual)
        }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
