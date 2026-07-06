import Foundation
import MSPCore
import Photos

struct PhotoLibraryWorkspaceChangeSummary: Sendable, Equatable {
    var trashedAssetCount: Int
    var deletedAlbumCount: Int
    var pendingAlbumCreationCount: Int
    var pendingAlbumMembershipAdditionCount: Int
    var pendingAlbumMembershipRemovalCount: Int
    var version: Int
    var updatedAt: Date?
    var isSyncing: Bool = false
    var errorMessage: String?

    static let idle = PhotoLibraryWorkspaceChangeSummary(
        trashedAssetCount: 0,
        deletedAlbumCount: 0,
        pendingAlbumCreationCount: 0,
        pendingAlbumMembershipAdditionCount: 0,
        pendingAlbumMembershipRemovalCount: 0,
        version: 0,
        updatedAt: nil
    )

    var hasChanges: Bool {
        trashedAssetCount > 0
            || deletedAlbumCount > 0
            || pendingAlbumCreationCount > 0
            || pendingAlbumMembershipAdditionCount > 0
            || pendingAlbumMembershipRemovalCount > 0
    }
}

struct PhotoLibraryWorkspaceSyncAlbumCreation: Sendable, Equatable {
    var name: String
    var virtualPath: String
}

struct PhotoLibraryWorkspaceSyncAlbumDeletion: Sendable, Equatable {
    var albumVirtualPath: String
    var albumLocalIdentifier: String?
}

struct PhotoLibraryWorkspaceSyncAlbumMembershipChange: Sendable, Equatable {
    var albumVirtualPath: String
    var albumLocalIdentifier: String?
    var assetLocalIdentifiers: [String]
}

struct PhotoLibraryWorkspaceSyncConflict: Identifiable, Sendable, Equatable {
    var id: String
    var message: String
}

struct PhotoLibraryWorkspaceSyncChangeSet: Sendable, Equatable {
    var trashedAssetLocalIdentifiers: [String]
    var createdAlbums: [PhotoLibraryWorkspaceSyncAlbumCreation]
    var deletedAlbums: [PhotoLibraryWorkspaceSyncAlbumDeletion]
    var membershipAdditions: [PhotoLibraryWorkspaceSyncAlbumMembershipChange]
    var membershipRemovals: [PhotoLibraryWorkspaceSyncAlbumMembershipChange]
    var conflicts: [PhotoLibraryWorkspaceSyncConflict]

    static let empty = PhotoLibraryWorkspaceSyncChangeSet(
        trashedAssetLocalIdentifiers: [],
        createdAlbums: [],
        deletedAlbums: [],
        membershipAdditions: [],
        membershipRemovals: [],
        conflicts: []
    )

    var isEmpty: Bool {
        trashedAssetLocalIdentifiers.isEmpty
            && createdAlbums.isEmpty
            && deletedAlbums.isEmpty
            && membershipAdditions.isEmpty
            && membershipRemovals.isEmpty
            && conflicts.isEmpty
    }

    var hasConflicts: Bool {
        !conflicts.isEmpty
    }
}

struct PhotoLibraryWorkspaceSyncConflictError: LocalizedError, Sendable {
    var conflicts: [PhotoLibraryWorkspaceSyncConflict]

    var errorDescription: String? {
        guard !conflicts.isEmpty else {
            return nil
        }
        return conflicts.map(\.message).joined(separator: "\n")
    }
}

struct PhotoLibraryWorkspaceAssetReference: Codable, Sendable, Equatable {
    var name: String
    var localIdentifier: String
    var mediaTypeRawValue: Int
    var mediaSubtypesRawValue: UInt
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date?
    var locationLatitude: Double?
    var locationLongitude: Double?
    var locationHorizontalAccuracy: Double?

    init(_ asset: PhotoLibraryMount.MountedAsset) {
        self.name = asset.name
        self.localIdentifier = asset.localIdentifier
        self.mediaTypeRawValue = asset.mediaType.rawValue
        self.mediaSubtypesRawValue = asset.mediaSubtypes.rawValue
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.creationDate = asset.creationDate
        self.modificationDate = asset.modificationDate
        self.locationLatitude = asset.locationLatitude
        self.locationLongitude = asset.locationLongitude
        self.locationHorizontalAccuracy = asset.locationHorizontalAccuracy
    }

