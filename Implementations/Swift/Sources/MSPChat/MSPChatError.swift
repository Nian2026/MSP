import Foundation

public enum MSPChatError: Error, Equatable, LocalizedError {
    case packageNotDirectory(String)
    case missingManifest(String)
    case missingTimeline(String)
    case invalidJSON(String)
    case invalidManifest(String)
    case invalidTimelineEvent(String)
    case invalidAppendState(String)
    case unsafeTimelinePath(String)
    case packageAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case let .packageNotDirectory(path):
            return "Package path is not an existing .chat directory: \(path)"
        case let .missingManifest(path):
            return "manifest.json is missing: \(path)"
        case let .missingTimeline(path):
            return "timeline.ndjson is missing: \(path)"
        case let .invalidJSON(message):
            return "Invalid JSON: \(message)"
        case let .invalidManifest(message):
            return "Invalid manifest: \(message)"
        case let .invalidTimelineEvent(message):
            return "Invalid timeline event: \(message)"
        case let .invalidAppendState(message):
            return "Invalid append state: \(message)"
        case let .unsafeTimelinePath(path):
            return "Unsafe timeline path: \(path)"
        case let .packageAlreadyExists(path):
            return "Package already exists: \(path)"
        }
    }
}
