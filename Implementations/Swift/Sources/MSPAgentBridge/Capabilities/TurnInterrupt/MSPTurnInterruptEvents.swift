import Foundation

public enum MSPTurnInterruptAbortReason: String, Codable, Hashable, Sendable {
    case interrupted
    case replaced
    case reviewEnded = "review_ended"
    case budgetLimited = "budget_limited"
}

public struct MSPTurnInterruptTurnStartedEvent: Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var startedAt: Date

    public init(threadID: String, turnID: String, startedAt: Date) {
        self.threadID = threadID
        self.turnID = turnID
        self.startedAt = startedAt
    }
}

public struct MSPTurnInterruptTurnAbortedEvent: Hashable, Sendable {
    public var threadID: String
    public var turnID: String?
    public var reason: MSPTurnInterruptAbortReason
    public var completedAt: Date
    public var durationMilliseconds: Int?

    public init(
        threadID: String,
        turnID: String?,
        reason: MSPTurnInterruptAbortReason,
        completedAt: Date,
        durationMilliseconds: Int?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.reason = reason
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
    }
}
