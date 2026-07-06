import Foundation

enum PhotoSorterMediaMetadataLookup: Sendable, Equatable {
    case hit(PhotoSorterMediaMetadata)
    case unavailable(String)
}

protocol PhotoSorterMediaMetadataProviding: Sendable {
    func photoSorterMediaMetadata(for virtualPath: String) throws -> PhotoSorterMediaMetadata?
    func photoSorterMediaMetadata(for virtualPaths: [String]) -> [PhotoSorterMediaMetadataLookup]
}

protocol PhotoSorterMediaListing: Sendable {
    func photoSorterMediaList(
        in scopePath: String,
        offset: Int,
        limit: Int,
        sort: PhotoSorterMediaListSort,
        order: PhotoSorterMediaListOrder,
        mediaType: PhotoSorterMediaType
    ) throws -> PhotoSorterMediaListPage
}

protocol PhotoSorterMediaStatsProviding: Sendable {
    func photoSorterMediaStats(
        in scopePath: String,
        groupBy: PhotoSorterMediaStatsGroup,
        dateField: PhotoSorterMediaStatsDateField,
        mediaType: PhotoSorterMediaType
    ) throws -> [PhotoSorterMediaStatsBucket]
}

extension PhotoSorterMediaMetadataProviding {
    func photoSorterMediaMetadata(for virtualPaths: [String]) -> [PhotoSorterMediaMetadataLookup] {
        virtualPaths.map { path in
            do {
                guard let metadata = try photoSorterMediaMetadata(for: path) else {
                    return .unavailable("media asset not found")
                }
                return .hit(metadata)
            } catch {
                return .unavailable(String(describing: error))
            }
        }
    }
}

protocol PhotoSorterMediaOCRProviding: Sendable {
    func cachedPhotoSorterMediaOCRText(for virtualPath: String) throws -> PhotoSorterMediaOCRCacheLookup
    func cachedPhotoSorterMediaOCRTexts(for virtualPaths: [String]) -> [PhotoSorterMediaOCRCacheLookup]
    func recognizePhotoSorterMediaOCRText(for virtualPath: String) async throws -> PhotoSorterMediaOCRResult?
}

extension PhotoSorterMediaOCRProviding {
    func cachedPhotoSorterMediaOCRTexts(for virtualPaths: [String]) -> [PhotoSorterMediaOCRCacheLookup] {
        virtualPaths.map { path in
            do {
                return try cachedPhotoSorterMediaOCRText(for: path)
            } catch {
                return .unavailable(String(describing: error))
            }
        }
    }
}

protocol PhotoSorterVLMProviding: Sendable {
    func photoSorterVLMStatus() -> PhotoSorterMediaVLMStatus
    func cachedPhotoSorterVLMSummary(for virtualPath: String) throws -> PhotoSorterMediaVLMCacheLookup
    func cachedPhotoSorterVLMSummaries(for virtualPaths: [String]) -> [PhotoSorterMediaVLMCacheLookup]
    func summarizePhotoSorterMediaVLM(for virtualPath: String) async throws -> PhotoSorterMediaVLMSummaryResult?
}

extension PhotoSorterVLMProviding {
    func cachedPhotoSorterVLMSummaries(for virtualPaths: [String]) -> [PhotoSorterMediaVLMCacheLookup] {
        virtualPaths.map { path in
            do {
                return try cachedPhotoSorterVLMSummary(for: path)
            } catch {
                return .unavailable(String(describing: error))
            }
        }
    }
}

final class PhotoSorterMediaLiveOCRBudgetSession: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(limit: Int) {
        self.remaining = max(0, limit)
    }

    func reserve(requestedCount: Int) -> Int {
        let requestedCount = max(0, requestedCount)
        guard requestedCount > 0 else {
            return 0
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        let granted = min(requestedCount, remaining)
        remaining -= granted
        return granted
    }
}

enum PhotoSorterMediaLiveOCRBudget {
    static let defaultLimit = 20

    @TaskLocal private static var currentSession: PhotoSorterMediaLiveOCRBudgetSession?

    static func withBudget<T>(
        limit: Int = defaultLimit,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentSession.withValue(
            PhotoSorterMediaLiveOCRBudgetSession(limit: limit),
            operation: operation
        )
    }

    static func reserve(
        requestedCount: Int,
        fallbackLimit: Int = defaultLimit
    ) -> Int {
        let requestedCount = max(0, requestedCount)
        guard requestedCount > 0 else {
            return 0
        }
        if let currentSession {
            return currentSession.reserve(requestedCount: requestedCount)
        }
        return min(requestedCount, max(0, fallbackLimit))
    }
}

