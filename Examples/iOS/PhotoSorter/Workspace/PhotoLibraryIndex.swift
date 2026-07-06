import Foundation
import Photos

enum PhotoLibraryIndexPhase: String, Codable, Sendable, Equatable {
    case idle
    case loadingPersisted
    case validating
    case building
    case refreshing
    case rebuilding
    case ready
    case dirty
    case failed
}

struct PhotoLibraryIndexStatus: Codable, Sendable, Equatable {
    var phase: PhotoLibraryIndexPhase
    var processed: Int
    var total: Int?
    var currentPath: String?
    var version: Int
    var message: String?
    var updatedAt: Date

    var progressFraction: Double? {
        guard let total, total > 0 else {
            return nil
        }
        return min(max(Double(processed) / Double(total), 0), 1)
    }

    static let idle = PhotoLibraryIndexStatus(
        phase: .idle,
        processed: 0,
        total: nil,
        currentPath: nil,
        version: 0,
        message: nil,
        updatedAt: Date()
    )
}

struct PhotoLibraryIndexBuildProgress: Sendable, Equatable {
    var phase: PhotoLibraryIndexPhase
    var processed: Int
    var total: Int?
    var currentPath: String?
    var message: String?
}

struct PhotoLibraryIndexDirectory: Codable, Sendable, Equatable {
    var name: String
    var path: String
    var parentPath: String?
    var collectionLocalIdentifier: String?
    var childDirectoryPaths: [String]
    var assetLocalIdentifiers: [String]
    var manifestFingerprint: String?
    var directFileCount: Int
    var recursiveFileCount: Int
    var hasSubdirectories: Bool
}

struct PhotoLibraryIndexAsset: Codable, Sendable, Equatable {
    var localIdentifier: String
    var fileName: String
    var fileExtension: String
    var mediaTypeRawValue: Int
    var mediaSubtypesRawValue: UInt
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date?
    var locationLatitude: Double? = nil
    var locationLongitude: Double? = nil
    var locationHorizontalAccuracy: Double? = nil

    func mountedAsset(in mountPath: String) -> PhotoLibraryMount.MountedAsset {
        let name = PhotoLibraryMount.sanitizedPathComponent(fileName)
        return PhotoLibraryMount.MountedAsset(
            name: name,
            virtualPath: PhotoLibraryMount.join(mountPath, name),
            localIdentifier: localIdentifier,
            mediaType: PHAssetMediaType(rawValue: mediaTypeRawValue) ?? .unknown,
            mediaSubtypes: PHAssetMediaSubtype(rawValue: mediaSubtypesRawValue),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            creationDate: creationDate,
            modificationDate: modificationDate,
            locationLatitude: locationLatitude,
            locationLongitude: locationLongitude,
            locationHorizontalAccuracy: locationHorizontalAccuracy
        )
    }
}

struct PhotoLibraryIndexSnapshot: Codable, Sendable, Equatable {
    static let schemaVersion = 6

    static var indexShapeFingerprint: String {
        PhotoLibraryMount.photoLibraryIndexShapeFingerprint
    }

    var schemaVersion: Int
    var indexShapeFingerprint: String
    var builtAt: Date
    var authorizationStatusRawValue: Int
    var libraryScopeFingerprint: String
    var version: Int
    var directories: [String: PhotoLibraryIndexDirectory]
    var assetsByLocalIdentifier: [String: PhotoLibraryIndexAsset]
    var assetLocalIdentifierByVirtualPath: [String: String]
    var photoLibraryChangeTokenData: Data?

    var indexedAssetMembershipCount: Int {
        directories.values.reduce(0) { total, directory in
            total + directory.assetLocalIdentifiers.count
        }
    }

    var userAlbums: [PhotoLibraryMount.MountedAlbum] {
        let userRoot = PhotoLibraryMount.userAlbumRootPath
        guard let userDirectory = directories[userRoot] else {
            return []
        }
        return userDirectory.childDirectoryPaths.compactMap { path in
            guard let directory = directories[path],
                  let collectionLocalIdentifier = directory.collectionLocalIdentifier
            else {
                return nil
            }
            return PhotoLibraryMount.MountedAlbum(
                name: directory.name,
                virtualPath: directory.path,
                localIdentifier: collectionLocalIdentifier
            )
        }
    }