    func mountedAsset(at virtualPath: String) -> PhotoLibraryMount.MountedAsset {
        PhotoLibraryMount.MountedAsset(
            name: PhotoLibraryMount.sanitizedPathComponent(name),
            virtualPath: PhotoLibraryMount.normalizeVirtualPath(virtualPath),
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

struct PhotoLibraryWorkspaceTrashedAsset: Codable, Sendable, Equatable {
    var record: MSPWorkspaceTrashRecord
    var assetReference: PhotoLibraryWorkspaceAssetReference
}

struct PhotoLibraryWorkspaceAlbumReference: Codable, Sendable, Equatable {
    var name: String
    var virtualPath: String
    var localIdentifier: String?

    init(_ album: PhotoLibraryMount.MountedAlbum) {
        self.name = album.name
        self.virtualPath = PhotoLibraryMount.normalizeVirtualPath(album.virtualPath)
        self.localIdentifier = album.localIdentifier.hasPrefix("pending:") ? nil : album.localIdentifier
    }

    func mountedAlbum() -> PhotoLibraryMount.MountedAlbum {
        PhotoLibraryMount.MountedAlbum(
            name: PhotoLibraryMount.sanitizedPathComponent(name),
            virtualPath: PhotoLibraryMount.normalizeVirtualPath(virtualPath),
            localIdentifier: localIdentifier ?? "pending:\(PhotoLibraryMount.normalizeVirtualPath(virtualPath))"
        )
    }
}

struct PhotoLibraryWorkspaceTrashedAlbum: Codable, Sendable, Equatable {
    var record: MSPWorkspaceTrashRecord
    var albumReference: PhotoLibraryWorkspaceAlbumReference
    var assetLocalIdentifiers: [String]
}

struct PhotoLibraryWorkspacePendingAlbum: Codable, Sendable, Equatable {
    var name: String
    var virtualPath: String
    var createdAt: Date

    var mountedAlbum: PhotoLibraryMount.MountedAlbum {
        PhotoLibraryMount.MountedAlbum(
            name: name,
            virtualPath: virtualPath,
            localIdentifier: "pending:\(virtualPath)"
        )
    }
}

struct PhotoLibraryWorkspaceOverlayIndex: Sendable, Equatable {
    var trashRecords: [MSPWorkspaceTrashRecord]
    var trashedAssetLocalIdentifiers: Set<String>
    var trashedAssetByDisplayPath: [String: PhotoLibraryWorkspaceTrashedAsset]
    var trashedAlbumByDisplayPath: [String: PhotoLibraryWorkspaceTrashedAlbum]
    var trashedAssetIDByLocalIdentifier: [String: String]
    var trashedAlbumIDByVirtualPath: [String: String]
    var trashDisplayPathByRecordID: [String: String]
    var deletedUserAlbumPaths: Set<String>
    var latestTrashModificationDate: Date?

    init(state: PhotoLibraryWorkspaceOverlayState) {
        var records: [MSPWorkspaceTrashRecord] = []
        records.reserveCapacity(state.trashedAssetsByID.count + state.trashedAlbumsByID.count)
        var trashedAssetLocalIdentifiers = Set<String>()
        trashedAssetLocalIdentifiers.reserveCapacity(state.trashedAssetsByID.count)
        var trashedAssetByDisplayPath: [String: PhotoLibraryWorkspaceTrashedAsset] = [:]
        trashedAssetByDisplayPath.reserveCapacity(state.trashedAssetsByID.count)
        var trashedAlbumByDisplayPath: [String: PhotoLibraryWorkspaceTrashedAlbum] = [:]
        trashedAlbumByDisplayPath.reserveCapacity(state.trashedAlbumsByID.count)
        var trashedAssetIDByLocalIdentifier: [String: String] = [:]
        trashedAssetIDByLocalIdentifier.reserveCapacity(state.trashedAssetsByID.count)
        var trashedAlbumIDByVirtualPath: [String: String] = [:]
        trashedAlbumIDByVirtualPath.reserveCapacity(state.trashedAlbumsByID.count)
        var trashDisplayPathByRecordID: [String: String] = [:]
        trashDisplayPathByRecordID.reserveCapacity(state.trashedAssetsByID.count + state.trashedAlbumsByID.count)
        var deletedUserAlbumPaths = Set(state.deletedUserAlbumsByPath.keys)
        var latestTrashModificationDate: Date?
        var usedDisplayNamesByParent: [String: Set<String>] = [:]

        func updateLatestDate(_ date: Date) {
            latestTrashModificationDate = max(latestTrashModificationDate ?? .distantPast, date)
        }

        func reserveDisplayName(_ rawName: String, in parentPath: String) -> String {
            var usedNames = usedDisplayNamesByParent[parentPath] ?? []
            let uniqueName = PhotoLibraryMount.uniqued(rawName, usedNames: &usedNames)
            usedDisplayNamesByParent[parentPath] = usedNames
            return uniqueName
        }

        func displayPathAtTrashRoot(for record: MSPWorkspaceTrashRecord) -> String {
            guard let displayRootPath = state.trashConfiguration.displayRootPath else {
                return record.originalPath
            }
            let displayName = reserveDisplayName(Self.trashDisplayName(for: record), in: displayRootPath)
            return PhotoLibraryMount.join(displayRootPath, displayName)
        }

        let sortedAlbums = state.trashedAlbumsByID.values.sorted {
            Self.trashRecordPrecedes($0.record, $1.record)
        }
        var albumDisplayPathByOriginalPath: [String: String] = [:]
        albumDisplayPathByOriginalPath.reserveCapacity(sortedAlbums.count)

        for trashedAlbum in sortedAlbums {
            records.append(trashedAlbum.record)
            let displayPath = displayPathAtTrashRoot(for: trashedAlbum.record)
            trashDisplayPathByRecordID[trashedAlbum.record.id] = displayPath
            trashedAlbumByDisplayPath[displayPath] = trashedAlbum
            albumDisplayPathByOriginalPath[trashedAlbum.albumReference.virtualPath] = displayPath
            trashedAlbumIDByVirtualPath[trashedAlbum.albumReference.virtualPath] = trashedAlbum.record.id
            deletedUserAlbumPaths.insert(trashedAlbum.albumReference.virtualPath)
            updateLatestDate(trashedAlbum.record.trashedAt)
        }

        let albumOriginalPathsByDescendingLength = albumDisplayPathByOriginalPath.keys.sorted {
            if $0.count == $1.count {
                return $0 < $1
            }
            return $0.count > $1.count
        }

        func containingAlbumDisplayPath(for originalPath: String) -> (originalPath: String, displayPath: String)? {
            for albumOriginalPath in albumOriginalPathsByDescendingLength
            where originalPath.hasPrefix(albumOriginalPath + "/") {
                return (albumOriginalPath, albumDisplayPathByOriginalPath[albumOriginalPath] ?? albumOriginalPath)
            }
            return nil
        }

        func displayPathInTrashedAlbum(
            for record: MSPWorkspaceTrashRecord,
            albumOriginalPath: String,
            albumDisplayPath: String
        ) -> String {
            let suffixStart = record.originalPath.index(
                record.originalPath.startIndex,
                offsetBy: min(albumOriginalPath.count + 1, record.originalPath.count)
            )
            let suffix = String(record.originalPath[suffixStart...])
            let components = suffix.split(separator: "/").map(String.init)
            guard let fileName = components.last else {
                return displayPathAtTrashRoot(for: record)
            }
            let parentPath = components.dropLast().reduce(albumDisplayPath) { parentPath, component in
                PhotoLibraryMount.join(parentPath, component)
            }
            let displayName = reserveDisplayName(fileName, in: parentPath)
            return PhotoLibraryMount.join(parentPath, displayName)
        }

        let sortedAssets = state.trashedAssetsByID.values.sorted {
            Self.trashRecordPrecedes($0.record, $1.record)
        }

        for trashedAsset in sortedAssets {
            records.append(trashedAsset.record)
            trashedAssetLocalIdentifiers.insert(trashedAsset.assetReference.localIdentifier)
            let displayPath: String
            if let containingAlbum = containingAlbumDisplayPath(for: trashedAsset.record.originalPath) {
                displayPath = displayPathInTrashedAlbum(
                    for: trashedAsset.record,
                    albumOriginalPath: containingAlbum.originalPath,
                    albumDisplayPath: containingAlbum.displayPath
                )
            } else {
                displayPath = displayPathAtTrashRoot(for: trashedAsset.record)
            }
            trashDisplayPathByRecordID[trashedAsset.record.id] = displayPath
            trashedAssetByDisplayPath[displayPath] = trashedAsset
            trashedAssetIDByLocalIdentifier[trashedAsset.assetReference.localIdentifier] = trashedAsset.record.id
            updateLatestDate(trashedAsset.record.trashedAt)
        }

        self.trashRecords = records.sorted { first, second in
            if first.trashedAt == second.trashedAt {
                return first.id < second.id
            }
            return first.trashedAt < second.trashedAt
        }
        self.trashedAssetLocalIdentifiers = trashedAssetLocalIdentifiers
        self.trashedAssetByDisplayPath = trashedAssetByDisplayPath
        self.trashedAlbumByDisplayPath = trashedAlbumByDisplayPath
        self.trashedAssetIDByLocalIdentifier = trashedAssetIDByLocalIdentifier
        self.trashedAlbumIDByVirtualPath = trashedAlbumIDByVirtualPath
        self.trashDisplayPathByRecordID = trashDisplayPathByRecordID
        self.deletedUserAlbumPaths = deletedUserAlbumPaths
        self.latestTrashModificationDate = latestTrashModificationDate
    }

    static func trashDisplayPath(
        for record: MSPWorkspaceTrashRecord,
        configuration: MSPWorkspaceTrashConfiguration
    ) -> String {
        guard let displayRootPath = configuration.displayRootPath else {
            return record.originalPath
        }
        return PhotoLibraryMount.join(displayRootPath, trashDisplayName(for: record))
    }

    private static func trashDisplayName(for record: MSPWorkspaceTrashRecord) -> String {
        let name = record.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        return record.originalPath.split(separator: "/").last.map(String.init) ?? record.id
    }

    private static func trashRecordPrecedes(
        _ first: MSPWorkspaceTrashRecord,
        _ second: MSPWorkspaceTrashRecord
    ) -> Bool {
        if first.trashedAt == second.trashedAt {
            return first.id < second.id
        }
        return first.trashedAt < second.trashedAt
    }

    mutating func insertTrashedAsset(
        _ trashedAsset: PhotoLibraryWorkspaceTrashedAsset,
        configuration: MSPWorkspaceTrashConfiguration
    ) {
        insertTrashRecord(trashedAsset.record)
        trashedAssetLocalIdentifiers.insert(trashedAsset.assetReference.localIdentifier)
        trashedAssetByDisplayPath[Self.trashDisplayPath(
            for: trashedAsset.record,
            configuration: configuration
        )] = trashedAsset
        trashedAssetIDByLocalIdentifier[trashedAsset.assetReference.localIdentifier] = trashedAsset.record.id
    }

    mutating func removeTrashedAsset(
        _ trashedAsset: PhotoLibraryWorkspaceTrashedAsset,
        configuration: MSPWorkspaceTrashConfiguration
    ) {
        removeTrashRecord(id: trashedAsset.record.id)
        trashedAssetLocalIdentifiers.remove(trashedAsset.assetReference.localIdentifier)
        trashedAssetByDisplayPath.removeValue(forKey: Self.trashDisplayPath(
            for: trashedAsset.record,
            configuration: configuration
        ))
        trashedAssetIDByLocalIdentifier.removeValue(forKey: trashedAsset.assetReference.localIdentifier)
    }

    private mutating func insertTrashRecord(_ record: MSPWorkspaceTrashRecord) {
        if let last = trashRecords.last,
           last.trashedAt > record.trashedAt {
            let insertionIndex = trashRecords.firstIndex {
                $0.trashedAt > record.trashedAt
                    || ($0.trashedAt == record.trashedAt && $0.id > record.id)
            } ?? trashRecords.endIndex
            trashRecords.insert(record, at: insertionIndex)
        } else {
            trashRecords.append(record)
        }
        latestTrashModificationDate = max(latestTrashModificationDate ?? .distantPast, record.trashedAt)
    }

    private mutating func removeTrashRecord(id: String) {
        trashRecords.removeAll { $0.id == id }
    }
}

struct PhotoLibraryWorkspaceOverlaySnapshot: Sendable, Equatable {
    fileprivate var state: PhotoLibraryWorkspaceOverlayState
    fileprivate var index: PhotoLibraryWorkspaceOverlayIndex

    init(state: PhotoLibraryWorkspaceOverlayState) {
        self.init(
            state: state,
            index: PhotoLibraryWorkspaceOverlayIndex(state: state)
        )
    }

    fileprivate init(
        state: PhotoLibraryWorkspaceOverlayState,
        index: PhotoLibraryWorkspaceOverlayIndex
    ) {
        self.state = state
        self.index = index
    }

    var trashConfiguration: MSPWorkspaceTrashConfiguration {
        state.trashConfiguration
    }

    var version: Int {
        state.version
    }

    var updatedAt: Date? {
        state.updatedAt
    }

    var summary: PhotoLibraryWorkspaceChangeSummary {
        PhotoLibraryWorkspaceChangeSummary(
            trashedAssetCount: state.trashedAssetsByID.count,
            deletedAlbumCount: state.trashedAlbumsByID.count + state.deletedUserAlbumsByPath.count,
            pendingAlbumCreationCount: state.pendingUserAlbumsByPath.count,
            pendingAlbumMembershipAdditionCount: state.membershipAdditionsByAlbumPath.values.reduce(0) {
                $0 + $1.count
            },
            pendingAlbumMembershipRemovalCount: state.membershipRemovalsByAlbumPath.values.reduce(0) {
                $0 + $1.count
            },
            version: state.version,
            updatedAt: state.updatedAt
        )
    }

    var trashRecords: [MSPWorkspaceTrashRecord] {
        index.trashRecords
    }

    var latestTrashModificationDate: Date? {
        index.latestTrashModificationDate
    }

    var pendingUserAlbums: [PhotoLibraryWorkspacePendingAlbum] {
        state.pendingUserAlbumsByPath.values.sorted { $0.virtualPath < $1.virtualPath }
    }

    var trashedAssetLocalIdentifiers: Set<String> {
        index.trashedAssetLocalIdentifiers
    }

    var trashedAssetCount: Int {
        state.trashedAssetsByID.count
    }

    func hasAssetChanges(in virtualDirectoryPath: String) -> Bool {
        let normalizedDirectory = PhotoLibraryMount.normalizeVirtualPath(virtualDirectoryPath)
        return !state.trashedAssetsByID.isEmpty
            || !(state.membershipRemovalsByAlbumPath[normalizedDirectory]?.isEmpty ?? true)
            || !(state.membershipAdditionsByAlbumPath[normalizedDirectory]?.isEmpty ?? true)
    }

    func effectiveAssetCount(
        in virtualDirectoryPath: String,
        baseAssetLocalIdentifiers: [String]
    ) -> Int {
        let normalizedDirectory = PhotoLibraryMount.normalizeVirtualPath(virtualDirectoryPath)
        let removals = state.membershipRemovalsByAlbumPath[normalizedDirectory] ?? []
        let additions = state.membershipAdditionsByAlbumPath[normalizedDirectory] ?? []
        guard !state.trashedAssetsByID.isEmpty || !removals.isEmpty || !additions.isEmpty else {
            return baseAssetLocalIdentifiers.count
        }

        let trashedIdentifiers = trashedAssetLocalIdentifiers
        let removedIdentifiers = Set(removals)
        var count = 0
        for identifier in baseAssetLocalIdentifiers
        where !trashedIdentifiers.contains(identifier) && !removedIdentifiers.contains(identifier) {
            count += 1
        }

        guard !additions.isEmpty else {
            return count
        }

        let baseIdentifiers = Set(baseAssetLocalIdentifiers)
        var seenAdditionIdentifiers = Set<String>()
        for identifier in additions
        where !trashedIdentifiers.contains(identifier)
            && !removedIdentifiers.contains(identifier)
            && !baseIdentifiers.contains(identifier)
            && seenAdditionIdentifiers.insert(identifier).inserted {
            count += 1
        }
        return count
    }


    var deletedUserAlbumReferences: [PhotoLibraryWorkspaceAlbumReference] {
        state.deletedUserAlbumsByPath.values.sorted { $0.virtualPath < $1.virtualPath }
    }

    var trashedAlbums: [PhotoLibraryWorkspaceTrashedAlbum] {
        state.trashedAlbumsByID.values.sorted { first, second in
            if first.record.trashedAt == second.record.trashedAt {
                return first.record.id < second.record.id
            }
            return first.record.trashedAt < second.record.trashedAt
        }
    }

    var deletedUserAlbumPaths: Set<String> {
        index.deletedUserAlbumPaths
    }

    func isTrashDisplayPath(_ path: String) -> Bool {
        guard let displayRootPath = trashConfiguration.displayRootPath else {
            return false
        }
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        return normalized == displayRootPath || normalized.hasPrefix(displayRootPath + "/")
    }

    func trashDisplayPath(for record: MSPWorkspaceTrashRecord) -> String {
        index.trashDisplayPathByRecordID[record.id] ?? PhotoLibraryWorkspaceOverlayIndex.trashDisplayPath(
            for: record,
            configuration: trashConfiguration
        )
    }

    func trashAsset(atDisplayPath path: String) -> PhotoLibraryWorkspaceTrashedAsset? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        return index.trashedAssetByDisplayPath[normalized]
    }

    func trashAlbum(atDisplayPath path: String) -> PhotoLibraryWorkspaceTrashedAlbum? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        return index.trashedAlbumByDisplayPath[normalized]
    }

    func trashRecord(containingDisplayPath path: String) -> PhotoLibraryWorkspaceTrashedAsset? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        return state.trashedAssetsByID.values
            .filter { trashedAsset in
                let displayPath = trashDisplayPath(for: trashedAsset.record)
                return normalized == displayPath
                    || (trashedAsset.record.isDirectory && normalized.hasPrefix(displayPath + "/"))
            }
            .sorted {
                trashDisplayPath(for: $0.record).count > trashDisplayPath(for: $1.record).count
            }
            .first
    }

