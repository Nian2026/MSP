import Foundation

final class PhotoSorterMediaVLMSummaryCache: @unchecked Sendable {
    static let configurationVersion = 2

    enum CacheError: LocalizedError {
        case unreadable(URL)
        case unsupportedSchema(Int, URL)

        var errorDescription: String? {
            switch self {
            case let .unreadable(url):
                return "VLM summary cache could not be decoded and was preserved at \(url.path)"
            case let .unsupportedSchema(version, url):
                return "VLM summary cache schema \(version) is unsupported and was preserved at \(url.path)"
            }
        }
    }

    private struct CacheFile: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        var summary: String
        var updatedAt: Date?
        var assetVersion: String?
        var contentFingerprint: String?
    }

    struct Lookup: Equatable {
        var summary: String
        var contentFingerprint: String?
        var requiresContentValidation: Bool
    }

    private static let schemaVersion = 3
    private static let supportedLegacySchemaVersions: Set<Int> = [1, 2]
    private static let deferredPersistBatchSize = 10
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var loadedEntries: [String: Entry]?
    private var dirtyEntryCount = 0
    private var mutationGeneration: UInt64 = 0
    private var loadError: Error?
    private var didCreateSessionBackup = false

    init(
        fileURL: URL = PhotoSorterMediaVLMSummaryCache.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseURL
            .appendingPathComponent("PhotoSorter", isDirectory: true)
            .appendingPathComponent("photo-library-vlm-summary-cache.json")
    }

    func summary(for key: PhotoSorterMediaVLMSummaryCacheKey) -> String? {
        lookup(for: key)?.summary
    }

    func lookup(for key: PhotoSorterMediaVLMSummaryCacheKey) -> Lookup? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard let entry = loadEntriesLocked()[key.storageKey] else {
            return nil
        }
        return Lookup(
            summary: entry.summary,
            contentFingerprint: entry.contentFingerprint,
            requiresContentValidation: entry.contentFingerprint != nil
                && entry.assetVersion != nil
                && entry.assetVersion != key.assetVersion
        )
    }

    var generation: UInt64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        _ = loadEntriesLocked()
        return mutationGeneration
    }

    func validEntryCount(
        for keys: [PhotoSorterMediaVLMSummaryCacheKey]
    ) -> (validCount: Int, generation: UInt64) {
        guard !keys.isEmpty else {
            return (0, generation)
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        let validCount = keys.reduce(0) { count, key in
            entries[key.storageKey] == nil ? count : count + 1
        }
        return (validCount, mutationGeneration)
    }

    func containsValidEntry(for key: PhotoSorterMediaVLMSummaryCacheKey) -> Bool {
        summary(for: key) != nil
    }

    @discardableResult
    func store(
        summary: String,
        for key: PhotoSorterMediaVLMSummaryCacheKey,
        contentFingerprint: String? = nil,
        persistImmediately: Bool = true
    ) throws -> (insertedValidEntry: Bool, generation: UInt64) {
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else {
            return (false, generation)
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        try ensureWritableLocked()
        let storageKey = key.storageKey
        let hadValidEntry = entries[storageKey] != nil
        entries[storageKey] = Entry(
            summary: normalizedSummary,
            updatedAt: Date(),
            assetVersion: key.assetVersion,
            contentFingerprint: contentFingerprint
        )
        loadedEntries = entries
        mutationGeneration &+= 1
        dirtyEntryCount += 1
        if persistImmediately || dirtyEntryCount >= Self.deferredPersistBatchSize {
            try persistLocked(entries)
            dirtyEntryCount = 0
        }
        return (!hadValidEntry, mutationGeneration)
    }

    func flush() throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard dirtyEntryCount > 0 else {
            return
        }
        try ensureWritableLocked()
        try persistLocked(loadEntriesLocked())
        dirtyEntryCount = 0
    }

    @discardableResult
    func remove(
        for key: PhotoSorterMediaVLMSummaryCacheKey,
        expectedContentFingerprint: String?
    ) throws -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        try ensureWritableLocked()
        guard let entry = entries[key.storageKey],
              entry.contentFingerprint == expectedContentFingerprint else {
            return false
        }
        entries.removeValue(forKey: key.storageKey)
        loadedEntries = entries
        mutationGeneration &+= 1
        dirtyEntryCount += 1
        try persistLocked(entries)
        dirtyEntryCount = 0
        return true
    }

    private func loadEntriesLocked() -> [String: Entry] {
        if let loadedEntries {
            return loadedEntries
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            loadedEntries = [:]
            return [:]
        }
        guard let data = try? Data(contentsOf: fileURL),
              let cacheFile = try? JSONDecoder().decode(CacheFile.self, from: data)
        else {
            loadError = CacheError.unreadable(fileURL)
            loadedEntries = [:]
            return [:]
        }
        guard cacheFile.schemaVersion == Self.schemaVersion
                || Self.supportedLegacySchemaVersions.contains(cacheFile.schemaVersion)
        else {
            loadError = CacheError.unsupportedSchema(cacheFile.schemaVersion, fileURL)
            loadedEntries = [:]
            return [:]
        }

        var entries: [String: Entry] = [:]
        var selectedRanks: [String: Double] = [:]
        var migrated = cacheFile.schemaVersion != Self.schemaVersion
        entries.reserveCapacity(cacheFile.entries.count)
        for (storageKey, entry) in cacheFile.entries {
            let canonicalKey = PhotoSorterMediaVLMSummaryCacheKey.canonicalizedStorageKey(storageKey)
            let rank = PhotoSorterMediaVLMSummaryCacheKey.modificationDateRank(in: storageKey)
                ?? entry.updatedAt?.timeIntervalSinceReferenceDate
                ?? .greatestFiniteMagnitude
            if let selectedRank = selectedRanks[canonicalKey], selectedRank > rank {
                migrated = true
                continue
            }
            if entries[canonicalKey] != nil || canonicalKey != storageKey {
                migrated = true
            }
            var migratedEntry = entry
            if migratedEntry.assetVersion == nil {
                migratedEntry.assetVersion = PhotoSorterMediaVLMSummaryCacheKey
                    .assetVersion(in: storageKey)
            }
            entries[canonicalKey] = migratedEntry
            selectedRanks[canonicalKey] = rank
        }
        loadedEntries = entries
        if migrated {
            do {
                try persistLocked(entries)
                dirtyEntryCount = 0
            } catch {
                // Reads remain available from memory, while subsequent writes
                // are blocked so a failed migration can never erase the source.
                loadError = error
                dirtyEntryCount = max(dirtyEntryCount, 1)
            }
        }
        return entries
    }

    private func persistLocked(_ entries: [String: Entry]) throws {
        try createSessionBackupIfNeededLocked()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cacheFile = CacheFile(
            schemaVersion: Self.schemaVersion,
            entries: entries
        )
        try encoder.encode(cacheFile).write(to: fileURL, options: [.atomic])
    }

    private func ensureWritableLocked() throws {
        if let loadError {
            throw loadError
        }
    }

    private func createSessionBackupIfNeededLocked() throws {
        guard !didCreateSessionBackup else {
            return
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            didCreateSessionBackup = true
            return
        }
        let backupURL = fileURL.appendingPathExtension("bak")
        if fileManager.fileExists(atPath: backupURL.path) {
            didCreateSessionBackup = true
            return
        }
        try fileManager.copyItem(at: fileURL, to: backupURL)
        didCreateSessionBackup = true
    }
}