    func directoryExists(_ path: String) -> Bool {
        directories[PhotoLibraryMount.normalizeVirtualPath(path)] != nil
    }

    func assets(in path: String, offset: Int = 0, limit: Int? = nil) -> [PhotoLibraryMount.MountedAsset] {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        guard let directory = directories[normalized] else {
            return []
        }

        let identifiers = directory.assetLocalIdentifiers
        let startIndex = min(max(offset, 0), identifiers.count)
        let endIndex = limit.map { min(startIndex + max($0, 0), identifiers.count) } ?? identifiers.count
        guard startIndex < endIndex else {
            return []
        }

        return identifiers[startIndex..<endIndex].compactMap { identifier in
            assetsByLocalIdentifier[identifier]?.mountedAsset(in: normalized)
        }
    }

    func asset(at path: String) -> PhotoLibraryMount.MountedAsset? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        guard let localIdentifier = assetLocalIdentifierByVirtualPath[normalized],
              let parentPath = PhotoLibraryMount.parentPath(of: normalized),
              let asset = assetsByLocalIdentifier[localIdentifier]
        else {
            return nil
        }
        return asset.mountedAsset(in: parentPath)
    }

    static func make(
        authorizationStatusRawValue: Int,
        libraryScopeFingerprint: String? = nil,
        version: Int,
        directories: [String: PhotoLibraryIndexDirectory],
        assetsByLocalIdentifier: [String: PhotoLibraryIndexAsset],
        photoLibraryChangeTokenData: Data? = nil
    ) -> PhotoLibraryIndexSnapshot {
        var directories = directories
        for path in Array(directories.keys) {
            guard var directory = directories[path] else {
                continue
            }
            directory.directFileCount = directory.assetLocalIdentifiers.count
            directory.hasSubdirectories = !directory.childDirectoryPaths.isEmpty
            directory.manifestFingerprint = manifestFingerprint(for: directory)
            directories[path] = directory
        }
        let recursiveCounts = Array(directories.keys).map { path in
            (
                path,
                recursiveFileCount(
                path: path,
                directories: directories
                )
            )
        }
        for (path, count) in recursiveCounts {
            guard var directory = directories[path] else {
                continue
            }
            directory.recursiveFileCount = count
            directories[path] = directory
        }

        var reverseLookup: [String: String] = [:]
        for directory in directories.values {
            for localIdentifier in directory.assetLocalIdentifiers {
                guard let asset = assetsByLocalIdentifier[localIdentifier] else {
                    continue
                }
                let virtualPath = PhotoLibraryMount.join(directory.path, asset.fileName)
                reverseLookup[virtualPath] = localIdentifier
            }
        }

        return PhotoLibraryIndexSnapshot(
            schemaVersion: schemaVersion,
            indexShapeFingerprint: indexShapeFingerprint,
            builtAt: Date(),
            authorizationStatusRawValue: authorizationStatusRawValue,
            libraryScopeFingerprint: libraryScopeFingerprint ?? "authorization:\(authorizationStatusRawValue)",
            version: version,
            directories: directories,
            assetsByLocalIdentifier: assetsByLocalIdentifier,
            assetLocalIdentifierByVirtualPath: reverseLookup,
            photoLibraryChangeTokenData: photoLibraryChangeTokenData
        )
    }

    private static func recursiveFileCount(
        path: String,
        directories: [String: PhotoLibraryIndexDirectory]
    ) -> Int {
        guard let directory = directories[path] else {
            return 0
        }
        return directory.directFileCount + directory.childDirectoryPaths.reduce(0) { total, childPath in
            total + recursiveFileCount(path: childPath, directories: directories)
        }
    }

    private static func manifestFingerprint(for directory: PhotoLibraryIndexDirectory) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func append(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }

        append(directory.path)
        append(directory.name)
        append(directory.parentPath ?? "")
        append(directory.collectionLocalIdentifier ?? "")
        for childPath in directory.childDirectoryPaths {
            append(childPath)
        }
        for localIdentifier in directory.assetLocalIdentifiers {
            append(localIdentifier)
        }
        return String(format: "%016llx", hash)
    }
}

