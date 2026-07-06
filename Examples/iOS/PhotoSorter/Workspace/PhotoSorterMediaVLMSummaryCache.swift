import Foundation

final class PhotoSorterMediaVLMSummaryCache: @unchecked Sendable {
    static let configurationVersion = 2

    private struct CacheFile: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        var summary: String
    }

    private static let schemaVersion = 1
    private static let deferredPersistBatchSize = 10
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var loadedEntries: [String: Entry]?
    private var dirtyEntryCount = 0
    private var mutationGeneration: UInt64 = 0

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
        lock.lock()
        defer {
            lock.unlock()
        }
        return loadEntriesLocked()[key.storageKey]?.summary
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
        let storageKey = key.storageKey
        let hadValidEntry = entries[storageKey] != nil
        entries[storageKey] = Entry(summary: normalizedSummary)
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
        try persistLocked(loadEntriesLocked())
        dirtyEntryCount = 0
    }

    private func loadEntriesLocked() -> [String: Entry] {
        if let loadedEntries {
            return loadedEntries
        }
        guard let data = try? Data(contentsOf: fileURL),
              let cacheFile = try? JSONDecoder().decode(CacheFile.self, from: data),
              cacheFile.schemaVersion == Self.schemaVersion
        else {
            loadedEntries = [:]
            return [:]
        }
        loadedEntries = cacheFile.entries
        return cacheFile.entries
    }

    private func persistLocked(_ entries: [String: Entry]) throws {
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
}
