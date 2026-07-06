import Foundation

final class PhotoSorterMediaPlaceCache: @unchecked Sendable {
    static let configurationVersion = 1

    private struct CacheFile: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        var localIdentifier: String
        var locationVersion: String
        var configurationVersion: Int
        var place: String
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
        fileURL: URL = PhotoSorterMediaPlaceCache.defaultFileURL(),
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
            .appendingPathComponent("photo-library-place-cache.json")
    }

    func place(localIdentifier: String, locationVersion: String) -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        guard let entry = entries[localIdentifier],
              entry.locationVersion == locationVersion,
              entry.configurationVersion == Self.configurationVersion
        else {
            return nil
        }
        return entry.place
    }

    func containsValidEntry(localIdentifier: String, locationVersion: String) -> Bool {
        place(localIdentifier: localIdentifier, locationVersion: locationVersion) != nil
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
        for requests: [PhotoSorterMediaPlaceCacheRequest]
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
                  entry.locationVersion == request.locationVersion,
                  entry.configurationVersion == Self.configurationVersion
            else {
                return count
            }
            return count + 1
        }
        return (validCount, mutationGeneration)
    }

    @discardableResult
    func store(
        place: String,
        localIdentifier: String,
        locationVersion: String,
        persistImmediately: Bool = true
    ) throws -> (insertedValidEntry: Bool, generation: UInt64) {
        let normalizedPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPlace.isEmpty else {
            return (false, generation)
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        let previous = entries[localIdentifier]
        let hadValidEntry = previous?.locationVersion == locationVersion
            && previous?.configurationVersion == Self.configurationVersion
        entries[localIdentifier] = Entry(
            localIdentifier: localIdentifier,
            locationVersion: locationVersion,
            configurationVersion: Self.configurationVersion,
            place: normalizedPlace,
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