enum PhotoLibraryIndexUpdateMode: String, Codable, Sendable, Equatable {
    case verifiedCacheHit
    case persistentChangeTokenVerified
    case liveScan
    case incrementalRefresh
    case fullRebuild
}

struct PhotoLibraryIndexBuildOutcome: Sendable, Equatable {
    var snapshot: PhotoLibraryIndexSnapshot
    var mode: PhotoLibraryIndexUpdateMode
    var diagnostics: [String: String]

    init(
        snapshot: PhotoLibraryIndexSnapshot,
        mode: PhotoLibraryIndexUpdateMode,
        diagnostics: [String: String] = [:]
    ) {
        self.snapshot = snapshot
        self.mode = mode
        self.diagnostics = diagnostics
    }
}

final class PhotoLibraryIndexPersistentStore: @unchecked Sendable {
    private struct ChangeTokenFile: Codable {
        var schemaVersion: Int
        var indexSchemaVersion: Int
        var indexShapeFingerprint: String
        var tokenData: Data?
        var updatedAt: Date
    }

    private static let changeTokenSchemaVersion = 1
    private let fileURL: URL
    private let changeTokenFileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = PhotoLibraryIndexPersistentStore.defaultFileURL(),
        changeTokenFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.changeTokenFileURL = changeTokenFileURL
            ?? PhotoLibraryIndexPersistentStore.defaultChangeTokenFileURL(for: fileURL)
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseURL
            .appendingPathComponent("PhotoSorter", isDirectory: true)
            .appendingPathComponent("photo-library-index.json")
    }

    static func defaultChangeTokenFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseURL
            .appendingPathComponent("PhotoSorter", isDirectory: true)
            .appendingPathComponent("photo-library-change-token.json")
    }

    private static func defaultChangeTokenFileURL(for fileURL: URL) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("photo-library-change-token.json")
    }

    func load() -> PhotoLibraryIndexSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              var snapshot = try? JSONDecoder().decode(PhotoLibraryIndexSnapshot.self, from: data),
              snapshot.schemaVersion == PhotoLibraryIndexSnapshot.schemaVersion,
              snapshot.indexShapeFingerprint == PhotoLibraryIndexSnapshot.indexShapeFingerprint
        else {
            return nil
        }
        if let tokenFile = loadChangeTokenFile(),
           tokenFile.indexSchemaVersion == snapshot.schemaVersion,
           tokenFile.indexShapeFingerprint == snapshot.indexShapeFingerprint {
            snapshot.photoLibraryChangeTokenData = tokenFile.tokenData
        }
        return snapshot
    }

    func save(_ snapshot: PhotoLibraryIndexSnapshot) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try saveChangeToken(
            snapshot.photoLibraryChangeTokenData,
            indexSchemaVersion: snapshot.schemaVersion,
            indexShapeFingerprint: snapshot.indexShapeFingerprint
        )
    }

    func saveChangeToken(for snapshot: PhotoLibraryIndexSnapshot) throws {
        try saveChangeToken(
            snapshot.photoLibraryChangeTokenData,
            indexSchemaVersion: snapshot.schemaVersion,
            indexShapeFingerprint: snapshot.indexShapeFingerprint
        )
    }

    private func saveChangeToken(
        _ tokenData: Data?,
        indexSchemaVersion: Int,
        indexShapeFingerprint: String
    ) throws {
        try fileManager.createDirectory(
            at: changeTokenFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let tokenFile = ChangeTokenFile(
            schemaVersion: Self.changeTokenSchemaVersion,
            indexSchemaVersion: indexSchemaVersion,
            indexShapeFingerprint: indexShapeFingerprint,
            tokenData: tokenData,
            updatedAt: Date()
        )
        let data = try encoder.encode(tokenFile)
        try data.write(to: changeTokenFileURL, options: [.atomic])
    }

    private func loadChangeTokenFile() -> ChangeTokenFile? {
        guard let data = try? Data(contentsOf: changeTokenFileURL),
              let tokenFile = try? JSONDecoder().decode(ChangeTokenFile.self, from: data),
              tokenFile.schemaVersion == Self.changeTokenSchemaVersion
        else {
            return nil
        }
        return tokenFile
    }
}