    func assetReference(for localIdentifier: String) -> PhotoLibraryWorkspaceAssetReference? {
        state.assetReferencesByLocalIdentifier[localIdentifier]
    }

    func pendingUserAlbum(at path: String) -> PhotoLibraryWorkspacePendingAlbum? {
        state.pendingUserAlbumsByPath[PhotoLibraryMount.normalizeVirtualPath(path)]
    }

    func userAlbums(merging realAlbums: [PhotoLibraryMount.MountedAlbum]) -> [PhotoLibraryMount.MountedAlbum] {
        let deletedPaths = deletedUserAlbumPaths
        var albumsByPath = Dictionary(uniqueKeysWithValues: realAlbums
            .filter { !deletedPaths.contains($0.virtualPath) }
            .map { ($0.virtualPath, $0) })
        for pendingAlbum in pendingUserAlbums {
            guard !deletedPaths.contains(pendingAlbum.virtualPath) else {
                continue
            }
            albumsByPath[pendingAlbum.virtualPath] = pendingAlbum.mountedAlbum
        }
        return albumsByPath.values.sorted { $0.name < $1.name }
    }

    func containsUserAlbum(path: String, realAlbums: [PhotoLibraryMount.MountedAlbum]) -> Bool {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(path)
        guard !deletedUserAlbumPaths.contains(normalized) else {
            return false
        }
        return state.pendingUserAlbumsByPath[normalized] != nil
            || realAlbums.contains(where: { $0.virtualPath == normalized })
    }

