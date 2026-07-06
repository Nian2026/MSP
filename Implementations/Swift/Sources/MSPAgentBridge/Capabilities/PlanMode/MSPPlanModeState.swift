import Foundation

public enum MSPPlanModeStatus: String, Codable, Hashable, Sendable {
    case inactive
    case planning
    case proposed
    case approved
    case rejected
    case implementing
}

public enum MSPPlanModeSource: String, Codable, Hashable, Sendable {
    case sdk
    case model
    case user
    case system
}

public struct MSPPlanModeProposalSnapshot: Codable, Hashable, Sendable {
    public var threadID: String
    public var planningTurnID: String
    public var proposalID: String
    public var proposalVersion: Int
    public var proposedPlanContent: String
    public var createdAt: Date
    public var updatedAt: Date
    public var source: MSPPlanModeSource
    public var eventID: String

    public init(
        threadID: String,
        planningTurnID: String,
        proposalID: String = UUID().uuidString,
        proposalVersion: Int,
        proposedPlanContent: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: MSPPlanModeSource,
        eventID: String
    ) {
        self.threadID = threadID
        self.planningTurnID = planningTurnID
        self.proposalID = proposalID
        self.proposalVersion = proposalVersion
        self.proposedPlanContent = proposedPlanContent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.eventID = eventID
    }
}

public struct MSPPlanModeImplementationHandoff: Codable, Hashable, Sendable {
    public var threadID: String
    public var proposalID: String
    public var proposalVersion: Int
    public var approvedAt: Date
    public var handoffAt: Date
    public var implementationPrompt: String
    public var modelVisibleItems: [MSPAgentJSONValue]
    public var eventID: String

    public init(
        threadID: String,
        proposalID: String,
        proposalVersion: Int,
        approvedAt: Date,
        handoffAt: Date,
        implementationPrompt: String,
        modelVisibleItems: [MSPAgentJSONValue],
        eventID: String
    ) {
        self.threadID = threadID
        self.proposalID = proposalID
        self.proposalVersion = proposalVersion
        self.approvedAt = approvedAt
        self.handoffAt = handoffAt
        self.implementationPrompt = implementationPrompt
        self.modelVisibleItems = modelVisibleItems
        self.eventID = eventID
    }
}

public struct MSPPlanModeSnapshot: Codable, Hashable, Sendable {
    public var threadID: String
    public var status: MSPPlanModeStatus
    public var currentProposal: MSPPlanModeProposalSnapshot?
    public var approvedProposal: MSPPlanModeProposalSnapshot?
    public var rejectedProposal: MSPPlanModeProposalSnapshot?
    public var implementationHandoff: MSPPlanModeImplementationHandoff?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        threadID: String,
        status: MSPPlanModeStatus = .inactive,
        currentProposal: MSPPlanModeProposalSnapshot? = nil,
        approvedProposal: MSPPlanModeProposalSnapshot? = nil,
        rejectedProposal: MSPPlanModeProposalSnapshot? = nil,
        implementationHandoff: MSPPlanModeImplementationHandoff? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.status = status
        self.currentProposal = currentProposal
        self.approvedProposal = approvedProposal
        self.rejectedProposal = rejectedProposal
        self.implementationHandoff = implementationHandoff
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MSPPlanModeRuntimeTurn: Sendable {
    var id: UUID
    var threadID: String
    var startedAt: Date
    var eventHandler: MSPAgentConversation.EventHandler
}

struct MSPPlanModeProposalOutcome {
    var proposal: MSPPlanModeProposalSnapshot
    var snapshot: MSPPlanModeSnapshot
    var event: MSPPlanModeProposedEvent
    var runtimeEvents: [MSPAgentEvent]
}
