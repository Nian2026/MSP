import Foundation

public enum MSPGoalStatus: String, Codable, Hashable, Sendable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete

    public var isUnfinished: Bool {
        self != .complete
    }

    public var stopsActiveAccounting: Bool {
        switch self {
        case .active:
            return false
        case .paused, .blocked, .usageLimited, .budgetLimited, .complete:
            return true
        }
    }
}

public enum MSPGoalUpdateSource: String, Codable, Hashable, Sendable {
    case sdk
    case modelTool
    case system
    case runtime
}

public enum MSPGoalMutationReason: String, Codable, Hashable, Sendable {
    case created
    case replaced
    case updated
    case accounted
    case statusChanged
    case cleared
}

public struct MSPGoalSnapshot: Codable, Hashable, Sendable {
    public var threadID: String
    public var goalID: String
    public var objective: String
    public var status: MSPGoalStatus
    public var tokenBudget: Int?
    public var tokensUsed: Int
    public var remainingTokens: Int?
    public var timeUsedSeconds: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        threadID: String,
        goalID: String = UUID().uuidString,
        objective: String,
        status: MSPGoalStatus = .active,
        tokenBudget: Int? = nil,
        tokensUsed: Int = 0,
        timeUsedSeconds: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.goalID = goalID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = max(0, tokensUsed)
        self.remainingTokens = tokenBudget.map { max(0, $0 - max(0, tokensUsed)) }
        self.timeUsedSeconds = max(0, timeUsedSeconds)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var withRecomputedBudget: MSPGoalSnapshot {
        var copy = self
        copy.remainingTokens = tokenBudget.map { max(0, $0 - tokensUsed) }
        if copy.status == .active,
           let tokenBudget,
           copy.tokensUsed >= tokenBudget {
            copy.status = .budgetLimited
        }
        return copy
    }
}

enum MSPGoalTurnKind: String, Hashable, Sendable {
    case user
    case planning
    case maintenance
}

enum MSPGoalTurnStatus: String, Hashable, Sendable {
    case running
    case completed
    case interrupted
    case failed
    case usageLimited
}

struct MSPGoalRuntimeTurn: Sendable {
    var id: UUID
    var threadID: String
    var kind: MSPGoalTurnKind
    var startedAt: Date
    var accountTokens: Bool
    var activeGoalID: String?
    var unaccountedTokens: Int
    var lastAccountedAt: Date
    var pendingContextItems: [MSPAgentJSONValue]

    init(
        id: UUID,
        threadID: String,
        kind: MSPGoalTurnKind,
        startedAt: Date,
        activeGoalID: String?
    ) {
        self.id = id
        self.threadID = threadID
        self.kind = kind
        self.startedAt = startedAt
        self.accountTokens = kind == .user
        self.activeGoalID = accountTokens ? activeGoalID : nil
        self.unaccountedTokens = 0
        self.lastAccountedAt = startedAt
        self.pendingContextItems = []
    }
}

struct MSPGoalToolExecutionOutcome {
    var result: MSPAgentToolResult
    var events: [MSPAgentEvent]
}

struct MSPGoalLifecycleOutcome {
    var events: [MSPAgentEvent]
}

struct MSPGoalMutationOutcome {
    var response: MSPGoalMutationResponse
    var events: [MSPAgentEvent]
}