    func effectiveAssets(
        in virtualDirectoryPath: String,
        baseAssets: [PhotoLibraryMount.MountedAsset],
        assetResolver: (String) -> PhotoLibraryMount.MountedAsset?
    ) -> [PhotoLibraryMount.MountedAsset] {
        let normalizedDirectory = PhotoLibraryMount.normalizeVirtualPath(virtualDirectoryPath)
        let trashedIdentifiers = trashedAssetLocalIdentifiers
        let removedIdentifiers = Set(state.membershipRemovalsByAlbumPath[normalizedDirectory] ?? [])
        var assetsByIdentifier: [String: PhotoLibraryMount.MountedAsset] = [:]
        var orderedIdentifiers: [String] = []

        for asset in baseAssets {
            guard !trashedIdentifiers.contains(asset.localIdentifier),
                  !removedIdentifiers.contains(asset.localIdentifier)
            else {
                continue
            }
            assetsByIdentifier[asset.localIdentifier] = asset
            orderedIdentifiers.append(asset.localIdentifier)
        }

        for identifier in state.membershipAdditionsByAlbumPath[normalizedDirectory] ?? [] {
            guard !trashedIdentifiers.contains(identifier),
                  assetsByIdentifier[identifier] == nil
            else {
                continue
            }
            let reference = state.assetReferencesByLocalIdentifier[identifier]
            let asset = reference?.mountedAsset(at: PhotoLibraryMount.join(normalizedDirectory, reference?.name ?? ""))
                ?? assetResolver(identifier).map {
                    renamedAsset($0, in: normalizedDirectory)
                }
            guard let asset else {
                continue
            }
            assetsByIdentifier[identifier] = asset
            orderedIdentifiers.append(identifier)
        }

        return orderedIdentifiers.compactMap { assetsByIdentifier[$0] }
    }

