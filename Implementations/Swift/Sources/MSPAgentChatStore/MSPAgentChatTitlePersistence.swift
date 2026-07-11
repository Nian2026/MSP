import Foundation
import MSPAgentBridge
import MSPChat

extension MSPAgentChatSession: MSPChatTitlePersisting {
    public func titleMetadata(for chatID: String) async throws -> MSPChatTitleMetadata {
        try titleMetadataForChat(chatID)
    }

    public func writeTitle(
        _ record: MSPChatTitleRecord,
        condition: MSPChatTitleWriteCondition
    ) async throws -> MSPChatTitleWriteResult {
        try setTitle(record, condition: condition)
    }
}

extension MSPAgentChatSession {
    /// Reads the current Chat title metadata without scanning or changing the timeline.
    public func titleMetadata() throws -> MSPChatTitleMetadata {
        try MSPChatCoreWriter.withPackageWriteLock(at: packageURL) {
            let manifest = try MSPChatCoreReader().readManifest(at: packageURL)
            guard let chatID = manifest.packageID else {
                throw MSPAgentChatStoreError.missingPackageID
            }
            return Self.titleMetadata(from: manifest, chatID: chatID)
        }
    }

    /// Updates display metadata in `manifest.json` under the package's
    /// process-local writer lock. This never renames the `.chat` package or
    /// appends a timeline event. Hosts must not concurrently write the same
    /// package from another process.
    @discardableResult
    public func setTitle(
        _ title: String,
        searchDescription: String? = nil,
        source: MSPChatTitleSource,
        condition: MSPChatTitleWriteCondition = .always,
        updatedAt: Date? = nil
    ) throws -> MSPChatTitleWriteResult {
        let manifest = try MSPChatCoreWriter.withPackageWriteLock(at: packageURL) {
            try MSPChatCoreReader().readManifest(at: packageURL)
        }
        guard let chatID = manifest.packageID else {
            throw MSPAgentChatStoreError.missingPackageID
        }
        return try setTitle(
            MSPChatTitleRecord(
                chatID: chatID,
                title: title,
                searchDescription: searchDescription,
                source: source,
                updatedAt: updatedAt ?? clock()
            ),
            condition: condition
        )
    }

    /// Applies the persistence condition and manifest write under one
    /// process-local package lock.
    @discardableResult
    public func setTitle(
        _ record: MSPChatTitleRecord,
        condition: MSPChatTitleWriteCondition = .always
    ) throws -> MSPChatTitleWriteResult {
        let normalizedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw MSPAgentChatStoreError.invalidTitle
        }
        let normalizedDescription = record.searchDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedDescription = normalizedDescription?.isEmpty == true ? nil : normalizedDescription
        var didUpdate = false

        let finalManifest = try MSPChatCoreWriter().updateManifest(at: packageURL) { manifest in
            try Self.validate(record.chatID, matches: manifest)
            let currentMetadata = Self.titleMetadata(from: manifest, chatID: record.chatID)
            guard Self.shouldWrite(condition, current: currentMetadata) else {
                return nil
            }

            let currentRevision = max(0, manifest.titleRevision ?? 0)
            guard currentRevision < Int.max else {
                throw MSPAgentChatStoreError.titleRevisionOverflow
            }
            let titleTimestamp = MSPAgentChatStore.timestamp(for: record.updatedAt)
            let packageTimestamp = Self.packageUpdatedAt(
                manifest: manifest,
                titleUpdatedAt: record.updatedAt
            )
            let updatedJSON = manifest.rawJSONWithTitle(
                normalizedTitle,
                searchDescription: storedDescription,
                revision: currentRevision + 1,
                titleUpdatedAt: titleTimestamp,
                source: record.source.rawValue,
                packageUpdatedAt: packageTimestamp
            )
            didUpdate = true
            return try MSPChatManifest(rawJSON: updatedJSON)
        }

        return MSPChatTitleWriteResult(
            disposition: didUpdate ? .updated : .notUpdated,
            metadata: Self.titleMetadata(from: finalManifest, chatID: record.chatID)
        )
    }

    private func titleMetadataForChat(_ chatID: String) throws -> MSPChatTitleMetadata {
        try MSPChatCoreWriter.withPackageWriteLock(at: packageURL) {
            let manifest = try MSPChatCoreReader().readManifest(at: packageURL)
            try Self.validate(chatID, matches: manifest)
            return Self.titleMetadata(from: manifest, chatID: chatID)
        }
    }

    private static func validate(_ chatID: String, matches manifest: MSPChatManifest) throws {
        guard let packageID = manifest.packageID else {
            throw MSPAgentChatStoreError.missingPackageID
        }
        if packageID != chatID {
            throw MSPAgentChatStoreError.chatIDMismatch(expected: packageID, actual: chatID)
        }
    }

    private static func shouldWrite(
        _ condition: MSPChatTitleWriteCondition,
        current: MSPChatTitleMetadata
    ) -> Bool {
        switch condition {
        case .always:
            return true
        case .onlyIfUntitled:
            return current.isUntitled
        case .ifRevision(let expectedRevision):
            return current.revision == expectedRevision
        }
    }

    private static func titleMetadata(
        from manifest: MSPChatManifest,
        chatID: String
    ) -> MSPChatTitleMetadata {
        let revision = manifest.titleRevision.map(String.init)
        guard let title = manifest.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return MSPChatTitleMetadata(record: nil, revision: revision)
        }

        let source = manifest.titleSource.flatMap(MSPChatTitleSource.init(rawValue:)) ?? .manual
        let updatedAt = date(from: manifest.titleUpdatedAt)
            ?? date(from: manifest.updatedAt)
            ?? date(from: manifest.createdAt)
            ?? Date(timeIntervalSince1970: 0)
        return MSPChatTitleMetadata(
            record: MSPChatTitleRecord(
                chatID: manifest.packageID ?? chatID,
                title: title,
                searchDescription: manifest.searchDescription,
                source: source,
                updatedAt: updatedAt
            ),
            revision: revision
        )
    }

    private static func packageUpdatedAt(
        manifest: MSPChatManifest,
        titleUpdatedAt: Date
    ) -> String {
        let current = date(from: manifest.updatedAt) ?? date(from: manifest.createdAt)
        return MSPAgentChatStore.timestamp(for: max(current ?? titleUpdatedAt, titleUpdatedAt))
    }

    private static func date(from timestamp: String?) -> Date? {
        guard let timestamp else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: timestamp)
    }
}
