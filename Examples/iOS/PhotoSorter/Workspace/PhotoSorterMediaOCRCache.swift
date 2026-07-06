import Foundation

final class PhotoSorterMediaOCRCache: @unchecked Sendable {
    static let configurationVersion = 1

    private struct CacheFile: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        var localIdentifier: String
        var assetVersion: String
        var configurationVersion: Int
        var text: String
        var updatedAt: Date
    }

    private static let schemaVersion = 1
    private static let deferredPersistBatchSize = 25
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var loadedEntries: [String: Entry]?
    private var dirtyEntryCount = 0
    private var mutationGeneration: UInt64 = 0

    init(
        fileURL: URL = PhotoSorterMediaOCRCache.defaultFileURL(),
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
            .appendingPathComponent("photo-library-ocr-cache.json")
    }

    func text(localIdentifier: String, assetVersion: String) -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        guard let entry = entries[localIdentifier],
              entry.assetVersion == assetVersion,
              entry.configurationVersion == Self.configurationVersion
        else {
            return nil
        }
        return entry.text
    }

    func texts(for requests: [PhotoSorterMediaOCRCacheRequest]) -> [String?] {
        guard !requests.isEmpty else {
            return []
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        return requests.map { request in
            guard let entry = entries[request.localIdentifier],
                  entry.assetVersion == request.assetVersion,
                  entry.configurationVersion == Self.configurationVersion
            else {
                return nil
            }
            return entry.text
        }
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
        for requests: [PhotoSorterMediaOCRCacheRequest]
    ) -> (validCount: Int, generation: UInt64) {
        guard !requests.isEmpty else {
            return (0, generation)
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        let validCount = requests.reduce(0) { count, request in
            guard let entry = entries[request.localIdentifier],
                  entry.assetVersion == request.assetVersion,
                  entry.configurationVersion == Self.configurationVersion
            else {
                return count
            }
            return count + 1
        }
        return (validCount, mutationGeneration)
    }

    func containsValidEntry(localIdentifier: String, assetVersion: String) -> Bool {
        text(localIdentifier: localIdentifier, assetVersion: assetVersion) != nil
    }

    @discardableResult
    func store(
        text: String,
        localIdentifier: String,
        assetVersion: String,
        persistImmediately: Bool = true
    ) throws -> (insertedValidEntry: Bool, generation: UInt64) {
        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        let previous = entries[localIdentifier]
        let hadValidEntry = previous?.assetVersion == assetVersion
            && previous?.configurationVersion == Self.configurationVersion
        entries[localIdentifier] = Entry(
            localIdentifier: localIdentifier,
            assetVersion: assetVersion,
            configurationVersion: Self.configurationVersion,
            text: text,
            updatedAt: Date()
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
