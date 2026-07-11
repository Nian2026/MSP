import Foundation

public enum MSPChatNamingError: Error, Equatable, Sendable {
    case generationTimedOut
    case emptyGeneratedTitle
    case emptyManualTitle
    case manualTitleWriteConflict
}

extension MSPChatNamingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .generationTimedOut:
            return "Chat title generation timed out."
        case .emptyGeneratedTitle:
            return "The title generator returned an empty title."
        case .emptyManualTitle:
            return "A manual chat title cannot be empty."
        case .manualTitleWriteConflict:
            return "The Chat title changed repeatedly while applying the manual rename."
        }
    }
}
