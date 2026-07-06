import Foundation

public enum MSPTurnSteerTurnStatus: String, Hashable, Sendable {
    case running
    case interrupting
    case completed
    case interrupted
    case failed
}

public enum MSPTurnSteerTurnKind: String, Hashable, Sendable {
    case user
    case planning
    case maintenance
}

public struct MSPTurnSteerActiveTurn: Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var status: MSPTurnSteerTurnStatus
    public var kind: MSPTurnSteerTurnKind
    public var startedAt: Date

    public init(
        threadID: String,
        turnID: String,
        status: MSPTurnSteerTurnStatus,
        kind: MSPTurnSteerTurnKind,
        startedAt: Date
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.kind = kind
        self.startedAt = startedAt
    }
}

struct MSPTurnSteerRuntimeTurn {
    var id: UUID
    var threadID: String
    var kind: MSPTurnSteerTurnKind
    var status: MSPTurnSteerTurnStatus
    var startedAt: Date
    var eventHandler: MSPAgentConversation.EventHandler
    var pendingInputs: [MSPTurnSteerAcceptedInput] = []

    var activeSnapshot: MSPTurnSteerActiveTurn {
        MSPTurnSteerActiveTurn(
            threadID: threadID,
            turnID: id.uuidString,
            status: status,
            kind: kind,
            startedAt: startedAt
        )
    }
}

struct MSPTurnSteerAcceptedInput: Hashable, Sendable {
    var target: MSPTurnSteerActiveTurn
    var sequenceNumber: Int
    var input: MSPTurnSteerInput
    var requestedAt: Date
    var acceptedAt: Date
    var modelVisibleItems: [MSPAgentJSONValue]

    var response: MSPTurnSteerResponse {
        MSPTurnSteerResponse(
            target: target,
            sequenceNumber: sequenceNumber,
            content: input,
            requestedAt: requestedAt,
            acceptedAt: acceptedAt
        )
    }

    var acceptedEvent: MSPTurnSteerAcceptedEvent {
        MSPTurnSteerAcceptedEvent(
            threadID: target.threadID,
            turnID: target.turnID,
            turnStartedAt: target.startedAt,
            sequenceNumber: sequenceNumber,
            contentText: input.text,
            clientUserMessageID: input.clientUserMessageID,
            requestedAt: requestedAt,
            acceptedAt: acceptedAt
        )
    }

    func appliedEvent(
        at appliedAt: Date,
        boundary: MSPTurnSteerApplicationBoundary
    ) -> MSPTurnSteerAppliedEvent {
        MSPTurnSteerAppliedEvent(
            threadID: target.threadID,
            turnID: target.turnID,
            sequenceNumber: sequenceNumber,
            contentText: input.text,
            clientUserMessageID: input.clientUserMessageID,
            requestedAt: requestedAt,
            acceptedAt: acceptedAt,
            appliedAt: appliedAt,
            boundary: boundary,
            modelInputItemCount: modelVisibleItems.count
        )
    }
}

struct MSPTurnSteerTerminalTurn: Hashable, Sendable {
    var turnID: String
    var status: MSPTurnSteerTurnStatus
}

struct MSPTurnSteerAcceptance {
    var acceptedInput: MSPTurnSteerAcceptedInput
    var eventHandler: MSPAgentConversation.EventHandler
}

struct MSPTurnSteerPendingInputDrain {
    var items: [MSPAgentJSONValue]
    var appliedEvents: [MSPTurnSteerAppliedEvent]
    var eventHandler: MSPAgentConversation.EventHandler?
}