    func effectiveAssetsPage(
        in virtualDirectoryPath: String,
        baseAssetLocalIdentifiers: [String],
        offset: Int,
        limit: Int?,
        assetResolver: (String) -> PhotoLibraryMount.MountedAsset?
    ) -> [PhotoLibraryMount.MountedAsset] {
        let normalizedDirectory = PhotoLibraryMount.normalizeVirtualPath(virtualDirectoryPath)
        let safeOffset = max(offset, 0)
        let safeLimit = limit.map { max($0, 0) }
        if safeLimit == 0 {
            return []
        }

        let trashedIdentifiers = trashedAssetLocalIdentifiers
        let removedIdentifiers = Set(state.membershipRemovalsByAlbumPath[normalizedDirectory] ?? [])
        let additions = state.membershipAdditionsByAlbumPath[normalizedDirectory] ?? []
        var seenBaseIdentifiers = additions.isEmpty ? nil : Set<String>()
        var seenAdditionIdentifiers = Set<String>()
        var skipped = 0
        var page: [PhotoLibraryMount.MountedAsset] = []

        func appendIfInPage(_ asset: PhotoLibraryMount.MountedAsset) -> Bool {
            if skipped < safeOffset {
                skipped += 1
                return false
            }
            if let safeLimit, page.count >= safeLimit {
                return true
            }
            page.append(asset)
            return safeLimit.map { page.count >= $0 } ?? false
        }

        for identifier in baseAssetLocalIdentifiers {
            seenBaseIdentifiers?.insert(identifier)
            guard !trashedIdentifiers.contains(identifier),
                  !removedIdentifiers.contains(identifier),
                  let asset = assetResolver(identifier).map({
                    renamedAsset($0, in: normalizedDirectory)
                  })
            else {
                continue
            }
            if appendIfInPage(asset) {
                return page
            }
        }

        for identifier in additions {
            guard !trashedIdentifiers.contains(identifier),
                  seenAdditionIdentifiers.insert(identifier).inserted,
                  !(seenBaseIdentifiers?.contains(identifier) == true && !removedIdentifiers.contains(identifier))
            else {
                continue
            }
            let reference = state.assetReferencesByLocalIdentifier[identifier]
            let asset = reference?.mountedAsset(
                at: PhotoLibraryMount.join(normalizedDirectory, reference?.name ?? "")
            ) ?? assetResolver(identifier).map {
                renamedAsset($0, in: normalizedDirectory)
            }
            guard let asset else {
                continue
            }
            if appendIfInPage(asset) {
                return page
            }
        }

        return page
    }

    func effectiveAsset(
        at virtualPath: String,
        baseAsset: PhotoLibraryMount.MountedAsset?,
        assetResolver: (String) -> PhotoLibraryMount.MountedAsset?
    ) -> PhotoLibraryMount.MountedAsset? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(virtualPath)
        if let trashed = trashAsset(atDisplayPath: normalized) {
            return trashed.assetReference.mountedAsset(at: normalized)
        }

        if let baseAsset {
            let parentPath = PhotoLibraryMount.parentPath(of: normalized) ?? "/"
            let removedIdentifiers = Set(state.membershipRemovalsByAlbumPath[parentPath] ?? [])
            guard !trashedAssetLocalIdentifiers.contains(baseAsset.localIdentifier),
                  !removedIdentifiers.contains(baseAsset.localIdentifier)
            else {
                return nil
            }
            return baseAsset
        }

        guard let parentPath = PhotoLibraryMount.parentPath(of: normalized),
              let fileName = normalized.split(separator: "/").last.map(String.init),
              let identifiers = state.membershipAdditionsByAlbumPath[parentPath]
        else {
            return nil
        }

        for identifier in identifiers {
            guard !trashedAssetLocalIdentifiers.contains(identifier) else {
                continue
            }
            let reference = state.assetReferencesByLocalIdentifier[identifier]
            if reference?.name == fileName {
                return reference?.mountedAsset(at: normalized)
            }
            if let asset = assetResolver(identifier),
               asset.name == fileName {
                return renamedAsset(asset, at: normalized)
            }
        }
        return nil
    }

    func albumMembershipAdditionsByPath() -> [String: [String]] {
        state.membershipAdditionsByAlbumPath
    }

    func albumMembershipRemovalsByPath() -> [String: [String]] {
        state.membershipRemovalsByAlbumPath
    }

    private func renamedAsset(
        _ asset: PhotoLibraryMount.MountedAsset,
        in directoryPath: String
    ) -> PhotoLibraryMount.MountedAsset {
        renamedAsset(asset, at: PhotoLibraryMount.join(directoryPath, asset.name))
    }

    private func renamedAsset(
        _ asset: PhotoLibraryMount.MountedAsset,
        at virtualPath: String
    ) -> PhotoLibraryMount.MountedAsset {
        PhotoLibraryMount.MountedAsset(
            name: asset.name,
            virtualPath: PhotoLibraryMount.normalizeVirtualPath(virtualPath),
            localIdentifier: asset.localIdentifier,
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            locationLatitude: asset.locationLatitude,
            locationLongitude: asset.locationLongitude,
            locationHorizontalAccuracy: asset.locationHorizontalAccuracy
        )
    }
}

final class PhotoLibraryWorkspaceOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private let store: PhotoLibraryWorkspaceOverlayStore?
    private var state: PhotoLibraryWorkspaceOverlayState
    private var index: PhotoLibraryWorkspaceOverlayIndex

    init(store: PhotoLibraryWorkspaceOverlayStore? = PhotoLibraryWorkspaceOverlayStore()) {
        self.store = store
        let initialState = store?.load() ?? PhotoLibraryWorkspaceOverlayState()
        self.state = initialState
        self.index = PhotoLibraryWorkspaceOverlayIndex(state: initialState)
    }

    var snapshot: PhotoLibraryWorkspaceOverlaySnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }
        return PhotoLibraryWorkspaceOverlaySnapshot(state: state, index: index)
    }

    var summary: PhotoLibraryWorkspaceChangeSummary {
        snapshot.summary
    }

    @discardableResult
    func createUserAlbum(at virtualPath: String) throws -> PhotoLibraryWorkspacePendingAlbum {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(virtualPath)
        guard PhotoLibraryMount.parentPath(of: normalized) == PhotoLibraryMount.userAlbumRootPath,
              let name = normalized.split(separator: "/").last.map(String.init),
              !name.isEmpty
        else {
            throw MSPWorkspaceFileSystemError.accessDenied(normalized)
        }

        return try mutate { state in
            if let existing = state.pendingUserAlbumsByPath[normalized] {
                return existing
            }
            let album = PhotoLibraryWorkspacePendingAlbum(
                name: PhotoLibraryMount.sanitizedPathComponent(name),
                virtualPath: normalized,
                createdAt: Date()
            )
            state.pendingUserAlbumsByPath[normalized] = album
            return album
        }
    }

    @discardableResult
    func removePendingUserAlbum(at virtualPath: String) throws -> Bool {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(virtualPath)
        return try mutate { state in
            guard state.pendingUserAlbumsByPath.removeValue(forKey: normalized) != nil else {
                return false
            }
            state.membershipAdditionsByAlbumPath.removeValue(forKey: normalized)
            state.membershipRemovalsByAlbumPath.removeValue(forKey: normalized)
            return true
        }
    }

    func deleteUserAlbumContainer(_ album: PhotoLibraryMount.MountedAlbum) throws {
        let albumReference = PhotoLibraryWorkspaceAlbumReference(album)
        let normalized = albumReference.virtualPath
        try mutate { state, index in
            if state.pendingUserAlbumsByPath.removeValue(forKey: normalized) != nil {
                state.membershipAdditionsByAlbumPath.removeValue(forKey: normalized)
                state.membershipRemovalsByAlbumPath.removeValue(forKey: normalized)
                return
            }
            removeTrashedAlbum(
                at: normalized,
                existingRecordID: index.trashedAlbumIDByVirtualPath[normalized],
                from: &state
            )
            state.deletedUserAlbumsByPath[normalized] = albumReference
            state.membershipAdditionsByAlbumPath.removeValue(forKey: normalized)
            state.membershipRemovalsByAlbumPath.removeValue(forKey: normalized)
        }
    }

    @discardableResult
    func trashAsset(
        _ asset: PhotoLibraryMount.MountedAsset,
        originalPath: String
    ) throws -> MSPWorkspaceTrashRecord {
        let normalizedOriginalPath = PhotoLibraryMount.normalizeVirtualPath(originalPath)
        let assetReference = PhotoLibraryWorkspaceAssetReference(asset)
        return try mutateMaintainingIndex { state, index in
            let record = trashAssetRecord(
                assetReference,
                originalPath: normalizedOriginalPath,
                existingRecordID: index.trashedAssetIDByLocalIdentifier[assetReference.localIdentifier],
                in: &state
            )
            index = PhotoLibraryWorkspaceOverlayIndex(state: state)
            return record
        }
    }

    @discardableResult
    func trashAssets(
        _ assets: [(asset: PhotoLibraryMount.MountedAsset, originalPath: String)]
    ) throws -> [MSPWorkspaceTrashRecord] {
        let requests = assets.map { item in
            (
                assetReference: PhotoLibraryWorkspaceAssetReference(item.asset),
                originalPath: PhotoLibraryMount.normalizeVirtualPath(item.originalPath)
            )
        }
        guard !requests.isEmpty else {
            return []
        }

        return try mutateMaintainingIndex { state, index in
            var records: [MSPWorkspaceTrashRecord] = []
            records.reserveCapacity(requests.count)
            for request in requests {
                records.append(trashAssetRecord(
                    request.assetReference,
                    originalPath: request.originalPath,
                    existingRecordID: index.trashedAssetIDByLocalIdentifier[
                        request.assetReference.localIdentifier
                    ],
                    in: &state
                ))
            }
            index = PhotoLibraryWorkspaceOverlayIndex(state: state)
            return records
        }
    }

    @discardableResult
    func trashUserAlbum(
        _ album: PhotoLibraryMount.MountedAlbum,
        assets: [PhotoLibraryMount.MountedAsset]
    ) throws -> MSPWorkspaceTrashRecord {
        let albumReference = PhotoLibraryWorkspaceAlbumReference(album)
        let normalizedAlbumPath = albumReference.virtualPath
        return try mutate { state, index in
            state.pendingUserAlbumsByPath.removeValue(forKey: normalizedAlbumPath)
            state.deletedUserAlbumsByPath.removeValue(forKey: normalizedAlbumPath)
            removeTrashedAlbum(
                at: normalizedAlbumPath,
                existingRecordID: index.trashedAlbumIDByVirtualPath[normalizedAlbumPath],
                from: &state
            )
            state.membershipAdditionsByAlbumPath.removeValue(forKey: normalizedAlbumPath)
            state.membershipRemovalsByAlbumPath.removeValue(forKey: normalizedAlbumPath)

            let assetIdentifiers = assets.map(\.localIdentifier)
            for asset in assets {
                _ = trashAssetRecord(
                    PhotoLibraryWorkspaceAssetReference(asset),
                    originalPath: PhotoLibraryMount.join(normalizedAlbumPath, asset.name),
                    existingRecordID: index.trashedAssetIDByLocalIdentifier[asset.localIdentifier],
                    in: &state
                )
            }

            let id = UUID().uuidString
            let itemDirectoryPath = PhotoLibraryMount.join(
                PhotoLibraryMount.join(state.trashConfiguration.storageRootPath, "items"),
                id
            )
            let trashPath = PhotoLibraryMount.join(itemDirectoryPath, albumReference.name)
            let record = MSPWorkspaceTrashRecord(
                id: id,
                originalPath: normalizedAlbumPath,
                originalName: albumReference.name,
                trashPath: trashPath,
                isDirectory: true,
                trashedAt: Date()
            )
            state.trashedAlbumsByID[id] = PhotoLibraryWorkspaceTrashedAlbum(
                record: record,
                albumReference: albumReference,
                assetLocalIdentifiers: assetIdentifiers
            )
            return record
        }
    }

    func restoreTrash(
        displayPath: String,
        destinationPath: String? = nil
    ) throws -> MSPWorkspaceTrashRestoreSummary {
        let normalizedDisplayPath = PhotoLibraryMount.normalizeVirtualPath(displayPath)
        let normalizedDestinationPath = destinationPath.map(PhotoLibraryMount.normalizeVirtualPath)
        return try mutate { state in
            let snapshot = PhotoLibraryWorkspaceOverlaySnapshot(state: state)
            if let trashedAlbum = snapshot.trashAlbum(atDisplayPath: normalizedDisplayPath) {
                let restoredPath = normalizedDestinationPath ?? trashedAlbum.record.originalPath
                guard restoredPath == trashedAlbum.record.originalPath else {
                    throw MSPWorkspaceFileSystemError.accessDenied(restoredPath)
                }
                state.trashedAlbumsByID.removeValue(forKey: trashedAlbum.record.id)
                for identifier in trashedAlbum.assetLocalIdentifiers {
                    removeTrashedAsset(
                        localIdentifier: identifier,
                        existingRecordID: snapshot.index.trashedAssetIDByLocalIdentifier[identifier],
                        from: &state
                    )
                }
                if trashedAlbum.albumReference.localIdentifier == nil {
                    state.pendingUserAlbumsByPath[trashedAlbum.albumReference.virtualPath] = PhotoLibraryWorkspacePendingAlbum(
                        name: trashedAlbum.albumReference.name,
                        virtualPath: trashedAlbum.albumReference.virtualPath,
                        createdAt: Date()
                    )
                }
                return MSPWorkspaceTrashRestoreSummary(
                    originalPath: trashedAlbum.record.originalPath,
                    restoredPath: restoredPath,
                    originalName: trashedAlbum.record.originalName,
                    isDirectory: true
                )
            }

            guard let trashedAsset = snapshot.trashAsset(atDisplayPath: normalizedDisplayPath) else {
                throw MSPWorkspaceFileSystemError.notFound(normalizedDisplayPath)
            }
            state.trashedAssetsByID.removeValue(forKey: trashedAsset.record.id)

            if let normalizedDestinationPath,
               let destinationDirectory = PhotoLibraryMount.parentPath(of: normalizedDestinationPath),
               destinationDirectory.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/") {
                addMembership(
                    trashedAsset.assetReference.localIdentifier,
                    toAlbumPath: destinationDirectory,
                    assetReference: trashedAsset.assetReference,
                    in: &state
                )
            }

            return MSPWorkspaceTrashRestoreSummary(
                originalPath: trashedAsset.record.originalPath,
                restoredPath: normalizedDestinationPath ?? trashedAsset.record.originalPath,
                originalName: trashedAsset.record.originalName,
                isDirectory: false
            )
        }
    }

    func addAsset(
        _ asset: PhotoLibraryMount.MountedAsset,
        toAlbumPath albumPath: String
    ) throws {
        let normalizedAlbumPath = PhotoLibraryMount.normalizeVirtualPath(albumPath)
        try mutate { state in
            addMembership(
                asset.localIdentifier,
                toAlbumPath: normalizedAlbumPath,
                assetReference: PhotoLibraryWorkspaceAssetReference(asset),
                in: &state
            )
        }
    }

    func addAssets(
        _ assets: [PhotoLibraryMount.MountedAsset],
        toAlbumPath albumPath: String
    ) throws {
        let normalizedAlbumPath = PhotoLibraryMount.normalizeVirtualPath(albumPath)
        guard !assets.isEmpty else {
            return
        }
        try mutate { state in
            for asset in assets {
                addMembership(
                    asset.localIdentifier,
                    toAlbumPath: normalizedAlbumPath,
                    assetReference: PhotoLibraryWorkspaceAssetReference(asset),
                    in: &state
                )
            }
        }
    }

    func removeAsset(
        _ asset: PhotoLibraryMount.MountedAsset,
        fromAlbumPath albumPath: String
    ) throws {
        let normalizedAlbumPath = PhotoLibraryMount.normalizeVirtualPath(albumPath)
        try mutate { state in
            let identifier = asset.localIdentifier
            state.assetReferencesByLocalIdentifier[identifier] = PhotoLibraryWorkspaceAssetReference(asset)
            let hadPendingAddition = state.membershipAdditionsByAlbumPath[normalizedAlbumPath]?.contains(identifier) == true
            removeIdentifier(identifier, from: &state.membershipAdditionsByAlbumPath[normalizedAlbumPath])
            guard !hadPendingAddition else {
                return
            }
            appendIdentifier(identifier, to: &state.membershipRemovalsByAlbumPath[normalizedAlbumPath])
        }
    }

    func removeAssets(
        _ assets: [PhotoLibraryMount.MountedAsset],
        fromAlbumPath albumPath: String
    ) throws {
        let normalizedAlbumPath = PhotoLibraryMount.normalizeVirtualPath(albumPath)
        guard !assets.isEmpty else {
            return
        }
        try mutate { state in
            for asset in assets {
                let identifier = asset.localIdentifier
                state.assetReferencesByLocalIdentifier[identifier] = PhotoLibraryWorkspaceAssetReference(asset)
                let hadPendingAddition = state.membershipAdditionsByAlbumPath[normalizedAlbumPath]?.contains(identifier) == true
                removeIdentifier(identifier, from: &state.membershipAdditionsByAlbumPath[normalizedAlbumPath])
                guard !hadPendingAddition else {
                    continue
                }
                appendIdentifier(identifier, to: &state.membershipRemovalsByAlbumPath[normalizedAlbumPath])
            }
        }
    }

    func clear() throws {
        try mutate { state in
            state = PhotoLibraryWorkspaceOverlayState()
        }
    }

    private func mutate<T>(_ update: (inout PhotoLibraryWorkspaceOverlayState) throws -> T) throws -> T {
        try mutate { state, _ in
            try update(&state)
        }
    }

    private func mutate<T>(_ update: (inout PhotoLibraryWorkspaceOverlayState, PhotoLibraryWorkspaceOverlayIndex) throws -> T) throws -> T {
        lock.lock()
        var mutableState = state
        let currentIndex = index
        do {
            let result = try update(&mutableState, currentIndex)
            guard mutableState != state else {
                lock.unlock()
                return result
            }
            mutableState.version += 1
            mutableState.updatedAt = Date()
            let mutableIndex = PhotoLibraryWorkspaceOverlayIndex(state: mutableState)
            try store?.save(mutableState)
            state = mutableState
            index = mutableIndex
            lock.unlock()
            return result
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func mutateMaintainingIndex<T>(
        _ update: (inout PhotoLibraryWorkspaceOverlayState, inout PhotoLibraryWorkspaceOverlayIndex) throws -> T
    ) throws -> T {
        lock.lock()
        var mutableState = state
        var mutableIndex = index
        do {
            let result = try update(&mutableState, &mutableIndex)
            guard mutableState != state else {
                lock.unlock()
                return result
            }
            mutableState.version += 1
            mutableState.updatedAt = Date()
            try store?.save(mutableState)
            state = mutableState
            index = mutableIndex
            lock.unlock()
            return result
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func addMembership(
        _ identifier: String,
        toAlbumPath albumPath: String,
        assetReference: PhotoLibraryWorkspaceAssetReference,
        in state: inout PhotoLibraryWorkspaceOverlayState
    ) {
        state.assetReferencesByLocalIdentifier[identifier] = assetReference
        removeIdentifier(identifier, from: &state.membershipRemovalsByAlbumPath[albumPath])
        appendIdentifier(identifier, to: &state.membershipAdditionsByAlbumPath[albumPath])
    }

    private func trashAssetRecord(
        _ assetReference: PhotoLibraryWorkspaceAssetReference,
        originalPath: String,
        existingRecordID: String?,
        in state: inout PhotoLibraryWorkspaceOverlayState
    ) -> MSPWorkspaceTrashRecord {
        removeTrashedAsset(
            localIdentifier: assetReference.localIdentifier,
            existingRecordID: existingRecordID,
            from: &state
        )
        removeMembershipChanges(for: assetReference.localIdentifier, from: &state)
        let id = UUID().uuidString
        let itemDirectoryPath = PhotoLibraryMount.join(
            PhotoLibraryMount.join(state.trashConfiguration.storageRootPath, "items"),
            id
        )
        let trashPath = PhotoLibraryMount.join(itemDirectoryPath, assetReference.name)
        let record = MSPWorkspaceTrashRecord(
            id: id,
            originalPath: PhotoLibraryMount.normalizeVirtualPath(originalPath),
            originalName: assetReference.name,
            trashPath: trashPath,
            isDirectory: false,
            trashedAt: Date()
        )
        state.assetReferencesByLocalIdentifier[assetReference.localIdentifier] = assetReference
        state.trashedAssetsByID[id] = PhotoLibraryWorkspaceTrashedAsset(
            record: record,
            assetReference: assetReference
        )
        return record
    }

    private func trashAssetRecordMaintainingIndex(
        _ assetReference: PhotoLibraryWorkspaceAssetReference,
        originalPath: String,
        existingRecordID: String?,
        index: inout PhotoLibraryWorkspaceOverlayIndex,
        in state: inout PhotoLibraryWorkspaceOverlayState
    ) -> MSPWorkspaceTrashRecord {
        removeTrashedAssetMaintainingIndex(
            localIdentifier: assetReference.localIdentifier,
            existingRecordID: existingRecordID,
            index: &index,
            from: &state
        )
        removeMembershipChanges(for: assetReference.localIdentifier, from: &state)
        let id = UUID().uuidString
        let itemDirectoryPath = PhotoLibraryMount.join(
            PhotoLibraryMount.join(state.trashConfiguration.storageRootPath, "items"),
            id
        )
        let trashPath = PhotoLibraryMount.join(itemDirectoryPath, assetReference.name)
        let record = MSPWorkspaceTrashRecord(
            id: id,
            originalPath: PhotoLibraryMount.normalizeVirtualPath(originalPath),
            originalName: assetReference.name,
            trashPath: trashPath,
            isDirectory: false,
            trashedAt: Date()
        )
        let trashedAsset = PhotoLibraryWorkspaceTrashedAsset(
            record: record,
            assetReference: assetReference
        )
        state.assetReferencesByLocalIdentifier[assetReference.localIdentifier] = assetReference
        state.trashedAssetsByID[id] = trashedAsset
        index.insertTrashedAsset(trashedAsset, configuration: state.trashConfiguration)
        return record
    }

    private func removeTrashedAsset(
        localIdentifier: String,
        existingRecordID: String?,
        from state: inout PhotoLibraryWorkspaceOverlayState
    ) {
        if let existingRecordID {
            state.trashedAssetsByID.removeValue(forKey: existingRecordID)
            return
        }
        for trashedAsset in state.trashedAssetsByID.values
            where trashedAsset.assetReference.localIdentifier == localIdentifier {
            state.trashedAssetsByID.removeValue(forKey: trashedAsset.record.id)
        }
    }

    private func removeTrashedAssetMaintainingIndex(
        localIdentifier: String,
        existingRecordID: String?,
        index: inout PhotoLibraryWorkspaceOverlayIndex,
        from state: inout PhotoLibraryWorkspaceOverlayState
    ) {
        if let existingRecordID,
           let removed = state.trashedAssetsByID.removeValue(forKey: existingRecordID) {
            index.removeTrashedAsset(removed, configuration: state.trashConfiguration)
            return
        }
        for trashedAsset in state.trashedAssetsByID.values
            where trashedAsset.assetReference.localIdentifier == localIdentifier {
            state.trashedAssetsByID.removeValue(forKey: trashedAsset.record.id)
            index.removeTrashedAsset(trashedAsset, configuration: state.trashConfiguration)
        }
    }

    private func removeTrashedAlbum(
        at virtualPath: String,
        existingRecordID: String?,
        from state: inout PhotoLibraryWorkspaceOverlayState
    ) {
        if let existingRecordID {
            state.trashedAlbumsByID.removeValue(forKey: existingRecordID)
            return
        }
        let normalized = PhotoLibraryMount.normalizeVirtualPath(virtualPath)
        for trashedAlbum in state.trashedAlbumsByID.values
            where trashedAlbum.albumReference.virtualPath == normalized {
            state.trashedAlbumsByID.removeValue(forKey: trashedAlbum.record.id)
        }
    }

    private func removeMembershipChanges(
        for identifier: String,
        from state: inout PhotoLibraryWorkspaceOverlayState
    ) {
        for albumPath in Array(state.membershipAdditionsByAlbumPath.keys) {
            removeIdentifier(identifier, from: &state.membershipAdditionsByAlbumPath[albumPath])
        }
        for albumPath in Array(state.membershipRemovalsByAlbumPath.keys) {
            removeIdentifier(identifier, from: &state.membershipRemovalsByAlbumPath[albumPath])
        }
    }

    private func appendIdentifier(_ identifier: String, to identifiers: inout [String]?) {
        var values = identifiers ?? []
        guard !values.contains(identifier) else {
            identifiers = values
            return
        }
        values.append(identifier)
        identifiers = values
    }

    private func removeIdentifier(_ identifier: String, from identifiers: inout [String]?) {
        guard var values = identifiers else {
            return
        }
        values.removeAll { $0 == identifier }
        identifiers = values.isEmpty ? nil : values
    }
}

final class PhotoLibraryWorkspaceOverlayStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = PhotoLibraryWorkspaceOverlayStore.defaultFileURL(),
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
            .appendingPathComponent("photo-library-workspace-overlay.json")
    }

    func load() -> PhotoLibraryWorkspaceOverlayState? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PhotoLibraryWorkspaceOverlayState.self, from: data),
              state.schemaVersion == PhotoLibraryWorkspaceOverlayState.schemaVersion
        else {
            return nil
        }
        return state
    }

    func save(_ state: PhotoLibraryWorkspaceOverlayState) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

struct PhotoLibraryWorkspaceOverlayState: Codable, Sendable, Equatable {
    static let schemaVersion = 2

    var schemaVersion = PhotoLibraryWorkspaceOverlayState.schemaVersion
    var trashConfiguration = MSPWorkspaceTrashConfiguration.displayedTrash(
        displayRootPath: "/最近删除",
        storageRootPath: "/.msp/photo-library-trash"
    )
    var assetReferencesByLocalIdentifier: [String: PhotoLibraryWorkspaceAssetReference] = [:]
    var trashedAssetsByID: [String: PhotoLibraryWorkspaceTrashedAsset] = [:]
    var trashedAlbumsByID: [String: PhotoLibraryWorkspaceTrashedAlbum] = [:]
    var pendingUserAlbumsByPath: [String: PhotoLibraryWorkspacePendingAlbum] = [:]
    var deletedUserAlbumsByPath: [String: PhotoLibraryWorkspaceAlbumReference] = [:]
    var membershipAdditionsByAlbumPath: [String: [String]] = [:]
    var membershipRemovalsByAlbumPath: [String: [String]] = [:]
    var version = 0
    var updatedAt: Date?
}
