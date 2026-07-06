import Foundation
import MSPCore
import Photos

extension PhotoLibraryMount: PhotoSorterMediaMetadataProviding, PhotoSorterMediaListing, PhotoSorterMediaStatsProviding, PhotoSorterFileTreeSnapshotProviding {
    func photoSorterFileTreeSnapshot(rootPath: String, maxUserAlbums: Int) -> String {
        photoWorkspacePromptTreeContext(rootPath: rootPath, maxUserAlbums: maxUserAlbums)
    }

    func photoSorterMediaMetadata(for virtualPath: String) throws -> PhotoSorterMediaMetadata? {
        guard let asset = try asset(at: virtualPath) else {
            return nil
        }
        return PhotoSorterMediaMetadata(
            path: asset.virtualPath,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaType: Self.photoSorterMediaType(for: asset.mediaType),
            cachedPlace: cachedPlace(for: asset)
        )
    }

    func photoSorterMediaList(
        in scopePath: String,
        offset: Int,
        limit: Int,
        sort: PhotoSorterMediaListSort,
        order: PhotoSorterMediaListOrder,
        mediaType: PhotoSorterMediaType
    ) throws -> PhotoSorterMediaListPage {
        let normalizedScope = Self.normalizeVirtualPath(scopePath)
        if sort == .created, order == .desc, mediaType == .all {
            let offset = max(offset, 0)
            let limit = max(limit, 0)
            let pageAssets = try assets(
                in: normalizedScope,
                offset: offset,
                limit: limit
            ).map(Self.mediaListItem)
            return PhotoSorterMediaListPage(
                items: pageAssets,
                totalCount: try assetCount(in: normalizedScope),
                offset: offset,
                limit: limit
            )
        }

        let allAssets = try assets(in: normalizedScope)
            .map(Self.mediaListItem)
            .filter { item in
                switch mediaType {
                case .all:
                    return true
                case .image, .video:
                    return item.mediaType == mediaType
                case .unknown:
                    return item.mediaType == .unknown
                }
            }
            .sorted { lhs, rhs in
                let isAscending = order == .asc
                switch sort {
                case .created:
                    return Self.compareDates(
                        lhs.creationDate,
                        rhs.creationDate,
                        lhsPath: lhs.path,
                        rhsPath: rhs.path,
                        ascending: isAscending
                    )
                case .modified:
                    return Self.compareDates(
                        lhs.modificationDate ?? lhs.creationDate,
                        rhs.modificationDate ?? rhs.creationDate,
                        lhsPath: lhs.path,
                        rhsPath: rhs.path,
                        ascending: isAscending
                    )
                case .name:
                    return isAscending
                        ? lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                        : lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
                }
            }
        let offset = max(offset, 0)
        let limit = max(limit, 0)
        let pageItems = Array(allAssets.dropFirst(min(offset, allAssets.count)).prefix(limit))
        return PhotoSorterMediaListPage(
            items: pageItems,
            totalCount: allAssets.count,
            offset: offset,
            limit: limit
        )
    }

    func photoSorterMediaStats(
        in scopePath: String,
        groupBy: PhotoSorterMediaStatsGroup,
        dateField: PhotoSorterMediaStatsDateField,
        mediaType: PhotoSorterMediaType
    ) throws -> [PhotoSorterMediaStatsBucket] {
        let items = try assets(in: Self.normalizeVirtualPath(scopePath))
            .map(Self.mediaListItem)
            .filter { item in
                mediaType == .all || item.mediaType == mediaType
            }
        return Self.statsBuckets(items: items, groupBy: groupBy, dateField: dateField)
    }

    private static func mediaListItem(_ asset: MountedAsset) -> PhotoSorterMediaListItem {
        PhotoSorterMediaListItem(
            path: asset.virtualPath,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaType: photoSorterMediaType(for: asset.mediaType)
        )
    }

    private static func photoSorterMediaType(for mediaType: PHAssetMediaType) -> PhotoSorterMediaType {
        switch mediaType {
        case .image:
            return .image
        case .video:
            return .video
        default:
            return .unknown
        }
    }

