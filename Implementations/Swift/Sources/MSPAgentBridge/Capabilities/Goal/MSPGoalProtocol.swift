import Foundation

public protocol MSPGoalProtocol: AnyObject {
    func currentGoal(threadID: String) async throws -> MSPGoalSnapshot?
    func createGoal(_ request: MSPGoalCreateRequest) async throws -> MSPGoalMutationResponse
    func setGoal(_ request: MSPGoalSetRequest) async throws -> MSPGoalMutationResponse
    func updateGoal(_ request: MSPGoalUpdateRequest) async throws -> MSPGoalMutationResponse
    func clearGoal(threadID: String) async throws -> MSPGoalClearResponse
    func continueActiveGoalIfIdle(
        onRequestBuilt: MSPAgentConversation.RequestBuiltHandler?,
        onEvent: @escaping MSPAgentConversation.EventHandler
    ) async throws -> MSPAgentRunResult?
    func goalCapabilityDeclaration() async -> MSPGoalCapabilityDeclaration
}

public extension MSPGoalProtocol {
    func createGoal(
        threadID: String,
        objective: String,
        tokenBudget: Int? = nil
    ) async throws -> MSPGoalMutationResponse {
        try await createGoal(MSPGoalCreateRequest(
            threadID: threadID,
            objective: objective,
            tokenBudget: tokenBudget
        ))
    }

    func setGoal(
        threadID: String,
        objective: String? = nil,
        status: MSPGoalStatus? = nil,
        tokenBudget: MSPGoalTokenBudgetUpdate = .keep
    ) async throws -> MSPGoalMutationResponse {
        try await setGoal(MSPGoalSetRequest(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        ))
    }

    func updateGoal(
        threadID: String,
        status: MSPGoalStatus
    ) async throws -> MSPGoalMutationResponse {
        try await updateGoal(MSPGoalUpdateRequest(
            threadID: threadID,
            status: status
        ))
    }

    func continueActiveGoalIfIdle() async throws -> MSPAgentRunResult? {
        try await continueActiveGoalIfIdle(
            onRequestBuilt: nil,
            onEvent: { _ in }
        )
    }

    func continueActiveGoalIfIdle(
        onEvent: @escaping MSPAgentConversation.EventHandler
    ) async throws -> MSPAgentRunResult? {
        try await continueActiveGoalIfIdle(
            onRequestBuilt: nil,
            onEvent: onEvent
        )
    }
}

public struct MSPGoalCreateRequest: Hashable, Sendable {
    public var threadID: String
    public var objective: String
    public var tokenBudget: Int?
    public var source: MSPGoalUpdateSource
    public var sourceTurnID: String?

    public init(
        threadID: String,
        objective: String,
        tokenBudget: Int? = nil,
        source: MSPGoalUpdateSource = .sdk,
        sourceTurnID: String? = nil
    ) {
        self.threadID = threadID
        self.objective = objective
        self.tokenBudget = tokenBudget
        self.source = source
        self.sourceTurnID = sourceTurnID
    }
}

public struct MSPGoalSetRequest: Hashable, Sendable {
    public var threadID: String
    public var objective: String?
    public var status: MSPGoalStatus?
    public var tokenBudget: MSPGoalTokenBudgetUpdate
    public var source: MSPGoalUpdateSource
    public var sourceTurnID: String?

    public init(
        threadID: String,
        objective: String? = nil,
        status: MSPGoalStatus? = nil,
        tokenBudget: MSPGoalTokenBudgetUpdate = .keep,
        source: MSPGoalUpdateSource = .sdk,
        sourceTurnID: String? = nil
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.source = source
        self.sourceTurnID = sourceTurnID
    }
}

public struct MSPGoalUpdateRequest: Hashable, Sendable {
    public var threadID: String
    public var status: MSPGoalStatus
    public var source: MSPGoalUpdateSource
    public var sourceTurnID: String?

    public init(
        threadID: String,
        status: MSPGoalStatus,
        source: MSPGoalUpdateSource = .sdk,
        sourceTurnID: String? = nil
    ) {
        self.threadID = threadID
        self.status = status
        self.source = source
        self.sourceTurnID = sourceTurnID
    }
}

public enum MSPGoalTokenBudgetUpdate: Hashable, Sendable {
    case keep
    case set(Int?)

    var valueForCreate: Int? {
        switch self {
        case .keep:
            return nil
        case .set(let value):
            return value
        }
    }
}

public struct MSPGoalMutationResponse: Hashable, Sendable {
    public var goal: MSPGoalSnapshot
    public var previousGoal: MSPGoalSnapshot?
    public var source: MSPGoalUpdateSource
    public var sourceTurnID: String?
    public var eventID: String
    public var acceptedAt: Date
    public var reason: MSPGoalMutationReason
    public var runtimeEvents: [MSPAgentEvent]

    public init(
        goal: MSPGoalSnapshot,
        previousGoal: MSPGoalSnapshot?,
        source: MSPGoalUpdateSource,
        sourceTurnID: String?,
        eventID: String,
        acceptedAt: Date,
        reason: MSPGoalMutationReason,
        runtimeEvents: [MSPAgentEvent] = []
    ) {
        self.goal = goal
        self.previousGoal = previousGoal
        self.source = source
        self.sourceTurnID = sourceTurnID
        self.eventID = eventID
        self.acceptedAt = acceptedAt
        self.reason = reason
        self.runtimeEvents = runtimeEvents
    }
}

public struct MSPGoalClearResponse: Hashable, Sendable {
    public var threadID: String
    public var cleared: Bool
    public var clearedGoal: MSPGoalSnapshot?
    public var source: MSPGoalUpdateSource
    public var eventID: String
    public var clearedAt: Date
    public var runtimeEvents: [MSPAgentEvent]

    public init(
        threadID: String,
        cleared: Bool,
        clearedGoal: MSPGoalSnapshot?,
        source: MSPGoalUpdateSource,
        eventID: String,
        clearedAt: Date,
        runtimeEvents: [MSPAgentEvent] = []
    ) {
        self.threadID = threadID
        self.cleared = cleared
        self.clearedGoal = clearedGoal
        self.source = source
        self.eventID = eventID
        self.clearedAt = clearedAt
        self.runtimeEvents = runtimeEvents
    }
}
