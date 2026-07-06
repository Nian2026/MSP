import Foundation

public protocol MSPPlanModeProtocol: AnyObject {
    func enterPlanMode(_ request: MSPPlanModeEnterRequest) async throws -> MSPPlanModeStateResponse
    func submitPlanningTurn(
        _ request: MSPPlanModePlanningTurnRequest,
        onRequestBuilt: MSPAgentConversation.RequestBuiltHandler?,
        onEvent: @escaping MSPAgentConversation.EventHandler
    ) async throws -> MSPPlanModePlanningTurnResponse
    func currentPlanModeState(threadID: String) async throws -> MSPPlanModeSnapshot
    func approveProposedPlan(_ request: MSPPlanModeDecisionRequest) async throws -> MSPPlanModeDecisionResponse
    func rejectProposedPlan(_ request: MSPPlanModeDecisionRequest) async throws -> MSPPlanModeDecisionResponse
    func modifyProposedPlan(_ request: MSPPlanModeModifyRequest) async throws -> MSPPlanModeModifyResponse
    func planModeCapabilityDeclaration() async -> MSPPlanModeCapabilityDeclaration
}

public extension MSPPlanModeProtocol {
    func enterPlanMode(threadID: String) async throws -> MSPPlanModeStateResponse {
        try await enterPlanMode(MSPPlanModeEnterRequest(threadID: threadID))
    }

    func submitPlanningTurn(
        threadID: String,
        prompt: String,
        onRequestBuilt: MSPAgentConversation.RequestBuiltHandler? = nil,
        onEvent: @escaping MSPAgentConversation.EventHandler = { _ in }
    ) async throws -> MSPPlanModePlanningTurnResponse {
        try await submitPlanningTurn(
            MSPPlanModePlanningTurnRequest(threadID: threadID, prompt: prompt),
            onRequestBuilt: onRequestBuilt,
            onEvent: onEvent
        )
    }

    func approveProposedPlan(
        threadID: String,
        proposalID: String,
        proposalVersion: Int
    ) async throws -> MSPPlanModeDecisionResponse {
        try await approveProposedPlan(MSPPlanModeDecisionRequest(
            threadID: threadID,
            proposalID: proposalID,
            proposalVersion: proposalVersion
        ))
    }

    func rejectProposedPlan(
        threadID: String,
        proposalID: String,
        proposalVersion: Int,
        reason: String? = nil
    ) async throws -> MSPPlanModeDecisionResponse {
        try await rejectProposedPlan(MSPPlanModeDecisionRequest(
            threadID: threadID,
            proposalID: proposalID,
            proposalVersion: proposalVersion,
            reason: reason
        ))
    }
}

public struct MSPPlanModeEnterRequest: Hashable, Sendable {
    public var threadID: String
    public var source: MSPPlanModeSource

    public init(threadID: String, source: MSPPlanModeSource = .sdk) {
        self.threadID = threadID
        self.source = source
    }
}

public struct MSPPlanModePlanningTurnRequest: Hashable, Sendable {
    public var threadID: String
    public var prompt: String
    public var source: MSPPlanModeSource

    public init(
        threadID: String,
        prompt: String,
        source: MSPPlanModeSource = .user
    ) {
        self.threadID = threadID
        self.prompt = prompt
        self.source = source
    }
}

public struct MSPPlanModeDecisionRequest: Hashable, Sendable {
    public var threadID: String
    public var proposalID: String
    public var proposalVersion: Int
    public var source: MSPPlanModeSource
    public var reason: String?

    public init(
        threadID: String,
        proposalID: String,
        proposalVersion: Int,
        source: MSPPlanModeSource = .user,
        reason: String? = nil
    ) {
        self.threadID = threadID
        self.proposalID = proposalID
        self.proposalVersion = proposalVersion
        self.source = source
        self.reason = reason
    }
}

public struct MSPPlanModeModifyRequest: Hashable, Sendable {
    public var threadID: String
    public var baseProposalID: String
    public var baseProposalVersion: Int
    public var revisedPlanContent: String
    public var source: MSPPlanModeSource
    public var reason: String?

    public init(
        threadID: String,
        baseProposalID: String,
        baseProposalVersion: Int,
        revisedPlanContent: String,
        source: MSPPlanModeSource = .user,
        reason: String? = nil
    ) {
        self.threadID = threadID
        self.baseProposalID = baseProposalID
        self.baseProposalVersion = baseProposalVersion
        self.revisedPlanContent = revisedPlanContent
        self.source = source
        self.reason = reason
    }
}

public struct MSPPlanModeStateResponse: Hashable, Sendable {
    public var snapshot: MSPPlanModeSnapshot
    public var acceptedAt: Date

    public init(snapshot: MSPPlanModeSnapshot, acceptedAt: Date) {
        self.snapshot = snapshot
        self.acceptedAt = acceptedAt
    }
}

public struct MSPPlanModePlanningTurnResponse: Hashable, Sendable {
    public var threadID: String
    public var planningTurnID: String
    public var snapshot: MSPPlanModeSnapshot
    public var proposedPlan: MSPPlanModeProposalSnapshot?
    public var runResult: MSPAgentRunResult
    public var runtimeEvents: [MSPAgentEvent]

    public init(
        threadID: String,
        planningTurnID: String,
        snapshot: MSPPlanModeSnapshot,
        proposedPlan: MSPPlanModeProposalSnapshot?,
        runResult: MSPAgentRunResult,
        runtimeEvents: [MSPAgentEvent]
    ) {
        self.threadID = threadID
        self.planningTurnID = planningTurnID
        self.snapshot = snapshot
        self.proposedPlan = proposedPlan
        self.runResult = runResult
        self.runtimeEvents = runtimeEvents
    }
}

public struct MSPPlanModeDecisionResponse: Hashable, Sendable {
    public var proposal: MSPPlanModeProposalSnapshot
    public var snapshot: MSPPlanModeSnapshot
    public var decisionEvent: MSPPlanModeDecisionEvent
    public var handoff: MSPPlanModeImplementationHandoff?
    public var runtimeEvents: [MSPAgentEvent]

    public init(
        proposal: MSPPlanModeProposalSnapshot,
        snapshot: MSPPlanModeSnapshot,
        decisionEvent: MSPPlanModeDecisionEvent,
        handoff: MSPPlanModeImplementationHandoff? = nil,
        runtimeEvents: [MSPAgentEvent]
    ) {
        self.proposal = proposal
        self.snapshot = snapshot
        self.decisionEvent = decisionEvent
        self.handoff = handoff
        self.runtimeEvents = runtimeEvents
    }
}

public struct MSPPlanModeModifyResponse: Hashable, Sendable {
    public var previousProposal: MSPPlanModeProposalSnapshot
    public var proposal: MSPPlanModeProposalSnapshot
    public var snapshot: MSPPlanModeSnapshot
    public var decisionEvent: MSPPlanModeDecisionEvent
    public var proposedEvent: MSPPlanModeProposedEvent
    public var runtimeEvents: [MSPAgentEvent]

    public init(
        previousProposal: MSPPlanModeProposalSnapshot,
        proposal: MSPPlanModeProposalSnapshot,
        snapshot: MSPPlanModeSnapshot,
        decisionEvent: MSPPlanModeDecisionEvent,
        proposedEvent: MSPPlanModeProposedEvent,
        runtimeEvents: [MSPAgentEvent]
    ) {
        self.previousProposal = previousProposal
        self.proposal = proposal
        self.snapshot = snapshot
        self.decisionEvent = decisionEvent
        self.proposedEvent = proposedEvent
        self.runtimeEvents = runtimeEvents
    }
}
