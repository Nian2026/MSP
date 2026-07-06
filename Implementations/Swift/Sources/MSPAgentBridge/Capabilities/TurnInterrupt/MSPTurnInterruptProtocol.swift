import Foundation

public protocol MSPTurnInterruptProtocol: AnyObject {
    func interruptTurn(
        _ request: MSPTurnInterruptRequest
    ) async throws -> MSPTurnInterruptResponse

    func interruptActiveTurn()
        async throws -> MSPTurnInterruptHandle?

    func currentTurnInterruptTarget() async -> MSPTurnInterruptActiveTurn?

    func turnInterruptCapabilityDeclaration()
        async -> MSPTurnInterruptCapabilityDeclaration
}

public struct MSPTurnInterruptRequest: Hashable, Sendable {
    public var threadID: String
    public var turnID: String

    public init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct MSPTurnInterruptResponse: Hashable, Sendable {
    public var threadID: String
    public var turnID: String?
    public var reason: MSPTurnInterruptAbortReason
    public var terminalEvent: MSPTurnInterruptTurnAbortedEvent?

    public init(
        threadID: String,
        turnID: String?,
        reason: MSPTurnInterruptAbortReason,
        terminalEvent: MSPTurnInterruptTurnAbortedEvent?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.reason = reason
        self.terminalEvent = terminalEvent
    }
}

public struct MSPTurnInterruptHandle: Sendable {
    public var target: MSPTurnInterruptActiveTurn
    public var requestedAt: Date
    private let terminalResponseTask: Task<MSPTurnInterruptResponse, Error>

    public init(
        target: MSPTurnInterruptActiveTurn,
        requestedAt: Date,
        terminalResponseTask: Task<MSPTurnInterruptResponse, Error>
    ) {
        self.target = target
        self.requestedAt = requestedAt
        self.terminalResponseTask = terminalResponseTask
    }

    public func terminalResponse() async throws -> MSPTurnInterruptResponse {
        try await terminalResponseTask.value
    }
}
