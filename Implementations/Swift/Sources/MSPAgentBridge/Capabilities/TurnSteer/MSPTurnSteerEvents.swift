import Foundation

public struct MSPTurnSteerAcceptedEvent: Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var turnStartedAt: Date
    public var sequenceNumber: Int
    public var contentText: String
    public var clientUserMessageID: String?
    public var requestedAt: Date
    public var acceptedAt: Date

    public init(
        threadID: String,
        turnID: String,
        turnStartedAt: Date,
        sequenceNumber: Int,
        contentText: String,
        clientUserMessageID: String?,
        requestedAt: Date,
        acceptedAt: Date
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.turnStartedAt = turnStartedAt
        self.sequenceNumber = sequenceNumber
        self.contentText = contentText
        self.clientUserMessageID = clientUserMessageID
        self.requestedAt = requestedAt
        self.acceptedAt = acceptedAt
    }
}

public enum MSPTurnSteerApplicationBoundary: String, Hashable, Sendable {
    case modelInput = "model_input"
    case terminalTranscript = "terminal_transcript"
    case interruptedTranscript = "interrupted_transcript"
}

public struct MSPTurnSteerAppliedEvent: Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var sequenceNumber: Int
    public var contentText: String
    public var clientUserMessageID: String?
    public var requestedAt: Date
    public var acceptedAt: Date
    public var appliedAt: Date
    public var boundary: MSPTurnSteerApplicationBoundary
    public var modelInputItemCount: Int

    public init(
        threadID: String,
        turnID: String,
        sequenceNumber: Int,
        contentText: String,
        clientUserMessageID: String?,
        requestedAt: Date,
        acceptedAt: Date,
        appliedAt: Date,
        boundary: MSPTurnSteerApplicationBoundary,
        modelInputItemCount: Int
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.sequenceNumber = sequenceNumber
        self.contentText = contentText
        self.clientUserMessageID = clientUserMessageID
        self.requestedAt = requestedAt
        self.acceptedAt = acceptedAt
        self.appliedAt = appliedAt
        self.boundary = boundary
        self.modelInputItemCount = modelInputItemCount
    }
}
