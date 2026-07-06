import Foundation

public enum MSPGoalRejectionReason: String, Hashable, Sendable {
    case capabilityDisabled = "capability_disabled"
    case nonPersistentThread = "non_persistent_thread"
    case threadMismatch = "thread_mismatch"
    case emptyObjective = "empty_objective"
    case objectiveTooLong = "objective_too_long"
    case invalidTokenBudget = "invalid_token_budget"
    case unfinishedGoalExists = "unfinished_goal_exists"
    case noGoal = "no_goal"
    case modelToolStatusUnsupported = "model_tool_status_unsupported"
}

public enum MSPGoalError: Error, Equatable, LocalizedError, Sendable {
    case capabilityDisabled
    case nonPersistentThread(threadID: String)
    case threadMismatch(expected: String, actual: String)
    case emptyObjective
    case objectiveTooLong(maxCharacters: Int)
    case invalidTokenBudget
    case unfinishedGoalExists(goalID: String)
    case noGoal(threadID: String)
    case modelToolStatusUnsupported(status: MSPGoalStatus)

    public var reason: MSPGoalRejectionReason {
        switch self {
        case .capabilityDisabled:
            return .capabilityDisabled
        case .nonPersistentThread:
            return .nonPersistentThread
        case .threadMismatch:
            return .threadMismatch
        case .emptyObjective:
            return .emptyObjective
        case .objectiveTooLong:
            return .objectiveTooLong
        case .invalidTokenBudget:
            return .invalidTokenBudget
        case .unfinishedGoalExists:
            return .unfinishedGoalExists
        case .noGoal:
            return .noGoal
        case .modelToolStatusUnsupported:
            return .modelToolStatusUnsupported
        }
    }

    public var errorDescription: String? {
        switch self {
        case .capabilityDisabled:
            return "Goal capability is disabled."
        case let .nonPersistentThread(threadID):
            return "thread \(threadID) does not support persisted goals"
        case let .threadMismatch(expected, actual):
            return "expected thread id `\(expected)` but found `\(actual)`"
        case .emptyObjective:
            return "goal objective must not be empty"
        case let .objectiveTooLong(maxCharacters):
            return "goal objective must be at most \(maxCharacters) characters"
        case .invalidTokenBudget:
            return "goal budgets must be positive when provided"
        case let .unfinishedGoalExists(goalID):
            return "cannot create a new goal while unfinished goal \(goalID) exists"
        case let .noGoal(threadID):
            return "cannot update goal for thread \(threadID): no goal exists"
        case let .modelToolStatusUnsupported(status):
            return "update_goal cannot set status \(status.rawValue)"
        }
    }
}
