import Foundation

public struct MSPPlanProgressUpdatedEvent: Hashable, Sendable {
    public var eventID: String
    public var threadID: String
    public var turnID: String
    public var explanation: String?
    public var plan: [MSPUpdatePlanItem]

    public init(
        eventID: String,
        threadID: String,
        turnID: String,
        explanation: String?,
        plan: [MSPUpdatePlanItem]
    ) {
        self.eventID = eventID
        self.threadID = threadID
        self.turnID = turnID
        self.explanation = explanation
        self.plan = plan
    }
}

struct MSPPlanProgressToolExecutionOutcome: Hashable, Sendable {
    var result: MSPAgentToolResult
    var event: MSPPlanProgressUpdatedEvent?
}
