import Foundation

public struct MSPGoalUpdatedEvent: Hashable, Sendable {
    public var threadID: String
    public var turnID: String?
    public var goal: MSPGoalSnapshot
    public var previousGoal: MSPGoalSnapshot?
    public var source: MSPGoalUpdateSource
    public var reason: MSPGoalMutationReason
    public var eventID: String
    public var occurredAt: Date

    public init(
        threadID: String,
        turnID: String?,
        goal: MSPGoalSnapshot,
        previousGoal: MSPGoalSnapshot?,
        source: MSPGoalUpdateSource,
        reason: MSPGoalMutationReason,
        eventID: String,
        occurredAt: Date = Date()
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.goal = goal
        self.previousGoal = previousGoal
        self.source = source
        self.reason = reason
        self.eventID = eventID
        self.occurredAt = occurredAt
    }
}

public struct MSPGoalClearedEvent: Hashable, Sendable {
    public var threadID: String
    public var clearedGoal: MSPGoalSnapshot?
    public var source: MSPGoalUpdateSource
    public var eventID: String
    public var occurredAt: Date

    public init(
        threadID: String,
        clearedGoal: MSPGoalSnapshot?,
        source: MSPGoalUpdateSource,
        eventID: String,
        occurredAt: Date = Date()
    ) {
        self.threadID = threadID
        self.clearedGoal = clearedGoal
        self.source = source
        self.eventID = eventID
        self.occurredAt = occurredAt
    }
}

public struct MSPGoalAccountedEvent: Hashable, Sendable {
    public var threadID: String
    public var turnID: String?
    public var goalID: String
    public var tokenDelta: Int
    public var timeDeltaSeconds: Int
    public var tokensUsed: Int
    public var timeUsedSeconds: Int
    public var status: MSPGoalStatus
    public var eventID: String
    public var occurredAt: Date

    public init(
        threadID: String,
        turnID: String?,
        goalID: String,
        tokenDelta: Int,
        timeDeltaSeconds: Int,
        tokensUsed: Int,
        timeUsedSeconds: Int,
        status: MSPGoalStatus,
        eventID: String,
        occurredAt: Date = Date()
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.goalID = goalID
        self.tokenDelta = tokenDelta
        self.timeDeltaSeconds = timeDeltaSeconds
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.status = status
        self.eventID = eventID
        self.occurredAt = occurredAt
    }
}