final class PhotoLibraryIndex: @unchecked Sendable {
    typealias BuildSnapshot = (
        _ previousSnapshot: PhotoLibraryIndexSnapshot?,
        _ progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void
    ) throws -> PhotoLibraryIndexBuildOutcome

    private let condition = NSCondition()
    private let store: PhotoLibraryIndexPersistentStore?
    private var snapshot: PhotoLibraryIndexSnapshot?
    private var requiresValidation: Bool
    private var isRefreshing = false
    private var invalidationGeneration = 0
    private var nextVersion: Int
    private var lastError: Error?
    private var status: PhotoLibraryIndexStatus

    init(store: PhotoLibraryIndexPersistentStore? = PhotoLibraryIndexPersistentStore()) {
        self.store = store
        if let persisted = store?.load() {
            self.snapshot = persisted
            self.requiresValidation = true
            self.nextVersion = persisted.version + 1
            self.status = PhotoLibraryIndexStatus(
                phase: .loadingPersisted,
                processed: 0,
                total: persisted.indexedAssetMembershipCount,
                currentPath: nil,
                version: persisted.version,
                message: "校验照片库索引",
                updatedAt: Date()
            )
        } else {
            self.snapshot = nil
            self.requiresValidation = true
            self.nextVersion = 1
            self.status = PhotoLibraryIndexStatus(
                phase: .dirty,
                processed: 0,
                total: nil,
                currentPath: nil,
                version: 0,
                message: "照片库索引待建立",
                updatedAt: Date()
            )
        }
    }

    var currentStatus: PhotoLibraryIndexStatus {
        condition.lock()
        defer {
            condition.unlock()
        }
        return status
    }

    func cachedSnapshotForStatus() -> PhotoLibraryIndexSnapshot? {
        condition.lock()
        defer {
            condition.unlock()
        }
        return snapshot
    }

    func trustedSnapshot() -> PhotoLibraryIndexSnapshot? {
        condition.lock()
        defer {
            condition.unlock()
        }
        guard status.phase == .ready, !requiresValidation, !isRefreshing else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    func applyResolvedChangeNotificationSnapshot(
        _ resolvedSnapshot: PhotoLibraryIndexSnapshot,
        previousVersion: Int,
        mode: PhotoLibraryIndexUpdateMode
    ) -> Bool {
        let snapshotToSave: PhotoLibraryIndexSnapshot
        condition.lock()
        guard let currentSnapshot = snapshot,
              currentSnapshot.version == previousVersion,
              !isRefreshing
        else {
            condition.unlock()
            return false
        }

        var freshSnapshot = resolvedSnapshot
        if mode == .persistentChangeTokenVerified {
            freshSnapshot.version = currentSnapshot.version
            snapshot = freshSnapshot
            condition.broadcast()
            condition.unlock()
            try? store?.saveChangeToken(for: freshSnapshot)
            return true
        }

        freshSnapshot.version = nextVersion
        nextVersion += 1
        snapshot = freshSnapshot
        requiresValidation = false
        lastError = nil
        status = PhotoLibraryIndexStatus(
            phase: .ready,
            processed: freshSnapshot.indexedAssetMembershipCount,
            total: freshSnapshot.indexedAssetMembershipCount,
            currentPath: nil,
            version: freshSnapshot.version,
            message: readyMessage(for: mode),
            updatedAt: Date()
        )
        snapshotToSave = freshSnapshot
        condition.broadcast()
        condition.unlock()
        try? store?.save(snapshotToSave)
        return true
    }

    func markDirty(reason: String) {
        condition.lock()
        invalidationGeneration += 1
        requiresValidation = true
        status = PhotoLibraryIndexStatus(
            phase: .dirty,
            processed: 0,
            total: snapshot?.indexedAssetMembershipCount,
            currentPath: nil,
            version: status.version,
            message: reason,
            updatedAt: Date()
        )
        condition.broadcast()
        condition.unlock()
    }

    func snapshot(reason: String, build: BuildSnapshot) throws -> PhotoLibraryIndexSnapshot {
        condition.lock()
        if let snapshot, !requiresValidation, !isRefreshing {
            condition.unlock()
            return snapshot
        }
        while isRefreshing {
            condition.wait()
            if let snapshot, !requiresValidation {
                condition.unlock()
                return snapshot
            }
        }
        isRefreshing = true
        lastError = nil
        let version = nextVersion
        nextVersion += 1
        let refreshGeneration = invalidationGeneration
        status = PhotoLibraryIndexStatus(
            phase: phaseForNextRefresh(),
            processed: 0,
            total: snapshot?.indexedAssetMembershipCount,
            currentPath: nil,
            version: version,
            message: reason,
            updatedAt: Date()
        )
        condition.broadcast()
        condition.unlock()

        return try finishRefresh(
            version: version,
            refreshGeneration: refreshGeneration,
            build: build
        )
    }

    func refreshInBackground(reason: String, build: @escaping BuildSnapshot) {
        condition.lock()
        guard !isRefreshing else {
            condition.unlock()
            return
        }
        requiresValidation = true
        isRefreshing = true
        lastError = nil
        let version = nextVersion
        nextVersion += 1
        let refreshGeneration = invalidationGeneration
        status = PhotoLibraryIndexStatus(
            phase: phaseForNextRefresh(),
            processed: 0,
            total: snapshot?.indexedAssetMembershipCount,
            currentPath: nil,
            version: version,
            message: reason,
            updatedAt: Date()
        )
        condition.broadcast()
        condition.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            _ = try? self.finishRefresh(
                version: version,
                refreshGeneration: refreshGeneration,
                build: build
            )
        }
    }