    private static func compareDates(
        _ lhs: Date?,
        _ rhs: Date?,
        lhsPath: String,
        rhsPath: String,
        ascending: Bool
    ) -> Bool {
        let lhsDate = lhs ?? .distantPast
        let rhsDate = rhs ?? .distantPast
        if lhsDate != rhsDate {
            return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
        }
        return ascending
            ? lhsPath.localizedStandardCompare(rhsPath) == .orderedAscending
            : lhsPath.localizedStandardCompare(rhsPath) == .orderedDescending
    }

    private static func statsBuckets(
        items: [PhotoSorterMediaListItem],
        groupBy: PhotoSorterMediaStatsGroup,
        dateField: PhotoSorterMediaStatsDateField
    ) -> [PhotoSorterMediaStatsBucket] {
        let grouped: [String: [PhotoSorterMediaListItem]]
        switch groupBy {
        case .type:
            grouped = Dictionary(grouping: items, by: { $0.mediaType.rawValue })
        case .month:
            grouped = Dictionary(grouping: items, by: { item in
                PhotoSorterMediaCommand.monthText(
                    for: dateField == .created ? item.creationDate : item.modificationDate
                )
            })
        }
        return grouped
            .map { PhotoSorterMediaStatsBucket(key: $0.key, count: $0.value.count) }
            .sorted { $0.key < $1.key }
    }
}

extension PhotoLibraryMount: PhotoSorterAlbumManaging {
    func addPhotoSorterAssets(
        at assetPaths: [String],
        toAlbumPath albumPath: String,
        createAlbumIfNeeded: Bool
    ) throws -> PhotoSorterAlbumAddSummary {
        try addWorkspaceAssets(
            at: assetPaths,
            toUserAlbumPath: albumPath,
            createAlbumIfNeeded: createAlbumIfNeeded
        )
    }

    func removePhotoSorterAssets(
        at assetPaths: [String],
        fromAlbumPath albumPath: String
    ) throws -> PhotoSorterAlbumRemoveSummary {
        try removeWorkspaceAssets(
            at: assetPaths,
            fromUserAlbumPath: albumPath
        )
    }

    func deletePhotoSorterUserAlbumContainer(at virtualPath: String) throws {
        try deleteUserAlbumContainer(at: virtualPath)
    }
}

extension PhotoLibraryMount: PhotoSorterAssetTrashBatching {
    func trashPhotoSorterAssets(at virtualPaths: [String]) throws -> PhotoSorterMediaTrashSummary {
        let summary = try trashWorkspaceAssets(at: virtualPaths)
        return PhotoSorterMediaTrashSummary(
            requested: summary.requested,
            trashed: summary.trashed,
            missingPaths: summary.missingPaths
        )
    }
}

extension PhotoLibraryMount: PhotoSorterAssetTrashRestoring {
    func restorePhotoSorterTrash(at virtualPaths: [String]) throws -> PhotoSorterMediaRestoreSummary {
        var restored = 0
        var missingPaths: [String] = []
        for path in virtualPaths {
            do {
                _ = try restoreWorkspaceTrash(displayPath: path)
                restored += 1
            } catch MSPWorkspaceFileSystemError.notFound(let missingPath) {
                missingPaths.append(missingPath)
            }
        }
        return PhotoSorterMediaRestoreSummary(
            requested: virtualPaths.count,
            restored: restored,
            missingPaths: missingPaths
        )
    }
}

extension PhotoLibraryMount: PhotoSorterMediaCacheStatusProviding {
    var photoSorterMediaIndexStatus: PhotoLibraryIndexStatus {
        photoLibraryIndexStatus
    }

    var photoSorterMediaOCRCacheStatus: PhotoSorterMediaOCRCacheStatus {
        photoLibraryOCRCacheStatus
    }

    var photoSorterMediaPlaceCacheStatus: PhotoSorterMediaPlaceCacheStatus {
        photoLibraryPlaceCacheStatus
    }
}
