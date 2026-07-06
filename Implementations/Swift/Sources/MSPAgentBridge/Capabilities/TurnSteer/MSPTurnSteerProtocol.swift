import Foundation

public protocol MSPTurnSteerProtocol: AnyObject {
    func steerTurn(
        _ request: MSPTurnSteerRequest
    ) async throws -> MSPTurnSteerResponse

    func steerActiveTurn(
        _ input: MSPTurnSteerInput
    ) async throws -> MSPTurnSteerHandle

    func currentTurnSteerTarget() async -> MSPTurnSteerActiveTurn?

    func turnSteerCapabilityDeclaration()
        async -> MSPTurnSteerCapabilityDeclaration
}

public extension MSPTurnSteerProtocol {
    func steerActiveTurn(
        _ text: String,
        clientUserMessageID: String? = nil
    ) async throws -> MSPTurnSteerHandle {
        try await steerActiveTurn(MSPTurnSteerInput(
            text: text,
            clientUserMessageID: clientUserMessageID
        ))
    }
}

public struct MSPTurnSteerRequest: Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var input: MSPTurnSteerInput

    public init(
        threadID: String,
        turnID: String,
        input: MSPTurnSteerInput
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.input = input
    }
}

public struct MSPTurnSteerInput: Hashable, Sendable {
    public var content: [MSPTurnSteerContent]
    public var clientUserMessageID: String?
    public var additionalContextItems: [MSPAgentJSONValue]

    public init(
        content: [MSPTurnSteerContent],
        clientUserMessageID: String? = nil,
        additionalContextItems: [MSPAgentJSONValue] = []
    ) {
        self.content = content
        self.clientUserMessageID = clientUserMessageID
        self.additionalContextItems = additionalContextItems
    }

    public init(
        text: String,
        clientUserMessageID: String? = nil,
        additionalContextItems: [MSPAgentJSONValue] = []
    ) {
        self.init(
            content: [.text(text)],
            clientUserMessageID: clientUserMessageID,
            additionalContextItems: additionalContextItems
        )
    }

    public var text: String {
        content.map(\.text).joined(separator: "\n")
    }

    var hasUserInput: Bool {
        content.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public enum MSPTurnSteerContent: Hashable, Sendable {
    case text(String)

    public var text: String {
        switch self {
        case .text(let value):
            return value
        }
    }
}

public struct MSPTurnSteerResponse: Hashable, Sendable {
    public var target: MSPTurnSteerActiveTurn
    public var sequenceNumber: Int
    public var content: MSPTurnSteerInput
    public var requestedAt: Date
    public var acceptedAt: Date
    public var appliedAt: Date?

    public init(
        target: MSPTurnSteerActiveTurn,
        sequenceNumber: Int,
        content: MSPTurnSteerInput,
        requestedAt: Date,
        acceptedAt: Date,
        appliedAt: Date? = nil
    ) {
        self.target = target
        self.sequenceNumber = sequenceNumber
        self.content = content
        self.requestedAt = requestedAt
        self.acceptedAt = acceptedAt
        self.appliedAt = appliedAt
    }
}

public struct MSPTurnSteerHandle: Sendable {
    public var response: MSPTurnSteerResponse
    private let appliedEventTask: Task<MSPTurnSteerAppliedEvent, Error>

    public init(
        response: MSPTurnSteerResponse,
        appliedEventTask: Task<MSPTurnSteerAppliedEvent, Error>
    ) {
        self.response = response
        self.appliedEventTask = appliedEventTask
    }

    public var target: MSPTurnSteerActiveTurn {
        response.target
    }

    public var requestedAt: Date {
        response.requestedAt
    }

    public var acceptedAt: Date {
        response.acceptedAt
    }

    public var sequenceNumber: Int {
        response.sequenceNumber
    }

    public func appliedEvent() async throws -> MSPTurnSteerAppliedEvent {
        try await appliedEventTask.value
    }
}
