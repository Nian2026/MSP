import Foundation
import MSPAgentBridge

public enum MSPAgentChatStoreError: Error, Equatable, LocalizedError {
    case missingAgentTranscriptItem(String)
    case invalidAgentTranscriptPayload(String)
    case nonFiniteNumber(Double)
    case missingPackageID
    case chatIDMismatch(expected: String, actual: String)
    case invalidTitle
    case titleRevisionOverflow

    public var errorDescription: String? {
        switch self {
        case .missingAgentTranscriptItem(let eventID):
            return "Timeline event \(eventID) is missing its agent transcript item."
        case .invalidAgentTranscriptPayload(let eventID):
            return "Timeline event \(eventID) has an invalid agent transcript payload."
        case .nonFiniteNumber(let value):
            return "Agent JSON number is not finite: \(value)."
        case .missingPackageID:
            return "The .chat manifest is missing package_id, so title metadata cannot be addressed by chat ID."
        case let .chatIDMismatch(expected, actual):
            return "Title metadata targets chat \(actual), but this session owns chat \(expected)."
        case .invalidTitle:
            return "Chat titles must contain non-whitespace text."
        case .titleRevisionOverflow:
            return "The chat title revision can no longer be advanced."
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
