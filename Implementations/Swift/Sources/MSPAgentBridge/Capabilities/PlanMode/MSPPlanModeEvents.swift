import Foundation

public struct MSPPlanModeProposalDeltaEvent: Hashable, Sendable {
    public var threadID: String
    public var planningTurnID: String
    public var itemID: String
    public var delta: String

    public init(
        threadID: String,
        planningTurnID: String,
        itemID: String,
        delta: String
    ) {
        self.threadID = threadID
        self.planningTurnID = planningTurnID
        self.itemID = itemID
        self.delta = delta
    }
}

public struct MSPPlanModeProposedEvent: Hashable, Sendable {
    public var threadID: String
    public var planningTurnID: String
    public var proposalID: String
    public var proposalVersion: Int
    public var proposedPlanContent: String
    public var source: MSPPlanModeSource
    public var eventID: String
    public var proposedAt: Date

    public init(
        threadID: String,
        planningTurnID: String,
        proposalID: String,
        proposalVersion: Int,
        proposedPlanContent: String,
        source: MSPPlanModeSource,
        eventID: String,
        proposedAt: Date
    ) {
        self.threadID = threadID
        self.planningTurnID = planningTurnID
        self.proposalID = proposalID
        self.proposalVersion = proposalVersion
        self.proposedPlanContent = proposedPlanContent
        self.source = source
        self.eventID = eventID
        self.proposedAt = proposedAt
    }
}

public struct MSPPlanModeDecisionEvent: Hashable, Sendable {
    public enum Decision: String, Hashable, Sendable {
        case approved
        case rejected
        case modified
    }

    public var threadID: String
    public var proposalID: String
    public var proposalVersion: Int
    public var decision: Decision
    public var source: MSPPlanModeSource
    public var eventID: String
    public var decidedAt: Date
    public var reason: String?

    public init(
        threadID: String,
        proposalID: String,
        proposalVersion: Int,
        decision: Decision,
        source: MSPPlanModeSource,
        eventID: String,
        decidedAt: Date,
        reason: String? = nil
    ) {
        self.threadID = threadID
        self.proposalID = proposalID
        self.proposalVersion = proposalVersion
        self.decision = decision
        self.source = source
        self.eventID = eventID
        self.decidedAt = decidedAt
        self.reason = reason
    }
}

public struct MSPPlanModeHandoffEvent: Hashable, Sendable {
    public var threadID: String
    public var proposalID: String
    public var proposalVersion: Int
    public var eventID: String
    public var handoffAt: Date
    public var implementationPrompt: String
    public var modelInputItemCount: Int

    public init(
        threadID: String,
        proposalID: String,
        proposalVersion: Int,
        eventID: String,
        handoffAt: Date,
        implementationPrompt: String,
        modelInputItemCount: Int
    ) {
        self.threadID = threadID
        self.proposalID = proposalID
        self.proposalVersion = proposalVersion
        self.eventID = eventID
        self.handoffAt = handoffAt
        self.implementationPrompt = implementationPrompt
        self.modelInputItemCount = modelInputItemCount
    }
}

extension MSPPlanModeProposalSnapshot {
    var proposedEvent: MSPPlanModeProposedEvent {
        MSPPlanModeProposedEvent(
            threadID: threadID,
            planningTurnID: planningTurnID,
            proposalID: proposalID,
            proposalVersion: proposalVersion,
            proposedPlanContent: proposedPlanContent,
            source: source,
            eventID: eventID,
            proposedAt: updatedAt
        )
    }
}

extension MSPPlanModeImplementationHandoff {
    var handoffEvent: MSPPlanModeHandoffEvent {
        MSPPlanModeHandoffEvent(
            threadID: threadID,
            proposalID: proposalID,
            proposalVersion: proposalVersion,
            eventID: eventID,
            handoffAt: handoffAt,
            implementationPrompt: implementationPrompt,
            modelInputItemCount: modelVisibleItems.count
        )
    }
}
