import Foundation

public enum MSPPlanModeErrorReason: String, Hashable, Sendable {
    case capabilityDisabled = "capability_disabled"
    case threadMismatch = "thread_mismatch"
    case noActivePlanningTurn = "no_active_planning_turn"
    case emptyPrompt = "empty_prompt"
    case emptyProposedPlan = "empty_proposed_plan"
    case noProposedPlan = "no_proposed_plan"
    case staleProposal = "stale_proposal"
    case proposalAlreadyApproved = "proposal_already_approved"
    case proposalAlreadyRejected = "proposal_already_rejected"
}

public enum MSPPlanModeError: LocalizedError, Equatable, Sendable {
    case capabilityDisabled
    case threadMismatch(expected: String, actual: String)
    case noActivePlanningTurn
    case emptyPrompt
    case emptyProposedPlan
    case noProposedPlan
    case staleProposal(expectedID: String, expectedVersion: Int, actualID: String?, actualVersion: Int?)
    case proposalAlreadyApproved(proposalID: String)
    case proposalAlreadyRejected(proposalID: String)

    public var reason: MSPPlanModeErrorReason {
        switch self {
        case .capabilityDisabled:
            return .capabilityDisabled
        case .threadMismatch:
            return .threadMismatch
        case .noActivePlanningTurn:
            return .noActivePlanningTurn
        case .emptyPrompt:
            return .emptyPrompt
        case .emptyProposedPlan:
            return .emptyProposedPlan
        case .noProposedPlan:
            return .noProposedPlan
        case .staleProposal:
            return .staleProposal
        case .proposalAlreadyApproved:
            return .proposalAlreadyApproved
        case .proposalAlreadyRejected:
            return .proposalAlreadyRejected
        }
    }

    public var errorDescription: String? {
        switch self {
        case .capabilityDisabled:
            return "PlanMode capability is disabled."
        case let .threadMismatch(expected, actual):
            return "thread mismatch: expected \(expected), got \(actual)"
        case .noActivePlanningTurn:
            return "no active planning turn"
        case .emptyPrompt:
            return "PlanMode prompt must not be empty."
        case .emptyProposedPlan:
            return "proposed plan content must not be empty."
        case .noProposedPlan:
            return "no proposed plan is available for this thread."
        case let .staleProposal(expectedID, expectedVersion, actualID, actualVersion):
            return "stale proposal \(expectedID)#\(expectedVersion); current is \(actualID ?? "none")#\(actualVersion.map(String.init) ?? "none")"
        case let .proposalAlreadyApproved(proposalID):
            return "proposal \(proposalID) has already been approved."
        case let .proposalAlreadyRejected(proposalID):
            return "proposal \(proposalID) has already been rejected."
        }
    }
}