final class PhotoSorterMediaLiveVLMBudgetSession: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(limit: Int) {
        self.remaining = max(0, limit)
    }

    func reserve(requestedCount: Int) -> Int {
        let requestedCount = max(0, requestedCount)
        guard requestedCount > 0 else {
            return 0
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        let granted = min(requestedCount, remaining)
        remaining -= granted
        return granted
    }
}

enum PhotoSorterMediaLiveVLMBudget {
    static let defaultLimit = 3

    @TaskLocal private static var currentSession: PhotoSorterMediaLiveVLMBudgetSession?

    static func withBudget<T>(
        limit: Int = defaultLimit,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentSession.withValue(
            PhotoSorterMediaLiveVLMBudgetSession(limit: limit),
            operation: operation
        )
    }

    static func reserve(
        requestedCount: Int,
        fallbackLimit: Int = defaultLimit
    ) -> Int {
        let requestedCount = max(0, requestedCount)
        guard requestedCount > 0 else {
            return 0
        }
        if let currentSession {
            return currentSession.reserve(requestedCount: requestedCount)
        }
        return min(requestedCount, max(0, fallbackLimit))
    }
}

protocol PhotoSorterMediaImageProviding: Sendable {
    func photoSorterModelImage(
        for virtualPath: String,
        maxPixelDimension: Int
    ) async throws -> PhotoSorterOriginalImage?
}

protocol PhotoSorterMediaReviewProviding: Sendable {
    func photoSorterReviewMedia(
        for virtualPath: String,
        maxPixelDimension: Int
    ) async throws -> PhotoSorterMediaViewItem?
}

protocol PhotoSorterMediaAskExclusionTracking: Sendable {
    func photoSorterMediaAskExcludedCountsByUser(for virtualPaths: [String]) -> [Int]
    func recordPhotoSorterMediaAskExclusionsByUser(at virtualPaths: [String]) throws
}

extension PhotoSorterMediaAskExclusionTracking {
    func photoSorterMediaAskExcludedCountsByUser(for virtualPaths: [String]) -> [Int] {
        Array(repeating: 0, count: virtualPaths.count)
    }
}

protocol PhotoSorterAlbumManaging: Sendable {
    func addPhotoSorterAssets(
        at assetPaths: [String],
        toAlbumPath albumPath: String,
        createAlbumIfNeeded: Bool
    ) throws -> PhotoSorterAlbumAddSummary

    func removePhotoSorterAssets(
        at assetPaths: [String],
        fromAlbumPath albumPath: String
    ) throws -> PhotoSorterAlbumRemoveSummary

    func deletePhotoSorterUserAlbumContainer(at virtualPath: String) throws
}

struct PhotoSorterAlbumAddSummary: Sendable, Equatable {
    var requested: Int
    var added: Int
    var skippedExisting: Int
}

struct PhotoSorterAlbumRemoveSummary: Sendable, Equatable {
    var requested: Int
    var removed: Int
    var skippedNotInAlbum: Int
}

protocol PhotoSorterAssetTrashBatching: Sendable {
    @discardableResult
    func trashPhotoSorterAssets(at virtualPaths: [String]) throws -> PhotoSorterMediaTrashSummary
}

protocol PhotoSorterAssetTrashRestoring: Sendable {
    func restorePhotoSorterTrash(at virtualPaths: [String]) throws -> PhotoSorterMediaRestoreSummary
}

struct PhotoSorterMediaTrashSummary: Sendable, Equatable {
    var requested: Int
    var trashed: Int
    var missingPaths: [String] = []

    var missing: Int {
        missingPaths.count
    }
}

struct PhotoSorterMediaRestoreSummary: Sendable, Equatable {
    var requested: Int
    var restored: Int
    var missingPaths: [String] = []

    var missing: Int {
        missingPaths.count
    }
}

protocol PhotoSorterMediaCacheStatusProviding: Sendable {
    var photoSorterMediaIndexStatus: PhotoLibraryIndexStatus { get }
    var photoSorterMediaOCRCacheStatus: PhotoSorterMediaOCRCacheStatus { get }
    var photoSorterMediaPlaceCacheStatus: PhotoSorterMediaPlaceCacheStatus { get }
}

protocol PhotoSorterFileTreeSnapshotProviding: Sendable {
    func photoSorterFileTreeSnapshot(rootPath: String, maxUserAlbums: Int) -> String
}
