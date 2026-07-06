import Foundation

public enum MSPTurnInterruptTurnStatus: String, Hashable, Sendable {
    case running
    case interrupting
    case completed
    case interrupted
    case failed
}

public struct MSPTurnInterruptActiveTurn: Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var status: MSPTurnInterruptTurnStatus
    public var startedAt: Date

    public init(
        threadID: String,
        turnID: String,
        status: MSPTurnInterruptTurnStatus,
        startedAt: Date
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.startedAt = startedAt
    }
}

enum MSPTurnInterruptTurnKind: Hashable, Sendable {
    case user
    case planning
    case maintenance
}

struct MSPTurnInterruptRuntimeTurn {
    var id: UUID
    var threadID: String
    var kind: MSPTurnInterruptTurnKind
    var status: MSPTurnInterruptTurnStatus
    var task: Task<MSPAgentRunResult, Error>?
    var transcriptRecorder: MSPAgentTurnTranscriptRecorder?
    var fallbackTranscriptItems: [MSPAgentJSONValue]
    var eventHandler: MSPAgentConversation.EventHandler
    var startedAt: Date

    var activeSnapshot: MSPTurnInterruptActiveTurn {
        MSPTurnInterruptActiveTurn(
            threadID: threadID,
            turnID: id.uuidString,
            status: status,
            startedAt: startedAt
        )
    }
}

struct MSPTurnInterruptTerminalTurn: Hashable, Sendable {
    var turnID: String
    var status: MSPTurnInterruptTurnStatus
    var reason: MSPTurnInterruptAbortReason?
}

struct MSPTurnInterruptCommit {
    var turn: MSPTurnInterruptRuntimeTurn
    var requestedTurnID: String
    var completedAt: Date
    var recordsInterruptedTranscript: Bool

    var turnID: String {
        turn.id.uuidString
    }
}

enum MSPTurnInterruptBeginResult {
    case startupAck(MSPTurnInterruptResponse)
    case perform(MSPTurnInterruptCommit)
    case waitForPending(turnID: String)
}
