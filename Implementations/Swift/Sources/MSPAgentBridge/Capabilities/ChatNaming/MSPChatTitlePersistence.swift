import Foundation

public enum MSPChatTitleWriteCondition: Hashable, Sendable {
    case always
    case onlyIfUntitled
    case ifRevision(String?)
}

public enum MSPChatTitleSource: String, Codable, Hashable, Sendable {
    case model
    case fallback
    case manual
    case inherited
}

public struct MSPChatTitleRecord: Hashable, Sendable {
    public var chatID: String
    public var title: String
    public var searchDescription: String?
    public var source: MSPChatTitleSource
    public var updatedAt: Date

    public init(
        chatID: String,
        title: String,
        searchDescription: String? = nil,
        source: MSPChatTitleSource,
        updatedAt: Date
    ) {
        self.chatID = chatID
        self.title = title
        self.searchDescription = searchDescription
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct MSPChatTitleMetadata: Hashable, Sendable {
    public var record: MSPChatTitleRecord?

    /// An opaque persistence revision. Stores choose its representation and
    /// must change it after every successful metadata write.
    public var revision: String?

    public init(record: MSPChatTitleRecord?, revision: String?) {
        self.record = record
        self.revision = revision
    }

    public static func untitled(revision: String? = nil) -> MSPChatTitleMetadata {
        MSPChatTitleMetadata(record: nil, revision: revision)
    }

    public var title: String? {
        record?.title
    }

    public var searchDescription: String? {
        record?.searchDescription
    }

    public var isUntitled: Bool {
        guard let title else {
            return true
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum MSPChatTitleWriteDisposition: String, Codable, Hashable, Sendable {
    case updated
    case notUpdated = "not_updated"
}

public struct MSPChatTitleWriteResult: Hashable, Sendable {
    public var disposition: MSPChatTitleWriteDisposition
    public var metadata: MSPChatTitleMetadata

    public init(
        disposition: MSPChatTitleWriteDisposition,
        metadata: MSPChatTitleMetadata
    ) {
        self.disposition = disposition
        self.metadata = metadata
    }

    public var didUpdate: Bool {
        disposition == .updated
    }
}

public protocol MSPChatTitlePersisting: Sendable {
    func titleMetadata(for chatID: String) async throws -> MSPChatTitleMetadata

    /// The condition must be checked atomically with the write inside the
    /// persistence implementation's supported writer domain. In particular,
    /// `.onlyIfUntitled` is the final compare-and-set that prevents a delayed
    /// model result from replacing a manual title.
    func writeTitle(
        _ record: MSPChatTitleRecord,
        condition: MSPChatTitleWriteCondition
    ) async throws -> MSPChatTitleWriteResult
}