    @discardableResult
    private func finishRefresh(
        version: Int,
        refreshGeneration: Int,
        build: BuildSnapshot
    ) throws -> PhotoLibraryIndexSnapshot {
        let previousSnapshot = snapshot
        do {
            let outcome = try build(previousSnapshot) { [weak self] progress in
                self?.update(progress: progress, version: version)
            }
            var freshSnapshot = outcome.snapshot
            freshSnapshot.version = version
            let becameDirtyDuringRefresh: Bool = {
                condition.lock()
                defer {
                    condition.unlock()
                }
                return invalidationGeneration != refreshGeneration
            }()
            if !becameDirtyDuringRefresh {
                try store?.save(freshSnapshot)
            }
            condition.lock()
            snapshot = freshSnapshot
            requiresValidation = becameDirtyDuringRefresh
            isRefreshing = false
            lastError = nil
            status = PhotoLibraryIndexStatus(
                phase: becameDirtyDuringRefresh ? .dirty : .ready,
                processed: freshSnapshot.indexedAssetMembershipCount,
                total: freshSnapshot.indexedAssetMembershipCount,
                currentPath: nil,
                version: freshSnapshot.version,
                message: becameDirtyDuringRefresh
                    ? "照片库在刷新期间再次变化"
                    : readyMessage(for: outcome.mode),
                updatedAt: Date()
            )
            condition.broadcast()
            condition.unlock()
            return freshSnapshot
        } catch {
            condition.lock()
            isRefreshing = false
            requiresValidation = true
            lastError = error
            status = PhotoLibraryIndexStatus(
                phase: .failed,
                processed: status.processed,
                total: status.total,
                currentPath: status.currentPath,
                version: version,
                message: error.localizedDescription,
                updatedAt: Date()
            )
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    private func update(progress: PhotoLibraryIndexBuildProgress, version: Int) {
        condition.lock()
        status = PhotoLibraryIndexStatus(
            phase: progress.phase,
            processed: progress.processed,
            total: progress.total,
            currentPath: progress.currentPath,
            version: version,
            message: progress.message,
            updatedAt: Date()
        )
        condition.broadcast()
        condition.unlock()
    }

    private func phaseForNextRefresh() -> PhotoLibraryIndexPhase {
        guard snapshot != nil else {
            return .building
        }
        switch status.phase {
        case .loadingPersisted, .validating:
            return .validating
        case .dirty, .failed:
            return .refreshing
        default:
            return .rebuilding
        }
    }

    private func readyMessage(for mode: PhotoLibraryIndexUpdateMode) -> String {
        switch mode {
        case .verifiedCacheHit:
            return "照片库缓存已校验"
        case .persistentChangeTokenVerified:
            return "照片库缓存已通过系统变更记录校验"
        case .liveScan:
            return "照片库索引已从真源建立"
        case .incrementalRefresh:
            return "照片库索引已增量刷新"
        case .fullRebuild:
            return "照片库索引已重建"
        }
    }
}
