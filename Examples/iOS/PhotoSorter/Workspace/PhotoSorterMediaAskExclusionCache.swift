import Foundation

final class PhotoSorterMediaAskExclusionCache: @unchecked Sendable {
    private struct CacheFile: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Equatable {
        var count: Int
        var updatedAt: Date
    }

    private static let schemaVersion = 1
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var loadedEntries: [String: Entry]?

    init(
        fileURL: URL = PhotoSorterMediaAskExclusionCache.defaultFileURL(),
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
            .appendingPathComponent("photo-library-media-ask-exclusions.json")
    }

    func count(localIdentifier: String) -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return max(loadEntriesLocked()[localIdentifier]?.count ?? 0, 0)
    }

    func counts(localIdentifiers: [String]) -> [Int] {
        guard !localIdentifiers.isEmpty else {
            return []
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        return localIdentifiers.map { max(entries[$0]?.count ?? 0, 0) }
    }

    func increment(localIdentifiers: [String]) throws {
        let identifiers = Self.uniqueNonEmptyIdentifiers(localIdentifiers)
        guard !identifiers.isEmpty else {
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        let now = Date()
        for identifier in identifiers {
            let previousCount = max(entries[identifier]?.count ?? 0, 0)
            entries[identifier] = Entry(count: previousCount + 1, updatedAt: now)
        }
        loadedEntries = entries
        try persistLocked(entries)
    }

    private static func uniqueNonEmptyIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in identifiers {
            let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
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
