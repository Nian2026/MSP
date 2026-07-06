import Foundation
import MSPAgentBridge

public enum MSPAgentChatStoreError: Error, Equatable, LocalizedError {
    case missingAgentTranscriptItem(String)
    case invalidAgentTranscriptPayload(String)
    case nonFiniteNumber(Double)

    public var errorDescription: String? {
        switch self {
        case .missingAgentTranscriptItem(let eventID):
            return "Timeline event \(eventID) is missing its agent transcript item."
        case .invalidAgentTranscriptPayload(let eventID):
            return "Timeline event \(eventID) has an invalid agent transcript payload."
        case .nonFiniteNumber(let value):
            return "Agent JSON number is not finite: \(value)."
        }
    }
}

public enum MSPAgentChatSnapshotReason: String, Sendable {
    case initial
    case compacted
    case replaced
    case restored
}

public struct MSPAgentChatOpenResult: Sendable {
    public var session: MSPAgentChatSession
    public var modelVisibleHistory: [MSPAgentJSONValue]
    public var latestApplicationStateSnapshot: MSPAgentJSONValue?

    public init(
        session: MSPAgentChatSession,
        modelVisibleHistory: [MSPAgentJSONValue],
        latestApplicationStateSnapshot: MSPAgentJSONValue?
    ) {
        self.session = session
        self.modelVisibleHistory = modelVisibleHistory
        self.latestApplicationStateSnapshot = latestApplicationStateSnapshot
    }
}
