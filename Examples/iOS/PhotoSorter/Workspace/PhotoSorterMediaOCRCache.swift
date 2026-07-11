import Foundation

final class PhotoSorterMediaOCRCache: @unchecked Sendable {
    static let configurationVersion = 1

    enum CacheError: LocalizedError {
        case unreadable(URL)
        case unsupportedSchema(Int, URL)

        var errorDescription: String? {
            switch self {
            case let .unreadable(url):
                return "OCR cache could not be decoded and was preserved at \(url.path)"
            case let .unsupportedSchema(version, url):
                return "OCR cache schema \(version) is unsupported and was preserved at \(url.path)"
            }
        }
    }

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
        var contentFingerprint: String?
    }

    struct Lookup: Equatable {
        var text: String
        var contentFingerprint: String?
        var requiresContentValidation: Bool
    }

    private static let schemaVersion = 3
    private static let supportedLegacySchemaVersions: Set<Int> = [1, 2]
    private static let deferredPersistBatchSize = 25
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var loadedEntries: [String: Entry]?
    private var dirtyEntryCount = 0
    private var mutationGeneration: UInt64 = 0
    private var loadError: Error?
    private var didCreateSessionBackup = false

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
        lookup(
            localIdentifier: localIdentifier,
            assetVersion: assetVersion
        )?.text
    }

    func lookup(localIdentifier: String, assetVersion: String) -> Lookup? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let entries = loadEntriesLocked()
        let canonicalVersion = Self.canonicalAssetVersion(assetVersion)
        guard let entry = entries[localIdentifier],
              Self.canonicalAssetVersion(entry.assetVersion) == canonicalVersion,
              entry.configurationVersion == Self.configurationVersion
        else {
            return nil
        }
        return Lookup(
            text: entry.text,
            contentFingerprint: entry.contentFingerprint,
            requiresContentValidation: entry.contentFingerprint != nil
                && entry.assetVersion != assetVersion
        )
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
            let canonicalVersion = Self.canonicalAssetVersion(request.assetVersion)
            guard let entry = entries[request.localIdentifier],
                  Self.canonicalAssetVersion(entry.assetVersion) == canonicalVersion,
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
            let canonicalVersion = Self.canonicalAssetVersion(request.assetVersion)
            guard let entry = entries[request.localIdentifier],
                  Self.canonicalAssetVersion(entry.assetVersion) == canonicalVersion,
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
        contentFingerprint: String? = nil,
        persistImmediately: Bool = true
    ) throws -> (insertedValidEntry: Bool, generation: UInt64) {
        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        try ensureWritableLocked()
        let canonicalVersion = Self.canonicalAssetVersion(assetVersion)
        let previous = entries[localIdentifier]
        let hadValidEntry = previous.map {
            Self.canonicalAssetVersion($0.assetVersion) == canonicalVersion
        } == true
            && previous?.configurationVersion == Self.configurationVersion
        entries[localIdentifier] = Entry(
            localIdentifier: localIdentifier,
            assetVersion: assetVersion,
            configurationVersion: Self.configurationVersion,
            text: text,
            updatedAt: Date(),
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
        localIdentifier: String,
        assetVersion: String,
        expectedContentFingerprint: String?
    ) throws -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        var entries = loadEntriesLocked()
        try ensureWritableLocked()
        guard let entry = entries[localIdentifier],
              Self.canonicalAssetVersion(entry.assetVersion)
                == Self.canonicalAssetVersion(assetVersion),
              entry.contentFingerprint == expectedContentFingerprint else {
            return false
        }
        entries.removeValue(forKey: localIdentifier)
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

        let entries = cacheFile.entries
        let migrated = cacheFile.schemaVersion != Self.schemaVersion
        loadedEntries = entries
        if migrated {
            do {
                try persistLocked(entries)
                dirtyEntryCount = 0
            } catch {
                // Keep serving the successfully decoded legacy entries, but
                // prevent later writes from replacing the original cache if
                // its backup/migration could not be completed safely.
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

    private static func canonicalAssetVersion(_ assetVersion: String) -> String {
        guard assetVersion.hasPrefix("modified:"),
              let stableSuffixRange = assetVersion.range(of: "|size:")
        else {
            return assetVersion
        }
        return String(assetVersion[stableSuffixRange.lowerBound...].dropFirst())
    }
}
