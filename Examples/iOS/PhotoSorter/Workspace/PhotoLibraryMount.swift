import Foundation
import CoreImage
import CoreLocation
import CoreGraphics
import ImageIO
import MapKit
import MSPCore
import Photos
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(PhotoSorterVisionSupport)
import PhotoSorterVisionSupport
#endif

struct PhotoLibraryWorkspaceTrashBatchSummary: Sendable, Equatable {
    var requested: Int
    var trashed: Int
    var missingPaths: [String]

    var missing: Int {
        missingPaths.count
    }
}

final class PhotoLibraryMount: NSObject, @unchecked Sendable {
    struct MountedAsset: Sendable, Equatable {
        var name: String
        var virtualPath: String
        var localIdentifier: String
        var mediaType: PHAssetMediaType
        var mediaSubtypes: PHAssetMediaSubtype
        var pixelWidth: Int
        var pixelHeight: Int
        var creationDate: Date?
        var modificationDate: Date?
        var locationLatitude: Double?
        var locationLongitude: Double?
        var locationHorizontalAccuracy: Double?
    }

    struct MountedAssetDirectoryEntry: Sendable, Equatable {
        var name: String
        var virtualPath: String
        var creationDate: Date?
        var modificationDate: Date?
    }

    struct MountedAlbum: Sendable, Equatable {
        var name: String
        var virtualPath: String
        var localIdentifier: String
    }

    struct WorkspaceAssetCopyRequest: Sendable, Equatable {
        var sourcePath: String
        var destinationPath: String
    }

    enum PreviewResult: Equatable {
        case image(Data, fileName: String)
        case media(PhotoSorterMediaPreview)
        case unsupported(String)
        case unavailable(String)
    }

    enum CachedAssetLookup {
        case found(MountedAsset)
        case knownMissing
        case unknown
    }

    struct OCRImagePlan: Equatable {
        var targetSize: CGSize
        var usesTiling: Bool
        var estimatedTileCount: Int
    }

    struct OCRImageTile: Equatable {
        var index: Int
        var count: Int
        var rect: CGRect
    }

    private struct PhotoWorkspacePromptTreeRow {
        var path: String
        var name: String
        var count: Int
        var hasSubdirectories: Bool
    }

    static let rootDirectories = [
        "图库",
        "相册"
    ]

    static let albumRootPath = "/相册"
    static let systemAlbumRootPath = "/相册/系统"
    static let userAlbumRootPath = "/相册/用户"
    static let ocrUntiledMaximumLongPixelDimension = 4096
    static let ocrTileMaximumLongPixelDimension = 3072
    static let ocrTileOverlapPixelDimension = 160
    static let defaultVLMSummaryPreheatBatchLimit: Int? = nil
    static let vlmMaximumInputLongPixelDimension = 1536

    private static let ocrPreheatAssetDelayNanoseconds: UInt64 = 25_000_000
    private static let vlmPreheatAssetDelayNanoseconds: UInt64 = 100_000_000

    private struct SystemAlbumDefinition {
        var name: String
        var subtype: PHAssetCollectionSubtype

        var virtualPath: String {
            PhotoLibraryMount.join(PhotoLibraryMount.systemAlbumRootPath, name)
        }
    }

    private static let systemAlbumDefinitions = [
        SystemAlbumDefinition(name: "个人收藏", subtype: .smartAlbumFavorites),
        SystemAlbumDefinition(name: "截图", subtype: .smartAlbumScreenshots),
        SystemAlbumDefinition(name: "最近添加", subtype: .smartAlbumRecentlyAdded),
        SystemAlbumDefinition(name: "视频", subtype: .smartAlbumVideos),
        SystemAlbumDefinition(name: "屏幕录制", subtype: .smartAlbumScreenRecordings),
        SystemAlbumDefinition(name: "RAW", subtype: .smartAlbumRAW),
        SystemAlbumDefinition(name: "实况照片", subtype: .smartAlbumLivePhotos),
        SystemAlbumDefinition(name: "慢动作", subtype: .smartAlbumSlomoVideos),
        SystemAlbumDefinition(name: "全景照片", subtype: .smartAlbumPanoramas),
        SystemAlbumDefinition(name: "自拍", subtype: .smartAlbumSelfPortraits),
        SystemAlbumDefinition(name: "连拍", subtype: .smartAlbumBursts),
        SystemAlbumDefinition(name: "延时摄影", subtype: .smartAlbumTimelapses),
        SystemAlbumDefinition(name: "电影效果", subtype: .smartAlbumCinematic),
        SystemAlbumDefinition(name: "空间", subtype: .smartAlbumSpatial)
    ]

    static var systemAlbumDirectories: [String] {
        systemAlbumDefinitions.map(\.name)
    }

    static var systemAlbumDirectoryPaths: [String] {
        systemAlbumDefinitions.map(\.virtualPath)
    }

    static var photoLibraryIndexShapeFingerprint: String {
        let components = [
            "root:" + rootDirectories.joined(separator: ","),
            "albumRoot:" + albumRootPath,
            "systemRoot:" + systemAlbumRootPath,
            "userRoot:" + userAlbumRootPath
        ] + systemAlbumDefinitions.map { definition in
            [
                definition.name,
                definition.virtualPath,
                "\(definition.subtype.rawValue)"
            ].joined(separator: "|")
        }
        let joinedComponents = components.joined(separator: "\n")
        return String(
            format: "photo-library-index-shape-v1-%016llx",
            fnv1a64(joinedComponents, seed: 14_695_981_039_346_656_037)
        )
    }

    static func isSystemAlbumMediaDirectory(_ virtualPath: String) -> Bool {
        systemAlbumSubtype(for: virtualPath) != nil
    }

    static func systemAlbumSubtype(for virtualPath: String) -> PHAssetCollectionSubtype? {
        let normalized = normalizeVirtualPath(virtualPath)
        return systemAlbumDefinitions.first { definition in
            definition.virtualPath == normalized
        }?.subtype
    }

    private let imageManager = PHImageManager.default()
    private let index: PhotoLibraryIndex
    private let ocrCache: PhotoSorterMediaOCRCache
    private let placeCache: PhotoSorterMediaPlaceCache
    private let vlmSummaryCache: PhotoSorterMediaVLMSummaryCache
    private let askExclusionCache: PhotoSorterMediaAskExclusionCache
    let workspaceOverlay: PhotoLibraryWorkspaceOverlay
    private let diagnosticsLog: PhotoSorterDiagnosticsLog?
    private let manifestProvider: any PhotoLibraryManifestProviding
    private let ocrRecognitionOverride: (@Sendable (MountedAsset, String) async throws -> String?)?
    private let placeResolutionOverride: (@Sendable (CLLocation) async throws -> String?)?
    private let vlmSummaryProvider: any PhotoSorterFastVLMSummaryProviding
    private let vlmImageOverride: (@Sendable (MountedAsset) async throws -> CIImage?)?
    private let placePreheatDelayNanoseconds: UInt64
    private let vlmModelBundleDirectoryURL: URL?
    private let foregroundPhotoLibraryActivityCondition = NSCondition()
    private var foregroundPhotoLibraryActivityCount = 0
    private let ocrPreheatCondition = NSCondition()
    private var ocrPreheatState = PhotoSorterMediaOCRPreheatState.idle
    private let placePreheatCondition = NSCondition()
    private var placePreheatState = PhotoSorterMediaPlacePreheatState.idle
    private let vlmPreheatCondition = NSCondition()
    private var vlmPreheatState = PhotoSorterMediaVLMPreheatState.idle
    private var vlmForegroundInferenceAllowed = true
    private var vlmForegroundBackgroundTransitionGeneration: UInt64 = 0
    private let cacheCoverageLock = NSLock()
    private var ocrCacheCoverage: PhotoSorterMediaOCRCacheCoverage?
    private var vlmCacheCoverage: PhotoSorterMediaVLMCacheCoverage?
    private var placeCacheCoverage: PhotoSorterMediaPlaceCacheCoverage?
    private let visualCacheValidationLock = NSLock()
    private var ocrAssetsUnderContentValidation: Set<String> = []
    private var vlmAssetsUnderContentValidation: Set<String> = []
    private let presentationAssetCacheLock = NSLock()
    private var presentationAssetByVirtualPath: [String: MountedAsset] = [:]
    static let assetEnumerationPageSize = 128
    private let photoLibraryChangeNotificationCondition = NSCondition()
    private var isProcessingPhotoLibraryChangeNotification = false
    private var hasPendingPhotoLibraryChangeNotification = false
    private var photoLibraryChangeNotificationForegroundActivityCount = 0

    init(
        indexStore: PhotoLibraryIndexPersistentStore? = PhotoLibraryIndexPersistentStore(),
        ocrCache: PhotoSorterMediaOCRCache = PhotoSorterMediaOCRCache(),
        placeCache: PhotoSorterMediaPlaceCache = PhotoSorterMediaPlaceCache(),
        vlmSummaryCache: PhotoSorterMediaVLMSummaryCache = PhotoSorterMediaVLMSummaryCache(),
        askExclusionCache: PhotoSorterMediaAskExclusionCache = PhotoSorterMediaAskExclusionCache(),
        workspaceOverlay: PhotoLibraryWorkspaceOverlay = PhotoLibraryWorkspaceOverlay(),
        diagnosticsLog: PhotoSorterDiagnosticsLog? = .shared,
        manifestProvider: (any PhotoLibraryManifestProviding)? = nil,
        ocrRecognitionOverride: (@Sendable (MountedAsset, String) async throws -> String?)? = nil,
        placeResolutionOverride: (@Sendable (CLLocation) async throws -> String?)? = nil,
        vlmSummaryProvider: (any PhotoSorterFastVLMSummaryProviding)? = nil,
        vlmImageOverride: (@Sendable (MountedAsset) async throws -> CIImage?)? = nil,
        placePreheatDelayNanoseconds: UInt64 = 250_000_000,
        vlmModelBundleDirectoryURL: URL? = nil
    ) {
        self.index = PhotoLibraryIndex(store: indexStore)
        self.ocrCache = ocrCache
        self.placeCache = placeCache
        self.vlmSummaryCache = vlmSummaryCache
        self.askExclusionCache = askExclusionCache
        self.workspaceOverlay = workspaceOverlay
        self.diagnosticsLog = diagnosticsLog
        self.manifestProvider = manifestProvider ?? PhotoKitPhotoLibraryManifestProvider()
        self.ocrRecognitionOverride = ocrRecognitionOverride
        self.placeResolutionOverride = placeResolutionOverride
        self.vlmSummaryProvider = vlmSummaryProvider ?? PhotoSorterDefaultFastVLMSummaryProviderFactory.make()
        self.vlmImageOverride = vlmImageOverride
        self.placePreheatDelayNanoseconds = placePreheatDelayNanoseconds
        self.vlmModelBundleDirectoryURL = vlmModelBundleDirectoryURL
        super.init()
        self.manifestProvider.registerChangeObserver(self)
    }

    deinit {
        manifestProvider.unregisterChangeObserver(self)
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        manifestProvider.authorizationStatus()
    }

    func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        await manifestProvider.requestAuthorizationIfNeeded()
    }

    func hasReadAccess() -> Bool {
        manifestProvider.hasReadAccess()
    }

    var photoLibraryIndexStatus: PhotoLibraryIndexStatus {
        index.currentStatus
    }

    func photoWorkspacePromptTreeContext(maxUserAlbums: Int = 300) -> String {
        photoWorkspacePromptTreeContext(rootPath: "/", maxUserAlbums: maxUserAlbums)
    }

    func photoWorkspacePromptTreeContext(rootPath: String, maxUserAlbums: Int = 300) -> String {
        let status = index.currentStatus
        guard let snapshot = index.cachedSnapshotForStatus() else {
            return Self.unavailablePhotoWorkspacePromptTreeContext(status: status)
        }

        let normalizedRootPath = Self.normalizeVirtualPath(rootPath)
        guard normalizedRootPath == "/" else {
            return photoWorkspacePromptSubtreeContext(
                rootPath: normalizedRootPath,
                maxUserAlbums: maxUserAlbums,
                snapshot: snapshot,
                status: status
            )
        }

        let overlaySnapshot = workspaceOverlay.snapshot
        let overlayHasChanges = overlaySnapshot.summary.hasChanges
        let galleryCount = promptTreeAssetCount(
            path: "/图库",
            snapshot: snapshot,
            overlaySnapshot: overlaySnapshot,
            overlayHasChanges: overlayHasChanges
        )
        let systemRows = Self.systemAlbumDirectoryPaths.map { path -> (name: String, count: Int) in
            let name = snapshot.directories[path]?.name ?? Self.lastPathComponent(path)
            return (
                Self.promptTreeDisplayName(name),
                promptTreeAssetCount(
                    path: path,
                    snapshot: snapshot,
                    overlaySnapshot: overlaySnapshot,
                    overlayHasChanges: overlayHasChanges
                )
            )
        }
        let systemCount = overlayHasChanges
            ? systemRows.reduce(0) { $0 + $1.count }
            : promptTreeRecursiveAssetCount(
                path: Self.systemAlbumRootPath,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            )
        let userAlbums = overlaySnapshot.userAlbums(merging: snapshot.userAlbums)
        let maxDisplayedUserAlbums = max(maxUserAlbums, 0)
        let displayedUserAlbums = Array(userAlbums.prefix(maxDisplayedUserAlbums))
        let userRows = displayedUserAlbums.map { album in
            (
                name: Self.promptTreeDisplayName(album.name),
                count: promptTreeAssetCount(
                    path: album.virtualPath,
                    snapshot: snapshot,
                    overlaySnapshot: overlaySnapshot,
                    overlayHasChanges: overlayHasChanges
                )
            )
        }
        let userCount = overlayHasChanges
            ? userAlbums.reduce(0) { total, album in
                total + promptTreeAssetCount(
                    path: album.virtualPath,
                    snapshot: snapshot,
                    overlaySnapshot: overlaySnapshot,
                    overlayHasChanges: overlayHasChanges
                )
            }
            : promptTreeRecursiveAssetCount(
                path: Self.userAlbumRootPath,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            )
        let albumCount = systemCount + userCount
        let trashCount = overlaySnapshot.trashedAssetCount
        let hiddenUserAlbumCount = max(0, userAlbums.count - userRows.count)

        var lines = [
            "当前照片工作区树（动态快照；括号内为该目录树下的媒体条目数；相册统计的是相册引用，可能重复计算同一张照片）：",
            "",
            "/",
            "├── 图库/ (\(galleryCount))",
            "├── 相册/ (\(albumCount))",
            "│   ├── 系统/ (\(systemCount))"
        ]
        for (index, row) in systemRows.enumerated() {
            let connector = index == systemRows.count - 1 ? "│   │   └──" : "│   │   ├──"
            lines.append("\(connector) \(row.name)/ (\(row.count))")
        }

        lines.append("│   └── 用户/ (\(userCount))")
        if userRows.isEmpty {
            if hiddenUserAlbumCount > 0 {
                lines.append("│       └── ... 还有 \(hiddenUserAlbumCount) 个用户相册未列出")
            } else {
                lines.append("│       └── （无用户相册）")
            }
        } else {
            for (index, row) in userRows.enumerated() {
                let isLastDisplayedRow = index == userRows.count - 1
                let connector = isLastDisplayedRow && hiddenUserAlbumCount == 0
                    ? "│       └──"
                    : "│       ├──"
                lines.append("\(connector) \(row.name)/ (\(row.count))")
            }
            if hiddenUserAlbumCount > 0 {
                lines.append("│       └── ... 还有 \(hiddenUserAlbumCount) 个用户相册未列出")
            }
        }

        lines.append("├── 最近删除/ (\(trashCount))")
        lines.append("└── tmp/ (普通临时目录，未统计)")
        lines.append("")
        lines.append("照片库索引：\(status.phase.rawValue)，version \(status.version)，processed \(status.processed)\(status.total.map { "/\($0)" } ?? "")")
        return lines.joined(separator: "\n")
    }

    private func photoWorkspacePromptSubtreeContext(
        rootPath: String,
        maxUserAlbums: Int,
        snapshot: PhotoLibraryIndexSnapshot,
        status: PhotoLibraryIndexStatus
    ) -> String {
        let overlaySnapshot = workspaceOverlay.snapshot
        let overlayHasChanges = overlaySnapshot.summary.hasChanges
        let normalizedRootPath = Self.normalizeVirtualPath(rootPath)
        var lines = [
            "当前照片工作区树（动态快照；括号内为该目录树下的媒体条目数；相册统计的是相册引用，可能重复计算同一张照片）：",
            ""
        ]

        switch normalizedRootPath {
        case "/最近删除":
            lines.append("/最近删除/ (\(overlaySnapshot.trashedAssetCount))")
        case "/tmp":
            lines.append("/tmp/ (普通临时目录，未统计)")
        default:
            guard let directory = snapshot.directories[normalizedRootPath] else {
                lines.append("\(normalizedRootPath)/ (路径不存在于当前照片工作区树快照)")
                lines.append("")
                lines.append("照片库索引：\(status.phase.rawValue)，version \(status.version)，processed \(status.processed)\(status.total.map { "/\($0)" } ?? "")")
                return lines.joined(separator: "\n")
            }
            let count = promptTreeDisplayCount(
                path: normalizedRootPath,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            )
            lines.append("\(directory.path)/ (\(count))")
            appendPromptTreeChildLines(
                path: normalizedRootPath,
                prefix: "",
                maxUserAlbums: maxUserAlbums,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges,
                lines: &lines
            )
        }

        lines.append("")
        lines.append("照片库索引：\(status.phase.rawValue)，version \(status.version)，processed \(status.processed)\(status.total.map { "/\($0)" } ?? "")")
        return lines.joined(separator: "\n")
    }

    private func appendPromptTreeChildLines(
        path: String,
        prefix: String,
        maxUserAlbums: Int,
        snapshot: PhotoLibraryIndexSnapshot,
        overlaySnapshot: PhotoLibraryWorkspaceOverlaySnapshot,
        overlayHasChanges: Bool,
        lines: inout [String]
    ) {
        let rows = promptTreeChildRows(
            path: path,
            maxUserAlbums: maxUserAlbums,
            snapshot: snapshot,
            overlaySnapshot: overlaySnapshot,
            overlayHasChanges: overlayHasChanges
        )
        for (index, row) in rows.displayed.enumerated() {
            let isLastDisplayedRow = index == rows.displayed.count - 1 && rows.hiddenCount == 0
            let connector = isLastDisplayedRow ? "└──" : "├──"
            lines.append("\(prefix)\(connector) \(row.name)/ (\(row.count))")
            guard row.hasSubdirectories else {
                continue
            }
            let childPrefix = prefix + (isLastDisplayedRow ? "    " : "│   ")
            appendPromptTreeChildLines(
                path: row.path,
                prefix: childPrefix,
                maxUserAlbums: maxUserAlbums,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges,
                lines: &lines
            )
        }
        if rows.hiddenCount > 0 {
            lines.append("\(prefix)└── ... 还有 \(rows.hiddenCount) 个用户相册未列出")
        }
    }

    private func promptTreeChildRows(
        path: String,
        maxUserAlbums: Int,
        snapshot: PhotoLibraryIndexSnapshot,
        overlaySnapshot: PhotoLibraryWorkspaceOverlaySnapshot,
        overlayHasChanges: Bool
    ) -> (displayed: [PhotoWorkspacePromptTreeRow], hiddenCount: Int) {
        let normalized = Self.normalizeVirtualPath(path)
        let maxDisplayedUserAlbums = max(maxUserAlbums, 0)
        let childPaths: [String]
        let userAlbumNamesByPath: [String: String]
        if normalized == Self.userAlbumRootPath {
            let userAlbums = overlaySnapshot.userAlbums(merging: snapshot.userAlbums)
            childPaths = userAlbums.map(\.virtualPath)
            userAlbumNamesByPath = Dictionary(uniqueKeysWithValues: userAlbums.map { ($0.virtualPath, $0.name) })
        } else {
            childPaths = snapshot.directories[normalized]?.childDirectoryPaths ?? []
            userAlbumNamesByPath = [:]
        }
        let displayedPaths = normalized == Self.userAlbumRootPath
            ? Array(childPaths.prefix(maxDisplayedUserAlbums))
            : childPaths
        let rows = displayedPaths.map { childPath in
            let directory = snapshot.directories[childPath]
            let name = directory?.name ?? userAlbumNamesByPath[childPath] ?? Self.lastPathComponent(childPath)
            return PhotoWorkspacePromptTreeRow(
                path: childPath,
                name: Self.promptTreeDisplayName(name),
                count: promptTreeDisplayCount(
                    path: childPath,
                    snapshot: snapshot,
                    overlaySnapshot: overlaySnapshot,
                    overlayHasChanges: overlayHasChanges
                ),
                hasSubdirectories: promptTreeHasSubdirectories(
                    path: childPath,
                    snapshot: snapshot,
                    overlaySnapshot: overlaySnapshot
                )
            )
        }
        let hiddenCount = normalized == Self.userAlbumRootPath
            ? max(0, childPaths.count - rows.count)
            : 0
        return (rows, hiddenCount)
    }

    private func promptTreeHasSubdirectories(
        path: String,
        snapshot: PhotoLibraryIndexSnapshot,
        overlaySnapshot: PhotoLibraryWorkspaceOverlaySnapshot
    ) -> Bool {
        let normalized = Self.normalizeVirtualPath(path)
        if normalized == Self.userAlbumRootPath {
            return !overlaySnapshot.userAlbums(merging: snapshot.userAlbums).isEmpty
        }
        return !(snapshot.directories[normalized]?.childDirectoryPaths ?? []).isEmpty
    }

    private func promptTreeDisplayCount(
        path: String,
        snapshot: PhotoLibraryIndexSnapshot,
        overlaySnapshot: PhotoLibraryWorkspaceOverlaySnapshot,
        overlayHasChanges: Bool
    ) -> Int {
        let normalized = Self.normalizeVirtualPath(path)
        if normalized == Self.albumRootPath {
            return promptTreeDisplayCount(
                path: Self.systemAlbumRootPath,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            ) + promptTreeDisplayCount(
                path: Self.userAlbumRootPath,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            )
        }
        if normalized == Self.userAlbumRootPath, overlayHasChanges {
            return overlaySnapshot.userAlbums(merging: snapshot.userAlbums).reduce(0) { total, album in
                total + promptTreeAssetCount(
                    path: album.virtualPath,
                    snapshot: snapshot,
                    overlaySnapshot: overlaySnapshot,
                    overlayHasChanges: overlayHasChanges
                )
            }
        }
        guard let directory = snapshot.directories[normalized] else {
            return 0
        }
        if directory.childDirectoryPaths.isEmpty {
            return promptTreeAssetCount(
                path: normalized,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            )
        }
        return promptTreeRecursiveAssetCount(
            path: normalized,
            snapshot: snapshot,
            overlaySnapshot: overlaySnapshot,
            overlayHasChanges: overlayHasChanges
        )
    }

    static func unavailablePhotoWorkspacePromptTreeContext(status: PhotoLibraryIndexStatus) -> String {
        "当前照片工作区树快照暂不可用；照片库索引：\(status.phase.rawValue)，version \(status.version)，processed \(status.processed)\(status.total.map { "/\($0)" } ?? "")。需要显式当前快照时运行 `filetree ls`。"
    }

    func withForegroundPhotoLibraryActivity<T>(
        operation: () async throws -> T
    ) async rethrows -> T {
        beginForegroundPhotoLibraryActivity()
        defer {
            endForegroundPhotoLibraryActivity()
        }
        return try await operation()
    }

    func withForegroundPhotoLibraryActivity<T>(
        operation: () throws -> T
    ) rethrows -> T {
        beginForegroundPhotoLibraryActivity()
        defer {
            endForegroundPhotoLibraryActivity()
        }
        return try operation()
    }

    var photoLibraryOCRCacheStatus: PhotoSorterMediaOCRCacheStatus {
        let coverage = currentOCRCacheCoverage()
        let preheatState = currentOCRPreheatState()
        return PhotoSorterMediaOCRCacheStatus(
            cachedCount: coverage.cachedCount,
            totalCount: coverage.totalCount,
            isPreheating: preheatState.isRunning,
            isPaused: preheatState.isPaused,
            processedInCurrentBatch: preheatState.processed,
            batchLimit: preheatState.limit,
            message: preheatState.message
        )
    }

    var photoLibraryPlaceCacheStatus: PhotoSorterMediaPlaceCacheStatus {
        let coverage = currentPlaceCacheCoverage()
        let preheatState = currentPlacePreheatState()
        return PhotoSorterMediaPlaceCacheStatus(
            cachedCount: coverage.cachedCount,
            totalCount: coverage.totalCount,
            isPreheating: preheatState.isRunning,
            isPaused: preheatState.isPaused,
            processedInCurrentBatch: preheatState.processed,
            batchLimit: preheatState.limit,
            message: preheatState.message
        )
    }

    var photoLibraryVLMSummaryCacheStatus: PhotoSorterMediaVLMStatus {
        let primaryProvider = currentVLMProviderStatus()
        let coverage = currentVLMSummaryCacheCoverage(providerStatus: primaryProvider)
        let preheatState = currentVLMPreheatState()
        return PhotoSorterMediaVLMStatus(
            primaryProvider: primaryProvider,
            systemProvider: PhotoSorterMediaVLMConfiguration.systemUnavailableProviderStatus,
            cachedCount: coverage.cachedCount,
            totalCount: coverage.totalCount,
            isPreheating: preheatState.isRunning || preheatState.isWaitingForForeground,
            isPaused: preheatState.isPaused,
            processedInCurrentBatch: preheatState.processed,
            batchLimit: preheatState.limit,
            failedInCurrentBatch: preheatState.failed,
            skippedInCurrentBatch: preheatState.skipped,
            message: preheatState.message,
            promptVersion: PhotoSorterMediaVLMConfiguration.promptVersion,
            prompt: PhotoSorterMediaVLMConfiguration.prompt,
            language: PhotoSorterMediaVLMConfiguration.language,
            summarySchemaVersion: PhotoSorterMediaVLMConfiguration.summarySchemaVersion
        )
    }

    var photoLibraryWorkspaceChangeSummary: PhotoLibraryWorkspaceChangeSummary {
        workspaceOverlay.summary
    }

    func startPhotoLibraryIndexRefresh(reason: String = "同步照片库索引") {
        index.refreshInBackground(reason: reason) { [self] previousSnapshot, progress in
            try resolveIndexSnapshot(previousSnapshot: previousSnapshot, progress: progress)
        }
    }

    func markPhotoLibraryIndexDirty(reason: String) {
        index.markDirty(reason: reason)
    }

    func handlePhotoLibraryChangeNotification() {
        photoLibraryChangeNotificationCondition.lock()
        hasPendingPhotoLibraryChangeNotification = true
        if isProcessingPhotoLibraryChangeNotification {
            photoLibraryChangeNotificationCondition.unlock()
            return
        }
        isProcessingPhotoLibraryChangeNotification = true
        photoLibraryChangeNotificationCondition.broadcast()
        photoLibraryChangeNotificationCondition.unlock()

        Task.detached(priority: .utility) { [weak self] in
            self?.runPhotoLibraryChangeNotificationLoop()
        }
    }

    func assets(in virtualDirectoryPath: String, offset: Int = 0, limit: Int? = nil) throws -> [MountedAsset] {
        let snapshot = try currentIndexSnapshot(reason: "读取照片目录")
        return effectiveSnapshotAssets(
            in: virtualDirectoryPath,
            offset: offset,
            limit: limit,
            snapshot: snapshot
        )
    }

    func assetCount(in virtualDirectoryPath: String) throws -> Int {
        let snapshot = try currentIndexSnapshot(reason: "读取照片目录统计")
        return effectiveSnapshotAssetCount(
            in: virtualDirectoryPath,
            snapshot: snapshot
        )
    }

    func cachedAssets(in virtualDirectoryPath: String, offset: Int = 0, limit: Int? = nil) -> [MountedAsset]? {
        guard let snapshot = index.cachedSnapshotForStatus() else {
            return nil
        }
        return effectiveSnapshotAssets(
            in: virtualDirectoryPath,
            offset: offset,
            limit: limit,
            snapshot: snapshot
        )
    }

    func assetDirectoryEntries(
        in virtualDirectoryPath: String,
        offset: Int = 0,
        limit: Int? = nil
    ) throws -> [MountedAssetDirectoryEntry] {
        let snapshot = try currentIndexSnapshot(reason: "读取照片目录")
        return effectiveSnapshotAssetDirectoryEntries(
            in: virtualDirectoryPath,
            offset: offset,
            limit: limit,
            snapshot: snapshot
        )
    }

    func enumerateAssetDirectoryEntries(
        in virtualDirectoryPath: String,
        limit: Int? = nil,
        visitor: (MountedAssetDirectoryEntry) async throws -> Bool
    ) async throws {
        let snapshot = try currentIndexSnapshot(reason: "读取照片目录")
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        let overlaySnapshot = workspaceOverlay.snapshot
        var offset = 0
        var remaining = limit.map { max($0, 0) }
        if remaining == 0 {
            return
        }

        if !overlaySnapshot.hasAssetChanges(in: normalized) {
            guard let directory = snapshot.directories[normalized] else {
                return
            }
            let identifiers = directory.assetLocalIdentifiers
            let endIndex = min(identifiers.count, remaining ?? identifiers.count)
            guard endIndex > 0 else {
                return
            }
            for localIdentifier in identifiers[..<endIndex] {
                guard let asset = snapshot.assetsByLocalIdentifier[localIdentifier] else {
                    continue
                }
                guard try await visitor(Self.mountedAssetDirectoryEntry(asset, in: normalized)) else {
                    return
                }
            }
            return
        }

        while true {
            let pageLimit = min(remaining ?? Self.assetEnumerationPageSize, Self.assetEnumerationPageSize)
            let entries = effectiveSnapshotAssetDirectoryEntries(
                in: normalized,
                offset: offset,
                limit: pageLimit,
                snapshot: snapshot
            )
            guard !entries.isEmpty else {
                return
            }
            for entry in entries {
                guard try await visitor(entry) else {
                    return
                }
            }
            offset += entries.count
            if let currentRemaining = remaining {
                remaining = max(currentRemaining - entries.count, 0)
                if remaining == 0 {
                    return
                }
            }
            if entries.count < pageLimit {
                return
            }
        }
    }

    func enumerateAssetDirectoryEntryBatches(
        in virtualDirectoryPath: String,
        batchSize: Int = PhotoLibraryMount.assetEnumerationPageSize,
        visitor: ([MountedAssetDirectoryEntry]) async throws -> Bool
    ) async throws {
        let snapshot = try currentIndexSnapshot(reason: "读取照片目录")
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        let overlaySnapshot = workspaceOverlay.snapshot
        let resolvedBatchSize = max(1, batchSize)

        if !overlaySnapshot.hasAssetChanges(in: normalized) {
            guard let directory = snapshot.directories[normalized] else {
                return
            }
            var batch: [MountedAssetDirectoryEntry] = []
            batch.reserveCapacity(resolvedBatchSize)
            for localIdentifier in directory.assetLocalIdentifiers {
                guard let asset = snapshot.assetsByLocalIdentifier[localIdentifier] else {
                    continue
                }
                batch.append(Self.mountedAssetDirectoryEntry(asset, in: normalized))
                if batch.count >= resolvedBatchSize {
                    guard try await visitor(batch) else {
                        return
                    }
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                _ = try await visitor(batch)
            }
            return
        }

        var offset = 0
        while true {
            let entries = effectiveSnapshotAssetDirectoryEntries(
                in: normalized,
                offset: offset,
                limit: resolvedBatchSize,
                snapshot: snapshot
            )
            guard !entries.isEmpty else {
                return
            }
            guard try await visitor(entries) else {
                return
            }
            offset += entries.count
            if entries.count < resolvedBatchSize {
                return
            }
        }
    }

    private func promptTreeAssetCount(
        path: String,
        snapshot: PhotoLibraryIndexSnapshot,
        overlaySnapshot: PhotoLibraryWorkspaceOverlaySnapshot,
        overlayHasChanges: Bool
    ) -> Int {
        let normalized = Self.normalizeVirtualPath(path)
        guard let directory = snapshot.directories[normalized] else {
            return 0
        }
        guard overlayHasChanges else {
            return directory.directFileCount
        }
        return overlaySnapshot.effectiveAssetCount(
            in: normalized,
            baseAssetLocalIdentifiers: directory.assetLocalIdentifiers
        )
    }

    private func promptTreeRecursiveAssetCount(
        path: String,
        snapshot: PhotoLibraryIndexSnapshot,
        overlaySnapshot: PhotoLibraryWorkspaceOverlaySnapshot,
        overlayHasChanges: Bool
    ) -> Int {
        let normalized = Self.normalizeVirtualPath(path)
        guard let directory = snapshot.directories[normalized] else {
            return 0
        }
        guard overlayHasChanges else {
            return directory.recursiveFileCount
        }
        return promptTreeAssetCount(
            path: normalized,
            snapshot: snapshot,
            overlaySnapshot: overlaySnapshot,
            overlayHasChanges: overlayHasChanges
        ) + directory.childDirectoryPaths.reduce(0) { total, childPath in
            total + promptTreeRecursiveAssetCount(
                path: childPath,
                snapshot: snapshot,
                overlaySnapshot: overlaySnapshot,
                overlayHasChanges: overlayHasChanges
            )
        }
    }

    private static func promptTreeDisplayName(_ name: String) -> String {
        name.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lastPathComponent(_ path: String) -> String {
        normalizeVirtualPath(path).split(separator: "/").last.map(String.init) ?? path
    }

    func presentationAssets(in virtualDirectoryPath: String, offset: Int = 0, limit: Int? = nil) -> [MountedAsset] {
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        if let cachedAssets = cachedAssets(in: normalized, offset: offset, limit: limit) {
            return cachedAssets
        }

        guard let records = manifestProvider.presentationAssetRecords(
            in: normalized,
            offset: offset,
            limit: limit
        ) else {
            return workspaceOverlay.snapshot.effectiveAssets(
                in: normalized,
                baseAssets: []
            ) { [weak self] identifier in
                self?.presentationAssetReference(localIdentifier: identifier)
            }.sliced(offset: offset, limit: limit)
        }

        let mountedAssets = Self.mountedAssets(from: records, in: normalized)
        rememberPresentationAssets(mountedAssets)
        return workspaceOverlay.snapshot.effectiveAssets(
            in: normalized,
            baseAssets: mountedAssets
        ) { [weak self] identifier in
            self?.presentationAssetReference(localIdentifier: identifier)
        }.sliced(offset: 0, limit: limit)
    }

    private func effectiveSnapshotAssets(
        in virtualDirectoryPath: String,
        offset: Int,
        limit: Int?,
        snapshot: PhotoLibraryIndexSnapshot
    ) -> [MountedAsset] {
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        let overlaySnapshot = workspaceOverlay.snapshot
        guard overlaySnapshot.hasAssetChanges(in: normalized) else {
            return snapshot.assets(in: normalized, offset: offset, limit: limit)
        }
        let identifiers = snapshot.directories[normalized]?.assetLocalIdentifiers ?? []
        return overlaySnapshot.effectiveAssetsPage(
            in: normalized,
            baseAssetLocalIdentifiers: identifiers,
            offset: offset,
            limit: limit
        ) { identifier in
            Self.mountedAsset(localIdentifier: identifier, from: snapshot)
        }
    }

    private func effectiveSnapshotAssetCount(
        in virtualDirectoryPath: String,
        snapshot: PhotoLibraryIndexSnapshot
    ) -> Int {
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        guard let directory = snapshot.directories[normalized] else {
            return 0
        }
        return workspaceOverlay.snapshot.effectiveAssetCount(
            in: normalized,
            baseAssetLocalIdentifiers: directory.assetLocalIdentifiers
        )
    }

    private func effectiveSnapshotAssetDirectoryEntries(
        in virtualDirectoryPath: String,
        offset: Int,
        limit: Int?,
        snapshot: PhotoLibraryIndexSnapshot
    ) -> [MountedAssetDirectoryEntry] {
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        let overlaySnapshot = workspaceOverlay.snapshot
        guard overlaySnapshot.hasAssetChanges(in: normalized) else {
            guard let directory = snapshot.directories[normalized] else {
                return []
            }
            let identifiers = directory.assetLocalIdentifiers
            let startIndex = Swift.min(Swift.max(offset, 0), identifiers.count)
            let endIndex = limit.map { Swift.min(startIndex + Swift.max($0, 0), identifiers.count) } ?? identifiers.count
            guard startIndex < endIndex else {
                return []
            }
            return identifiers[startIndex..<endIndex].compactMap { identifier in
                snapshot.assetsByLocalIdentifier[identifier].map {
                    Self.mountedAssetDirectoryEntry($0, in: normalized)
                }
            }
        }
        return effectiveSnapshotAssets(
            in: normalized,
            offset: offset,
            limit: limit,
            snapshot: snapshot
        ).map(Self.mountedAssetDirectoryEntry)
    }

    func enumerateAssets(
        in virtualDirectoryPath: String,
        limit: Int? = nil,
        visitor: (MountedAsset) async throws -> Bool
    ) async throws {
        let snapshot = try currentIndexSnapshot(reason: "读取照片目录")
        let normalized = Self.normalizeVirtualPath(virtualDirectoryPath)
        let overlaySnapshot = workspaceOverlay.snapshot
        var offset = 0
        var remaining = limit.map { max($0, 0) }
        if remaining == 0 {
            return
        }

        if !overlaySnapshot.hasAssetChanges(in: normalized) {
            guard let directory = snapshot.directories[normalized] else {
                return
            }
            let identifiers = directory.assetLocalIdentifiers
            let endIndex = min(identifiers.count, remaining ?? identifiers.count)
            guard endIndex > 0 else {
                return
            }
            for localIdentifier in identifiers[..<endIndex] {
                guard let asset = snapshot.assetsByLocalIdentifier[localIdentifier]?.mountedAsset(in: normalized) else {
                    continue
                }
                guard try await visitor(asset) else {
                    return
                }
            }
            return
        }

        while true {
            let pageLimit = min(remaining ?? Self.assetEnumerationPageSize, Self.assetEnumerationPageSize)
            let mountedAssets = effectiveSnapshotAssets(
                in: normalized,
                offset: offset,
                limit: pageLimit,
                snapshot: snapshot
            )
            guard !mountedAssets.isEmpty else {
                return
            }
            for mountedAsset in mountedAssets {
                guard try await visitor(mountedAsset) else {
                    return
                }
            }
            offset += mountedAssets.count
            if let currentRemaining = remaining {
                remaining = max(currentRemaining - mountedAssets.count, 0)
                if remaining == 0 {
                    return
                }
            }
            if mountedAssets.count < pageLimit {
                return
            }
        }
    }

    func userAlbums() -> [MountedAlbum] {
        let realAlbums = (try? currentIndexSnapshot(reason: "读取用户相册"))?.userAlbums ?? []
        return workspaceOverlay.snapshot.userAlbums(merging: realAlbums)
    }

    func cachedUserAlbums() -> [MountedAlbum]? {
        guard let realAlbums = index.cachedSnapshotForStatus()?.userAlbums else {
            return nil
        }
        return workspaceOverlay.snapshot.userAlbums(merging: realAlbums)
    }

    func presentationUserAlbums() -> [MountedAlbum]? {
        let realAlbums = cachedUserAlbums() ?? manifestProvider.presentationUserAlbums()
        guard let realAlbums else {
            return workspaceOverlay.snapshot.pendingUserAlbums.map(\.mountedAlbum)
        }
        return workspaceOverlay.snapshot.userAlbums(merging: realAlbums)
    }

    func asset(at virtualPath: String) throws -> MountedAsset? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        let snapshot = try currentIndexSnapshot(reason: "读取媒体文件")
        return workspaceOverlay.snapshot.effectiveAsset(
            at: normalized,
            baseAsset: snapshot.asset(at: normalized)
        ) { identifier in
            Self.mountedAsset(localIdentifier: identifier, from: snapshot)
        }
    }

    func cachedAsset(at virtualPath: String) -> MountedAsset? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let snapshot = index.cachedSnapshotForStatus() else {
            return workspaceOverlay.snapshot.effectiveAsset(
                at: normalized,
                baseAsset: nil
            ) { [weak self] identifier in
                self?.presentationAssetReference(localIdentifier: identifier)
            }
        }
        return workspaceOverlay.snapshot.effectiveAsset(
            at: normalized,
            baseAsset: snapshot.asset(at: normalized)
        ) { identifier in
            Self.mountedAsset(localIdentifier: identifier, from: snapshot)
        }
    }

    func cachedAssetLookup(at virtualPath: String) -> CachedAssetLookup {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        let overlaySnapshot = workspaceOverlay.snapshot
        guard let snapshot = index.cachedSnapshotForStatus() else {
            let asset = overlaySnapshot.effectiveAsset(
                at: normalized,
                baseAsset: nil,
                assetResolver: { [weak self] identifier in
                    self?.presentationAssetReference(localIdentifier: identifier)
                }
            )
            if let asset {
                return .found(asset)
            }
            return .unknown
        }

        let baseAsset = snapshot.asset(at: normalized)
        let asset = overlaySnapshot.effectiveAsset(
            at: normalized,
            baseAsset: baseAsset,
            assetResolver: { identifier in
                Self.mountedAsset(localIdentifier: identifier, from: snapshot)
            }
        )
        if let asset {
            return .found(asset)
        }
        if baseAsset != nil {
            return .knownMissing
        }
        return .unknown
    }

    func presentationAsset(at virtualPath: String) -> MountedAsset? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        let baseAsset: MountedAsset?
        if let snapshot = index.cachedSnapshotForStatus() {
            baseAsset = snapshot.asset(at: normalized)
        } else {
            presentationAssetCacheLock.lock()
            baseAsset = presentationAssetByVirtualPath[normalized]
            presentationAssetCacheLock.unlock()
        }
        return workspaceOverlay.snapshot.effectiveAsset(
            at: normalized,
            baseAsset: baseAsset
        ) { [weak self] identifier in
            self?.presentationAssetReference(localIdentifier: identifier)
        }
    }

    func workspaceFileData(for virtualPath: String) throws -> Data? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        let mountedAsset: MountedAsset?
        if let cached = cachedAsset(at: normalized) {
            mountedAsset = cached
        } else {
            mountedAsset = try asset(at: normalized)
        }
        guard let mountedAsset else {
            return nil
        }
        return try manifestProvider.resourceData(forLocalIdentifier: mountedAsset.localIdentifier)
    }

    var photoLibraryTrashConfiguration: MSPWorkspaceTrashConfiguration {
        workspaceOverlay.snapshot.trashConfiguration
    }

    func isPhotoLibraryTrashDisplayPath(_ virtualPath: String) -> Bool {
        workspaceOverlay.snapshot.isTrashDisplayPath(virtualPath)
    }

    func photoLibraryTrashRecords() -> [MSPWorkspaceTrashRecord] {
        workspaceOverlay.snapshot.trashRecords
    }

    func listPhotoLibraryTrash(_ path: String) throws -> [MSPDirectoryEntry] {
        let normalized = Self.normalizeVirtualPath(path)
        let overlaySnapshot = workspaceOverlay.snapshot
        guard overlaySnapshot.isTrashDisplayPath(normalized),
              let displayRootPath = overlaySnapshot.trashConfiguration.displayRootPath
        else {
            throw MSPWorkspaceFileSystemError.notFound(normalized)
        }
        let info = try photoLibraryTrashFileInfo(atDisplayPath: normalized)
        guard info.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(normalized)
        }

        var entriesByName: [String: MSPDirectoryEntry] = [:]
        for record in overlaySnapshot.trashRecords {
            let displayPath = overlaySnapshot.trashDisplayPath(for: record)
            guard displayPath.hasPrefix(normalized + "/") else {
                continue
            }
            let suffix = String(displayPath.dropFirst(normalized.count + 1))
            guard let childName = suffix.split(separator: "/").first.map(String.init) else {
                continue
            }
            let childPath = Self.join(normalized, childName)
            if suffix == childName {
                entriesByName[childName] = MSPDirectoryEntry(
                    name: childName,
                    info: try photoLibraryTrashFileInfo(atDisplayPath: childPath)
                )
            } else {
                let existingDate = entriesByName[childName]?.info.modificationDate
                let modifiedAt = max(existingDate ?? .distantPast, record.trashedAt)
                entriesByName[childName] = MSPDirectoryEntry(
                    name: childName,
                    info: MSPFileInfo(
                        virtualPath: childPath,
                        type: .directory,
                        size: 0,
                        modificationDate: modifiedAt,
                        permissions: 0o555
                    )
                )
            }
        }

        if normalized == displayRootPath {
            return entriesByName.values.sorted { $0.name < $1.name }
        }
        return entriesByName.values.sorted { $0.name < $1.name }
    }

    func photoLibraryTrashFileInfo(atDisplayPath path: String) throws -> MSPFileInfo {
        let normalized = Self.normalizeVirtualPath(path)
        let overlaySnapshot = workspaceOverlay.snapshot
        guard overlaySnapshot.isTrashDisplayPath(normalized),
              let displayRootPath = overlaySnapshot.trashConfiguration.displayRootPath
        else {
            throw MSPWorkspaceFileSystemError.notFound(normalized)
        }

        if normalized == displayRootPath {
            return MSPFileInfo(
                virtualPath: displayRootPath,
                type: .directory,
                size: 0,
                modificationDate: overlaySnapshot.latestTrashModificationDate,
                permissions: 0o555
            )
        }

        if let trashedAsset = overlaySnapshot.trashAsset(atDisplayPath: normalized) {
            let asset = trashedAsset.assetReference.mountedAsset(at: normalized)
            return MSPFileInfo(
                virtualPath: normalized,
                type: .regularFile,
                size: nil,
                modificationDate: asset.modificationDate ?? asset.creationDate ?? trashedAsset.record.trashedAt,
                permissions: 0o444
            )
        }

        if let trashedAlbum = overlaySnapshot.trashAlbum(atDisplayPath: normalized) {
            return MSPFileInfo(
                virtualPath: normalized,
                type: .directory,
                size: 0,
                modificationDate: trashedAlbum.record.trashedAt,
                permissions: 0o555
            )
        }

        let childRecords = overlaySnapshot.trashRecords.filter {
            overlaySnapshot.trashDisplayPath(for: $0).hasPrefix(normalized + "/")
        }
        guard !childRecords.isEmpty else {
            throw MSPWorkspaceFileSystemError.notFound(normalized)
        }
        return MSPFileInfo(
            virtualPath: normalized,
            type: .directory,
            size: 0,
            modificationDate: childRecords.map(\.trashedAt).max(),
            permissions: 0o555
        )
    }

    func createPendingUserAlbum(at virtualPath: String) throws {
        try workspaceOverlay.createUserAlbum(at: virtualPath)
    }

    @discardableResult
    func removePendingUserAlbum(at virtualPath: String) throws -> Bool {
        try workspaceOverlay.removePendingUserAlbum(at: virtualPath)
    }

    func deleteUserAlbumContainer(at virtualPath: String) throws {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let album = userAlbums().first(where: { $0.virtualPath == normalized }) else {
            throw MSPWorkspaceFileSystemError.notFound(normalized)
        }
        try workspaceOverlay.deleteUserAlbumContainer(album)
    }

    func trashWorkspaceUserAlbum(at virtualPath: String) throws {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let album = userAlbums().first(where: { $0.virtualPath == normalized }) else {
            throw MSPWorkspaceFileSystemError.notFound(normalized)
        }
        let albumAssets = try assets(in: normalized)
        try workspaceOverlay.trashUserAlbum(album, assets: albumAssets)
    }

    func trashWorkspaceAsset(at virtualPath: String) throws {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let asset = try asset(at: normalized) else {
            throw MSPWorkspaceFileSystemError.notFound(normalized)
        }
        try workspaceOverlay.trashAsset(asset, originalPath: normalized)
    }

    @discardableResult
    func trashWorkspaceAssets(at virtualPaths: [String]) throws -> PhotoLibraryWorkspaceTrashBatchSummary {
        let normalizedPaths = virtualPaths.map(Self.normalizeVirtualPath)
        guard !normalizedPaths.isEmpty else {
            return PhotoLibraryWorkspaceTrashBatchSummary(
                requested: 0,
                trashed: 0,
                missingPaths: []
            )
        }

        let snapshot = try currentIndexSnapshot(reason: "读取媒体文件")
        let overlaySnapshot = workspaceOverlay.snapshot
        var assets: [(asset: MountedAsset, originalPath: String)] = []
        var missingPaths: [String] = []
        assets.reserveCapacity(normalizedPaths.count)
        for normalized in normalizedPaths {
            if let asset = overlaySnapshot.effectiveAsset(
                at: normalized,
                baseAsset: snapshot.asset(at: normalized),
                assetResolver: { identifier in
                    Self.mountedAsset(localIdentifier: identifier, from: snapshot)
                }
            ) {
                assets.append((asset: asset, originalPath: normalized))
            } else {
                missingPaths.append(normalized)
            }
        }

        if !assets.isEmpty {
            try workspaceOverlay.trashAssets(assets)
        }
        return PhotoLibraryWorkspaceTrashBatchSummary(
            requested: normalizedPaths.count,
            trashed: assets.count,
            missingPaths: missingPaths
        )
    }

    @discardableResult
    func restoreWorkspaceTrash(
        displayPath: String,
        destinationPath: String? = nil
    ) throws -> MSPWorkspaceTrashRestoreSummary {
        try workspaceOverlay.restoreTrash(
            displayPath: displayPath,
            destinationPath: destinationPath
        )
    }

    func moveWorkspaceAsset(
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        let source = Self.normalizeVirtualPath(sourcePath)
        let destination = Self.normalizeVirtualPath(destinationPath)
        if isPhotoLibraryTrashDisplayPath(source) {
            try restoreWorkspaceTrash(displayPath: source, destinationPath: destination)
            return
        }
        if isPhotoLibraryTrashDisplayPath(destination) {
            try trashWorkspaceAsset(at: source)
            return
        }

        guard let asset = try asset(at: source),
              let sourceParent = Self.parentPath(of: source),
              let destinationParent = Self.parentPath(of: destination)
        else {
            throw MSPWorkspaceFileSystemError.notFound(source)
        }
        guard destination.split(separator: "/").last.map(String.init) == asset.name else {
            throw MSPWorkspaceFileSystemError.accessDenied(destination)
        }
        guard destinationParent == "/图库"
            || destinationParent.hasPrefix(Self.userAlbumRootPath + "/")
        else {
            throw MSPWorkspaceFileSystemError.accessDenied(destination)
        }

        if sourceParent.hasPrefix(Self.userAlbumRootPath + "/"),
           sourceParent != destinationParent {
            try workspaceOverlay.removeAsset(asset, fromAlbumPath: sourceParent)
        }
        if destinationParent.hasPrefix(Self.userAlbumRootPath + "/") {
            let realAlbums = userAlbums()
            guard workspaceOverlay.snapshot.containsUserAlbum(path: destinationParent, realAlbums: realAlbums) else {
                throw MSPWorkspaceFileSystemError.notFound(destinationParent)
            }
            try workspaceOverlay.addAsset(asset, toAlbumPath: destinationParent)
        }
    }

    func copyWorkspaceAsset(
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        let source = Self.normalizeVirtualPath(sourcePath)
        let destination = Self.normalizeVirtualPath(destinationPath)
        guard !isPhotoLibraryTrashDisplayPath(source),
              !isPhotoLibraryTrashDisplayPath(destination)
        else {
            throw MSPWorkspaceFileSystemError.accessDenied(destination)
        }

        guard let destinationParent = Self.parentPath(of: destination)
        else {
            throw MSPWorkspaceFileSystemError.notFound(source)
        }
        guard destinationParent.hasPrefix(Self.userAlbumRootPath + "/") else {
            throw MSPWorkspaceFileSystemError.accessDenied(destination)
        }

        let snapshot = try currentIndexSnapshot(reason: "复制媒体到用户相册")
        let overlaySnapshot = workspaceOverlay.snapshot
        guard let asset = overlaySnapshot.effectiveAsset(
            at: source,
            baseAsset: snapshot.asset(at: source),
            assetResolver: { identifier in
                Self.mountedAsset(localIdentifier: identifier, from: snapshot)
            }
        ) else {
            throw MSPWorkspaceFileSystemError.notFound(source)
        }
        guard destination.split(separator: "/").last.map(String.init) == asset.name else {
            throw MSPWorkspaceFileSystemError.accessDenied(destination)
        }
        guard overlaySnapshot.containsUserAlbum(path: destinationParent, realAlbums: snapshot.userAlbums) else {
            throw MSPWorkspaceFileSystemError.notFound(destinationParent)
        }
        try workspaceOverlay.addAsset(asset, toAlbumPath: destinationParent)
    }

    func copyWorkspaceAssets(_ requests: [WorkspaceAssetCopyRequest]) throws {
        let normalizedRequests = requests.map {
            WorkspaceAssetCopyRequest(
                sourcePath: Self.normalizeVirtualPath($0.sourcePath),
                destinationPath: Self.normalizeVirtualPath($0.destinationPath)
            )
        }
        guard !normalizedRequests.isEmpty else {
            return
        }
        for request in normalizedRequests {
            guard !isPhotoLibraryTrashDisplayPath(request.sourcePath),
                  !isPhotoLibraryTrashDisplayPath(request.destinationPath)
            else {
                throw MSPWorkspaceFileSystemError.accessDenied(request.destinationPath)
            }
        }

        let snapshot = try currentIndexSnapshot(reason: "复制媒体到用户相册")
        let overlaySnapshot = workspaceOverlay.snapshot
        let realAlbums = snapshot.userAlbums
        var assetsByAlbumPath: [String: [MountedAsset]] = [:]
        assetsByAlbumPath.reserveCapacity(1)

        for request in normalizedRequests {
            guard let asset = overlaySnapshot.effectiveAsset(
                at: request.sourcePath,
                baseAsset: snapshot.asset(at: request.sourcePath),
                assetResolver: { identifier in
                    Self.mountedAsset(localIdentifier: identifier, from: snapshot)
                }
            ), let destinationParent = Self.parentPath(of: request.destinationPath)
            else {
                throw MSPWorkspaceFileSystemError.notFound(request.sourcePath)
            }
            guard request.destinationPath.split(separator: "/").last.map(String.init) == asset.name else {
                throw MSPWorkspaceFileSystemError.accessDenied(request.destinationPath)
            }
            guard destinationParent.hasPrefix(Self.userAlbumRootPath + "/") else {
                throw MSPWorkspaceFileSystemError.accessDenied(request.destinationPath)
            }
            guard overlaySnapshot.containsUserAlbum(path: destinationParent, realAlbums: realAlbums) else {
                throw MSPWorkspaceFileSystemError.notFound(destinationParent)
            }
            assetsByAlbumPath[destinationParent, default: []].append(asset)
        }

        for albumPath in assetsByAlbumPath.keys.sorted() {
            try workspaceOverlay.addAssets(assetsByAlbumPath[albumPath] ?? [], toAlbumPath: albumPath)
        }
    }

    func addWorkspaceAssets(
        at assetPaths: [String],
        toUserAlbumPath albumPath: String,
        createAlbumIfNeeded: Bool
    ) throws -> PhotoSorterAlbumAddSummary {
        try withForegroundPhotoLibraryActivity {
            let normalizedAlbumPath = Self.normalizeVirtualPath(albumPath)
            guard Self.parentPath(of: normalizedAlbumPath) == Self.userAlbumRootPath else {
                throw MSPWorkspaceFileSystemError.accessDenied(normalizedAlbumPath)
            }

            let snapshot = try currentIndexSnapshot(reason: "加入用户相册")
            let realAlbums = snapshot.userAlbums
            if !workspaceOverlay.snapshot.containsUserAlbum(path: normalizedAlbumPath, realAlbums: realAlbums) {
                guard createAlbumIfNeeded else {
                    throw MSPWorkspaceFileSystemError.notFound(normalizedAlbumPath)
                }
                try workspaceOverlay.createUserAlbum(at: normalizedAlbumPath)
            }

            let overlaySnapshot = workspaceOverlay.snapshot
            guard overlaySnapshot.containsUserAlbum(path: normalizedAlbumPath, realAlbums: realAlbums) else {
                throw MSPWorkspaceFileSystemError.notFound(normalizedAlbumPath)
            }

            let existingAssetIdentifiers = Set(effectiveSnapshotAssets(
                in: normalizedAlbumPath,
                offset: 0,
                limit: nil,
                snapshot: snapshot
            ).map(\.localIdentifier))

            var assetsToAdd: [MountedAsset] = []
            assetsToAdd.reserveCapacity(assetPaths.count)
            var seenAssetIdentifiers = Set<String>()
            var skippedExisting = 0

            for rawAssetPath in assetPaths {
                let assetPath = Self.normalizeVirtualPath(rawAssetPath)
                guard let asset = overlaySnapshot.effectiveAsset(
                    at: assetPath,
                    baseAsset: snapshot.asset(at: assetPath),
                    assetResolver: { identifier in
                        Self.mountedAsset(localIdentifier: identifier, from: snapshot)
                    }
                ) else {
                    throw MSPWorkspaceFileSystemError.notFound(assetPath)
                }

                guard !existingAssetIdentifiers.contains(asset.localIdentifier),
                      seenAssetIdentifiers.insert(asset.localIdentifier).inserted
                else {
                    skippedExisting += 1
                    continue
                }
                assetsToAdd.append(asset)
            }

            try workspaceOverlay.addAssets(assetsToAdd, toAlbumPath: normalizedAlbumPath)
            return PhotoSorterAlbumAddSummary(
                requested: assetPaths.count,
                added: assetsToAdd.count,
                skippedExisting: skippedExisting
            )
        }
    }

    func removeWorkspaceAssets(
        at assetPaths: [String],
        fromUserAlbumPath albumPath: String
    ) throws -> PhotoSorterAlbumRemoveSummary {
        try withForegroundPhotoLibraryActivity {
            let normalizedAlbumPath = Self.normalizeVirtualPath(albumPath)
            guard Self.parentPath(of: normalizedAlbumPath) == Self.userAlbumRootPath else {
                throw MSPWorkspaceFileSystemError.accessDenied(normalizedAlbumPath)
            }

            let snapshot = try currentIndexSnapshot(reason: "移出用户相册")
            let realAlbums = snapshot.userAlbums
            let overlaySnapshot = workspaceOverlay.snapshot
            guard overlaySnapshot.containsUserAlbum(path: normalizedAlbumPath, realAlbums: realAlbums) else {
                throw MSPWorkspaceFileSystemError.notFound(normalizedAlbumPath)
            }

            let existingAssetIdentifiers = Set(effectiveSnapshotAssets(
                in: normalizedAlbumPath,
                offset: 0,
                limit: nil,
                snapshot: snapshot
            ).map(\.localIdentifier))

            var assetsToRemove: [MountedAsset] = []
            assetsToRemove.reserveCapacity(assetPaths.count)
            var seenAssetIdentifiers = Set<String>()
            var skippedNotInAlbum = 0

            for rawAssetPath in assetPaths {
                let assetPath = Self.normalizeVirtualPath(rawAssetPath)
                guard let asset = overlaySnapshot.effectiveAsset(
                    at: assetPath,
                    baseAsset: snapshot.asset(at: assetPath),
                    assetResolver: { identifier in
                        Self.mountedAsset(localIdentifier: identifier, from: snapshot)
                    }
                ) else {
                    throw MSPWorkspaceFileSystemError.notFound(assetPath)
                }

                guard existingAssetIdentifiers.contains(asset.localIdentifier),
                      seenAssetIdentifiers.insert(asset.localIdentifier).inserted
                else {
                    skippedNotInAlbum += 1
                    continue
                }
                assetsToRemove.append(asset)
            }

            try workspaceOverlay.removeAssets(assetsToRemove, fromAlbumPath: normalizedAlbumPath)
            return PhotoSorterAlbumRemoveSummary(
                requested: assetPaths.count,
                removed: assetsToRemove.count,
                skippedNotInAlbum: skippedNotInAlbum
            )
        }
    }

    func photoLibraryWorkspaceSyncChangeSet() throws -> PhotoLibraryWorkspaceSyncChangeSet {
        let realSnapshot = try currentIndexSnapshot(reason: "同步工作区变更")
        let overlaySnapshot = workspaceOverlay.snapshot
        let realAssetIdentifiers = Set(realSnapshot.assetsByLocalIdentifier.keys)
        let realAlbumsByPath = Dictionary(uniqueKeysWithValues: realSnapshot.userAlbums.map {
            ($0.virtualPath, $0)
        })
        let deletedAlbumReferences = (overlaySnapshot.deletedUserAlbumReferences
            + overlaySnapshot.trashedAlbums.map(\.albumReference))
            .sorted { $0.virtualPath < $1.virtualPath }
        let deletedAlbumPaths = Set(deletedAlbumReferences.map(\.virtualPath))
        let pendingAlbumPaths = Set(overlaySnapshot.pendingUserAlbums.map(\.virtualPath))
            .subtracting(deletedAlbumPaths)
        var conflicts: [PhotoLibraryWorkspaceSyncConflict] = []

        func appendMissingAssetConflicts(
            _ identifiers: [String],
            action: String
        ) -> [String] {
            var validIdentifiers: [String] = []
            for identifier in identifiers {
                if realAssetIdentifiers.contains(identifier) {
                    validIdentifiers.append(identifier)
                } else {
                    conflicts.append(PhotoLibraryWorkspaceSyncConflict(
                        id: "\(action):missing-asset:\(identifier)",
                        message: "\(action)失败：系统相册里已找不到照片 \(identifier)"
                    ))
                }
            }
            return validIdentifiers
        }

        let createdAlbums = overlaySnapshot.pendingUserAlbums.compactMap { album -> PhotoLibraryWorkspaceSyncAlbumCreation? in
            guard !deletedAlbumPaths.contains(album.virtualPath) else {
                return nil
            }
            guard realAlbumsByPath[album.virtualPath] == nil else {
                return nil
            }
            return PhotoLibraryWorkspaceSyncAlbumCreation(name: album.name, virtualPath: album.virtualPath)
        }
        var seenDeletedAlbumPaths = Set<String>()
        let deletedAlbums = deletedAlbumReferences.compactMap { reference -> PhotoLibraryWorkspaceSyncAlbumDeletion? in
            guard seenDeletedAlbumPaths.insert(reference.virtualPath).inserted else {
                return nil
            }
            if let realAlbum = realAlbumsByPath[reference.virtualPath] {
                return PhotoLibraryWorkspaceSyncAlbumDeletion(
                    albumVirtualPath: reference.virtualPath,
                    albumLocalIdentifier: realAlbum.localIdentifier
                )
            }
            guard reference.localIdentifier != nil else {
                return nil
            }
            conflicts.append(PhotoLibraryWorkspaceSyncConflict(
                id: "album-deletion:missing-album:\(reference.virtualPath)",
                message: "删除相册失败：系统相册里已找不到相册 \(reference.virtualPath)"
            ))
            return nil
        }
        let additions = overlaySnapshot.albumMembershipAdditionsByPath().compactMap { entry -> PhotoLibraryWorkspaceSyncAlbumMembershipChange? in
            let albumPath = entry.key
            guard !deletedAlbumPaths.contains(albumPath) else {
                return nil
            }
            let identifiers = appendMissingAssetConflicts(entry.value, action: "加入相册 \(albumPath)")
            guard !identifiers.isEmpty else {
                return nil
            }
            guard realAlbumsByPath[albumPath] != nil || pendingAlbumPaths.contains(albumPath) else {
                conflicts.append(PhotoLibraryWorkspaceSyncConflict(
                    id: "membership-addition:missing-album:\(albumPath)",
                    message: "加入相册失败：找不到目标相册 \(albumPath)"
                ))
                return nil
            }
            return PhotoLibraryWorkspaceSyncAlbumMembershipChange(
                albumVirtualPath: albumPath,
                albumLocalIdentifier: realAlbumsByPath[albumPath]?.localIdentifier,
                assetLocalIdentifiers: identifiers
            )
        }
        let removals = overlaySnapshot.albumMembershipRemovalsByPath().compactMap { entry -> PhotoLibraryWorkspaceSyncAlbumMembershipChange? in
            let albumPath = entry.key
            guard !deletedAlbumPaths.contains(albumPath) else {
                return nil
            }
            let identifiers = appendMissingAssetConflicts(entry.value, action: "移出相册 \(albumPath)")
            guard !identifiers.isEmpty else {
                return nil
            }
            guard let album = realAlbumsByPath[albumPath] else {
                if !pendingAlbumPaths.contains(albumPath) {
                    conflicts.append(PhotoLibraryWorkspaceSyncConflict(
                        id: "membership-removal:missing-album:\(albumPath)",
                        message: "移出相册失败：找不到目标相册 \(albumPath)"
                    ))
                }
                return nil
            }
            return PhotoLibraryWorkspaceSyncAlbumMembershipChange(
                albumVirtualPath: albumPath,
                albumLocalIdentifier: album.localIdentifier,
                assetLocalIdentifiers: identifiers
            )
        }
        let trashedAssetLocalIdentifiers = appendMissingAssetConflicts(
            Array(overlaySnapshot.trashedAssetLocalIdentifiers).sorted(),
            action: "删除照片"
        )

        return PhotoLibraryWorkspaceSyncChangeSet(
            trashedAssetLocalIdentifiers: trashedAssetLocalIdentifiers,
            createdAlbums: createdAlbums.sorted { $0.virtualPath < $1.virtualPath },
            deletedAlbums: deletedAlbums.sorted { $0.albumVirtualPath < $1.albumVirtualPath },
            membershipAdditions: additions.sorted { $0.albumVirtualPath < $1.albumVirtualPath },
            membershipRemovals: removals.sorted { $0.albumVirtualPath < $1.albumVirtualPath },
            conflicts: conflicts.sorted { $0.id < $1.id }
        )
    }

    func preparePhotoLibraryWorkspaceSyncChangeSet() async throws -> PhotoLibraryWorkspaceSyncChangeSet {
        try withForegroundPhotoLibraryActivity {
            try photoLibraryWorkspaceSyncChangeSet()
        }
    }

    func applyPendingWorkspaceChangesToPhotoLibrary() async throws {
        try await withForegroundPhotoLibraryActivity {
            let changeSet = try photoLibraryWorkspaceSyncChangeSet()
            guard !changeSet.hasConflicts else {
                throw PhotoLibraryWorkspaceSyncConflictError(conflicts: changeSet.conflicts)
            }
            guard !changeSet.isEmpty else {
                return
            }
            try await manifestProvider.applyWorkspaceChanges(changeSet)
            try workspaceOverlay.clear()
            markPhotoLibraryIndexDirty(reason: "工作区变更已同步到系统相册")
            startPhotoLibraryIndexRefresh(reason: "刷新已同步的工作区变更")
        }
    }

    func cachedPlace(for mountedAsset: MountedAsset) -> String? {
        guard Self.hasLocation(mountedAsset) else {
            return nil
        }
        return placeCache.place(
            localIdentifier: mountedAsset.localIdentifier,
            locationVersion: Self.placeLocationVersion(for: mountedAsset)
        )
    }

    func preview(
        for virtualPath: String,
        targetSize: CGSize = CGSize(width: 1600, height: 1600),
        timeout: TimeInterval = 20
    ) async -> PreviewResult {
        let mountedAsset: MountedAsset
        guard let asset = presentationAsset(at: virtualPath) else {
            return .unavailable("找不到这个媒体文件。")
        }
        mountedAsset = asset
        guard let previewKind = Self.mediaPreviewKind(for: mountedAsset) else {
            return .unsupported("这个媒体类型暂时无法预览。")
        }
        guard previewKind == .image else {
            return .media(await mediaPreview(
                for: mountedAsset,
                kind: previewKind,
                targetSize: targetSize
            ))
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [mountedAsset.localIdentifier],
            options: nil
        ).firstObject else {
            return .unavailable("找不到这个媒体文件。")
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact

        let safeTargetSize = Self.previewImageTargetSize(
            for: mountedAsset,
            requestedTargetSize: targetSize
        )

        return await withCheckedContinuation { continuation in
            let state = PhotoSorterMediaImageRequestState()
            let timeoutWorkItem = DispatchWorkItem {
                guard let resume = state.markResumed() else {
                    return
                }
                if let requestID = resume.requestID {
                    self.imageManager.cancelImageRequest(requestID)
                }
                continuation.resume(returning: .unavailable("这张照片的本地预览暂时不可用。"))
            }
            state.setTimeoutWorkItem(timeoutWorkItem)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + max(timeout, 0.1),
                execute: timeoutWorkItem
            )

            let requestID = self.imageManager.requestImage(
                for: asset,
                targetSize: safeTargetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isCancelled = info?[PHImageCancelledKey] as? Bool ?? false
                if let error = info?[PHImageErrorKey] as? Error {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(returning: .unavailable(error.localizedDescription))
                    return
                }
                if isCancelled {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(returning: .unavailable("本地高清预览请求已取消。"))
                    return
                }
                guard !Self.imageRequestResultIsDegraded(info) else {
                    return
                }
                guard let image else {
                    guard state.markResumed() != nil else {
                        return
                    }
                    let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                    let message = isInCloud
                        ? "这张照片的本地高清预览暂时不可用。"
                        : "无法读取高清照片预览。"
                    continuation.resume(returning: .unavailable(message))
                    return
                }
                guard let data = WorkspaceFileThumbnailEncoder.data(from: image) else {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(returning: .unavailable("无法编码高清照片预览。"))
                    return
                }

                guard let resume = state.markResumed() else {
                    return
                }
                if let requestID = resume.requestID {
                    self.imageManager.cancelImageRequest(requestID)
                }
                continuation.resume(returning: .image(data, fileName: mountedAsset.name))
            }
            if state.setRequestID(requestID) {
                self.imageManager.cancelImageRequest(requestID)
            }
        }
    }

    static func previewImageTargetSize(
        for asset: MountedAsset,
        requestedTargetSize: CGSize = CGSize(width: 1600, height: 1600)
    ) -> CGSize {
        let requestedMaximumDimension = Int(max(
            requestedTargetSize.width,
            requestedTargetSize.height
        ).rounded(.up))
        return PhotoSorterModelImageSizing.targetSize(
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            preferredMaximumPixelDimension: max(
                requestedMaximumDimension,
                PhotoSorterModelImageSizing.preferredMaximumPixelDimension
            )
        )
    }

    private func mediaPreview(
        for mountedAsset: MountedAsset,
        kind: PhotoSorterMediaPreviewKind,
        targetSize: CGSize,
        thumbnailData: Data? = nil
    ) async -> PhotoSorterMediaPreview {
        let resolvedThumbnailData: Data?
        if let thumbnailData {
            resolvedThumbnailData = thumbnailData
        } else {
            resolvedThumbnailData = await thumbnail(
                for: mountedAsset.virtualPath,
                targetSize: targetSize,
                allowsNetworkAccess: true
            )?.data
        }
        return PhotoSorterMediaPreview(
            path: mountedAsset.virtualPath,
            fileName: mountedAsset.name,
            kind: kind,
            pixelWidth: mountedAsset.pixelWidth,
            pixelHeight: mountedAsset.pixelHeight,
            thumbnailData: resolvedThumbnailData,
            photoLibraryLocalIdentifier: mountedAsset.localIdentifier,
            fileURL: nil
        )
    }

    private static func mediaPreviewKind(for asset: MountedAsset) -> PhotoSorterMediaPreviewKind? {
        switch asset.mediaType {
        case .image:
            return asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .image
        case .video:
            return .video
        default:
            return nil
        }
    }

    func thumbnail(
        for virtualPath: String,
        targetSize: CGSize = CGSize(width: 64, height: 64),
        allowsNetworkAccess: Bool = false
    ) async -> WorkspaceFileThumbnail? {
        guard let mountedAsset = presentationAsset(at: virtualPath),
              mountedAsset.mediaType == .image || mountedAsset.mediaType == .video
        else {
            return nil
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [mountedAsset.localIdentifier],
            options: nil
        ).firstObject else {
            return nil
        }

#if canImport(UIKit) || canImport(AppKit)
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.resizeMode = .fast

        let safeTargetSize = CGSize(
            width: max(targetSize.width, 1),
            height: max(targetSize.height, 1)
        )

        return await withCheckedContinuation { continuation in
            var didResume = false
            var latestThumbnail: WorkspaceFileThumbnail?
            self.imageManager.requestImage(
                for: asset,
                targetSize: safeTargetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !didResume else {
                    return
                }

                if let image,
                   let data = WorkspaceFileThumbnailEncoder.data(from: image) {
                    latestThumbnail = WorkspaceFileThumbnail(data: data)
                }

                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let isCancelled = info?[PHImageCancelledKey] as? Bool ?? false
                let error = info?[PHImageErrorKey] as? Error
                guard !isDegraded || isCancelled || error != nil else {
                    return
                }

                didResume = true
                continuation.resume(returning: latestThumbnail)
            }
        }
#else
        return nil
#endif
    }

    func startOCRCachePreheatBatch(limit: Int? = nil) {
        let normalizedLimit = limit.map { max(0, $0) }
        if normalizedLimit == 0 {
            return
        }
        guard let snapshot = index.cachedSnapshotForStatus() else {
            setOCRPreheatState(PhotoSorterMediaOCRPreheatState(
                isRunning: false,
                isPaused: false,
                processed: 0,
                limit: normalizedLimit ?? 0,
                message: "暂无照片库缓存"
            ))
            return
        }
        ocrPreheatCondition.lock()
        guard !ocrPreheatState.isRunning, !ocrPreheatState.isPaused else {
            ocrPreheatCondition.unlock()
            return
        }
        ocrPreheatState = PhotoSorterMediaOCRPreheatState(
            isRunning: true,
            isPaused: false,
            processed: 0,
            limit: normalizedLimit ?? 0,
            message: "准备 OCR 缓存"
        )
        ocrPreheatCondition.broadcast()
        ocrPreheatCondition.unlock()

        Task.detached(priority: .utility) { [weak self] in
            await self?.runOCRCachePreheatBatch(limit: normalizedLimit, snapshot: snapshot)
        }
    }

    func pauseOCRCachePreheat() {
        ocrPreheatCondition.lock()
        guard ocrPreheatState.isRunning else {
            ocrPreheatCondition.unlock()
            return
        }
        ocrPreheatState.isRunning = false
        ocrPreheatState.isPaused = true
        ocrPreheatState.message = ocrPreheatProgressMessage(
            prefix: "OCR 缓存已暂停",
            processed: ocrPreheatState.processed,
            limit: ocrPreheatState.limit
        )
        ocrPreheatCondition.broadcast()
        ocrPreheatCondition.unlock()
        try? ocrCache.flush()
    }

    func resumeOCRCachePreheat() {
        ocrPreheatCondition.lock()
        guard ocrPreheatState.isPaused else {
            ocrPreheatCondition.unlock()
            return
        }
        ocrPreheatState.isRunning = true
        ocrPreheatState.isPaused = false
        ocrPreheatState.message = ocrPreheatProgressMessage(
            prefix: "继续 OCR 缓存",
            processed: ocrPreheatState.processed,
            limit: ocrPreheatState.limit
        )
        ocrPreheatCondition.broadcast()
        ocrPreheatCondition.unlock()
    }

    func startVLMSummaryCachePreheatBatch(
        limit: Int? = PhotoLibraryMount.defaultVLMSummaryPreheatBatchLimit
    ) {
        let normalizedLimit = limit.map { max(0, $0) }
        if normalizedLimit == 0 {
            return
        }
        guard let snapshot = index.cachedSnapshotForStatus() else {
            setVLMPreheatState(PhotoSorterMediaVLMPreheatState(
                isRunning: false,
                isPaused: false,
                isWaitingForForeground: false,
                processed: 0,
                limit: normalizedLimit ?? 0,
                failed: 0,
                skipped: 0,
                message: "暂无照片库缓存"
            ))
            return
        }
        let providerStatus = currentVLMProviderStatus()
        guard providerStatus.isLiveSummarizationAvailable else {
            setVLMPreheatState(PhotoSorterMediaVLMPreheatState(
                isRunning: false,
                isPaused: false,
                isWaitingForForeground: false,
                processed: 0,
                limit: normalizedLimit ?? 0,
                failed: 0,
                skipped: 0,
                message: providerStatus.reason ?? "本地 FastVLM 当前不可用"
            ))
            return
        }
        vlmPreheatCondition.lock()
        guard !vlmPreheatState.isRunning,
              !vlmPreheatState.isPaused,
              !vlmPreheatState.isWaitingForForeground
        else {
            vlmPreheatCondition.unlock()
            return
        }
        let startsInForeground = vlmForegroundInferenceAllowed
        vlmPreheatState = PhotoSorterMediaVLMPreheatState(
            isRunning: startsInForeground,
            isPaused: false,
            isWaitingForForeground: !startsInForeground,
            processed: 0,
            limit: normalizedLimit ?? 0,
            failed: 0,
            skipped: 0,
            message: startsInForeground
                ? "准备视觉摘要缓存"
                : "等待前台继续视觉摘要"
        )
        vlmPreheatCondition.broadcast()
        vlmPreheatCondition.unlock()

        Task.detached(priority: .utility) { [weak self] in
            await self?.runVLMSummaryCachePreheatBatch(
                limit: normalizedLimit,
                snapshot: snapshot
            )
        }
    }

    func pauseVLMSummaryCachePreheat() {
        vlmPreheatCondition.lock()
        guard vlmPreheatState.isRunning || vlmPreheatState.isWaitingForForeground else {
            vlmPreheatCondition.unlock()
            return
        }
        vlmPreheatState.isRunning = false
        vlmPreheatState.isPaused = true
        vlmPreheatState.isWaitingForForeground = false
        vlmPreheatState.message = vlmPreheatProgressMessage(
            prefix: "视觉摘要缓存已暂停",
            processed: vlmPreheatState.processed,
            limit: vlmPreheatState.limit
        )
        vlmPreheatCondition.broadcast()
        vlmPreheatCondition.unlock()
        try? vlmSummaryCache.flush()
    }

    func resumeVLMSummaryCachePreheat() {
        vlmPreheatCondition.lock()
        guard vlmPreheatState.isPaused else {
            vlmPreheatCondition.unlock()
            return
        }
        let canRunNow = vlmForegroundInferenceAllowed
        vlmPreheatState.isRunning = canRunNow
        vlmPreheatState.isPaused = false
        vlmPreheatState.isWaitingForForeground = !canRunNow
        vlmPreheatState.message = vlmPreheatProgressMessage(
            prefix: canRunNow ? "继续视觉摘要缓存" : "等待前台继续视觉摘要",
            processed: vlmPreheatState.processed,
            limit: vlmPreheatState.limit
        )
        vlmPreheatCondition.broadcast()
        vlmPreheatCondition.unlock()
    }

    @discardableResult
    func setVLMSummaryInferenceForegroundAllowed(_ allowed: Bool) -> Bool {
        vlmPreheatCondition.lock()
        defer {
            vlmPreheatCondition.broadcast()
            vlmPreheatCondition.unlock()
        }
        guard vlmForegroundInferenceAllowed != allowed else {
            return false
        }
        vlmForegroundInferenceAllowed = allowed
        if !allowed {
            vlmForegroundBackgroundTransitionGeneration &+= 1
        }
        guard !vlmPreheatState.isPaused else {
            return true
        }
        if !allowed, vlmPreheatState.isRunning {
            vlmPreheatState.isRunning = false
            vlmPreheatState.isWaitingForForeground = true
            vlmPreheatState.message = vlmPreheatProgressMessage(
                prefix: "等待前台继续视觉摘要",
                processed: vlmPreheatState.processed,
                limit: vlmPreheatState.limit
            )
            return true
        }
        if allowed, vlmPreheatState.isWaitingForForeground {
            vlmPreheatState.isRunning = true
            vlmPreheatState.isWaitingForForeground = false
            vlmPreheatState.message = vlmPreheatProgressMessage(
                prefix: "继续视觉摘要缓存",
                processed: vlmPreheatState.processed,
                limit: vlmPreheatState.limit
            )
        }
        return true
    }

    func startPlaceCachePreheatBatch(limit: Int? = nil) {
        let normalizedLimit = limit.map { max(0, $0) }
        if normalizedLimit == 0 {
            return
        }
        guard let snapshot = index.cachedSnapshotForStatus() else {
            setPlacePreheatState(PhotoSorterMediaPlacePreheatState(
                isRunning: false,
                isPaused: false,
                hasActiveTask: false,
                processed: 0,
                limit: normalizedLimit ?? 0,
                message: "暂无照片库缓存"
            ))
            return
        }
        placePreheatCondition.lock()
        guard !placePreheatState.isRunning,
              !(placePreheatState.isPaused && placePreheatState.hasActiveTask)
        else {
            placePreheatCondition.unlock()
            return
        }
        placePreheatState = PhotoSorterMediaPlacePreheatState(
            isRunning: true,
            isPaused: false,
            hasActiveTask: true,
            processed: 0,
            limit: normalizedLimit ?? 0,
            message: "准备地点缓存"
        )
        placePreheatCondition.broadcast()
        placePreheatCondition.unlock()

        Task.detached(priority: .utility) { [weak self] in
            await self?.runPlaceCachePreheatBatch(limit: normalizedLimit, snapshot: snapshot)
        }
    }

    func pausePlaceCachePreheat() {
        placePreheatCondition.lock()
        let hasActiveTask = placePreheatState.hasActiveTask
        placePreheatState = PhotoSorterMediaPlacePreheatState(
            isRunning: false,
            isPaused: true,
            hasActiveTask: hasActiveTask,
            processed: placePreheatState.processed,
            limit: placePreheatState.limit,
            message: placePreheatProgressMessage(
                prefix: "地点缓存已暂停",
                processed: placePreheatState.processed,
                limit: placePreheatState.limit
            )
        )
        placePreheatCondition.broadcast()
        placePreheatCondition.unlock()
        try? placeCache.flush()
    }

    @discardableResult
    func resumePlaceCachePreheat() -> Bool {
        placePreheatCondition.lock()
        guard placePreheatState.isPaused else {
            placePreheatCondition.unlock()
            return false
        }
        let hasActiveTask = placePreheatState.hasActiveTask
        if hasActiveTask {
            placePreheatState.isRunning = true
            placePreheatState.isPaused = false
            placePreheatState.message = placePreheatProgressMessage(
                prefix: "继续地点缓存",
                processed: placePreheatState.processed,
                limit: placePreheatState.limit
            )
        } else {
            placePreheatState = .idle
        }
        placePreheatCondition.broadcast()
        placePreheatCondition.unlock()
        return hasActiveTask
    }

    func currentIndexSnapshot(reason: String) throws -> PhotoLibraryIndexSnapshot {
        waitForPhotoLibraryChangeNotificationProcessing()
        let startedAt = Date()
        let startStatus = index.currentStatus
        do {
            let snapshot = try index.snapshot(reason: reason) { [self] previousSnapshot, progress in
                try resolveIndexSnapshot(previousSnapshot: previousSnapshot, progress: progress)
            }
            let endStatus = index.currentStatus
            recordIndexDiagnostic(
                "photo_library_index_snapshot_request",
                fields: indexSnapshotRequestFields(
                    reason: reason,
                    startedAt: startedAt,
                    startStatus: startStatus,
                    endStatus: endStatus,
                    result: "success"
                )
            )
            return snapshot
        } catch {
            let endStatus = index.currentStatus
            var fields = indexSnapshotRequestFields(
                reason: reason,
                startedAt: startedAt,
                startStatus: startStatus,
                endStatus: endStatus,
                result: "failure"
            )
            fields["error"] = error.localizedDescription
            recordIndexDiagnostic("photo_library_index_snapshot_request", fields: fields)
            throw error
        }
    }

    private func resolveIndexSnapshot(
        previousSnapshot: PhotoLibraryIndexSnapshot?,
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void
    ) throws -> PhotoLibraryIndexBuildOutcome {
        let startedAt = Date()
        if let previousSnapshot,
           let persistentOutcome = try resolveIndexSnapshotFromPersistentChanges(
            previousSnapshot: previousSnapshot,
            startedAt: startedAt,
            progress: progress
           ) {
            return persistentOutcome
        }

        let scan = manifestProvider.makeManifest(
            progress: progress,
            hasPreviousSnapshot: previousSnapshot != nil
        )
        let summary = previousSnapshot.map {
            PhotoLibraryManifestChangeSummary(previousSnapshot: $0, scan: scan)
        }

        if let previousSnapshot,
           let summary,
           !summary.hasChanges {
            let diagnostics = scan.diagnosticsFields(
                mode: .verifiedCacheHit,
                summary: summary,
                startedAt: startedAt
            )
            recordIndexDiagnostic("photo_library_index_verified_cache_hit", fields: diagnostics)
            return PhotoLibraryIndexBuildOutcome(
                snapshot: previousSnapshot,
                mode: .verifiedCacheHit,
                diagnostics: diagnostics
            )
        }

        let snapshot = try makeIndexSnapshot(
            from: scan,
            previousSnapshot: previousSnapshot
        )
        let mode: PhotoLibraryIndexUpdateMode = previousSnapshot == nil
            ? .fullRebuild
            : .incrementalRefresh
        let diagnostics = scan.diagnosticsFields(
            mode: mode,
            summary: summary,
            startedAt: startedAt
        )
        recordIndexDiagnostic(
            mode == .fullRebuild
                ? "photo_library_index_full_rebuild"
                : "photo_library_index_incremental_refresh",
            fields: diagnostics
        )
        return PhotoLibraryIndexBuildOutcome(
            snapshot: snapshot,
            mode: mode,
            diagnostics: diagnostics
        )
    }

    private func makeIndexSnapshot(
        from scan: PhotoLibraryManifestScan,
        previousSnapshot _: PhotoLibraryIndexSnapshot?
    ) throws -> PhotoLibraryIndexSnapshot {
        let orderedAssetRecords = scan.orderedUniqueAssetRecords()
        let fileNamesByLocalIdentifier = Self.assetFileNames(for: orderedAssetRecords)
        var assetsByLocalIdentifier: [String: PhotoLibraryIndexAsset] = [:]
        assetsByLocalIdentifier.reserveCapacity(scan.assetRecords.count)

        for record in orderedAssetRecords {
            guard let fileName = fileNamesByLocalIdentifier[record.localIdentifier] else {
                continue
            }
            assetsByLocalIdentifier[record.localIdentifier] = PhotoLibraryIndexAsset(
                localIdentifier: record.localIdentifier,
                fileName: fileName,
                fileExtension: record.fileExtension,
                mediaTypeRawValue: record.mediaTypeRawValue,
                mediaSubtypesRawValue: record.mediaSubtypesRawValue,
                pixelWidth: record.pixelWidth,
                pixelHeight: record.pixelHeight,
                creationDate: record.creationDate,
                modificationDate: record.modificationDate,
                locationLatitude: record.locationLatitude,
                locationLongitude: record.locationLongitude,
                locationHorizontalAccuracy: record.locationHorizontalAccuracy
            )
        }

        return PhotoLibraryIndexSnapshot.make(
            authorizationStatusRawValue: scan.authorizationStatusRawValue,
            libraryScopeFingerprint: scan.libraryScopeFingerprint,
            version: photoLibraryIndexStatus.version,
            directories: scan.directories,
            assetsByLocalIdentifier: assetsByLocalIdentifier,
            photoLibraryChangeTokenData: manifestProvider.currentPhotoLibraryChangeTokenData()
        )
    }

    private static func mountedAssets(
        from records: [PhotoLibraryManifestAssetRecord],
        in virtualDirectoryPath: String
    ) -> [MountedAsset] {
        let normalizedDirectory = normalizeVirtualPath(virtualDirectoryPath)
        let fileNamesByLocalIdentifier = assetFileNames(for: records)
        return records.compactMap { record in
            guard let fileName = fileNamesByLocalIdentifier[record.localIdentifier] else {
                return nil
            }
            let name = sanitizedPathComponent(fileName)
            return MountedAsset(
                name: name,
                virtualPath: join(normalizedDirectory, name),
                localIdentifier: record.localIdentifier,
                mediaType: PHAssetMediaType(rawValue: record.mediaTypeRawValue) ?? .unknown,
                mediaSubtypes: PHAssetMediaSubtype(rawValue: record.mediaSubtypesRawValue),
                pixelWidth: record.pixelWidth,
                pixelHeight: record.pixelHeight,
                creationDate: record.creationDate,
                modificationDate: record.modificationDate,
                locationLatitude: record.locationLatitude,
                locationLongitude: record.locationLongitude,
                locationHorizontalAccuracy: record.locationHorizontalAccuracy
            )
        }
    }

    private static func mountedAssetDirectoryEntry(
        _ asset: PhotoLibraryIndexAsset,
        in virtualDirectoryPath: String
    ) -> MountedAssetDirectoryEntry {
        let normalizedDirectory = normalizeVirtualPath(virtualDirectoryPath)
        let name = sanitizedPathComponent(asset.fileName)
        return MountedAssetDirectoryEntry(
            name: name,
            virtualPath: join(normalizedDirectory, name),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate
        )
    }

    private static func mountedAssetDirectoryEntry(
        _ asset: MountedAsset
    ) -> MountedAssetDirectoryEntry {
        MountedAssetDirectoryEntry(
            name: asset.name,
            virtualPath: asset.virtualPath,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate
        )
    }

    static func mountedAsset(
        localIdentifier: String,
        from snapshot: PhotoLibraryIndexSnapshot
    ) -> MountedAsset? {
        snapshot.assetsByLocalIdentifier[localIdentifier]?.mountedAsset(in: "/图库")
    }

    private func presentationAssetReference(localIdentifier: String) -> MountedAsset? {
        if let snapshot = index.cachedSnapshotForStatus(),
           let asset = Self.mountedAsset(localIdentifier: localIdentifier, from: snapshot) {
            return asset
        }

        presentationAssetCacheLock.lock()
        defer {
            presentationAssetCacheLock.unlock()
        }
        return presentationAssetByVirtualPath.values.first {
            $0.localIdentifier == localIdentifier
        }
    }

    private func rememberPresentationAssets(_ mountedAssets: [MountedAsset]) {
        guard !mountedAssets.isEmpty else {
            return
        }
        presentationAssetCacheLock.lock()
        for mountedAsset in mountedAssets {
            presentationAssetByVirtualPath[Self.normalizeVirtualPath(mountedAsset.virtualPath)] = mountedAsset
        }
        presentationAssetCacheLock.unlock()
    }

    private func verifyUpdatedAssetChangesDoNotAffectIndex(
        previousSnapshot: PhotoLibraryIndexSnapshot,
        changes: PhotoLibraryPersistentChangeSummary
    ) -> PhotoLibraryUpdatedAssetChangeVerification? {
        guard changes.hasOnlyUpdatedAssetChanges else {
            return nil
        }
        let updatedIdentifiers = changes.updatedAssetLocalIdentifiers
        guard updatedIdentifiers.allSatisfy({ previousSnapshot.assetsByLocalIdentifier[$0] != nil }) else {
            return nil
        }

        let freshRecords = manifestProvider.manifestAssetRecords(for: updatedIdentifiers)
        guard freshRecords.count == updatedIdentifiers.count else {
            return nil
        }
        for identifier in updatedIdentifiers {
            guard let indexedAsset = previousSnapshot.assetsByLocalIdentifier[identifier],
                  let freshRecord = freshRecords[identifier],
                  freshRecord.metadataMatches(indexedAsset)
            else {
                return nil
            }
        }

        var snapshot = previousSnapshot
        snapshot.photoLibraryChangeTokenData = changes.latestTokenData
            ?? manifestProvider.currentPhotoLibraryChangeTokenData()
        return PhotoLibraryUpdatedAssetChangeVerification(
            snapshot: snapshot,
            checkedAssetCount: updatedIdentifiers.count
        )
    }

    private func indexedFieldsUnchangedDiagnostics(
        changes: PhotoLibraryPersistentChangeSummary,
        verification: PhotoLibraryUpdatedAssetChangeVerification,
        startedAt: Date
    ) -> [String: String] {
        var diagnostics = changes.diagnosticsFields(
            mode: .persistentChangeTokenVerified,
            startedAt: startedAt
        )
        diagnostics["indexed_change"] = "false"
        diagnostics["resolution"] = "updated_asset_indexed_fields_unchanged"
        diagnostics["checked_updated_asset_count"] = "\(verification.checkedAssetCount)"
        return diagnostics
    }

    private func resolveIndexSnapshotFromPersistentChanges(
        previousSnapshot: PhotoLibraryIndexSnapshot,
        startedAt: Date,
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void
    ) throws -> PhotoLibraryIndexBuildOutcome? {
        guard let tokenData = previousSnapshot.photoLibraryChangeTokenData else {
            recordIndexDiagnostic("photo_library_index_persistent_change_unavailable", fields: [
                "reason": "missing_saved_token"
            ])
            return nil
        }
        guard previousSnapshot.authorizationStatusRawValue == authorizationStatus().rawValue else {
            recordIndexDiagnostic("photo_library_index_persistent_change_unavailable", fields: [
                "reason": "authorization_changed"
            ])
            return nil
        }
        guard let changes = try manifestProvider.photoLibraryPersistentChanges(since: tokenData) else {
            recordIndexDiagnostic("photo_library_index_persistent_change_unavailable", fields: [
                "reason": "provider_unavailable"
            ])
            return nil
        }

        if !changes.hasRelevantChanges {
            progress(PhotoLibraryIndexBuildProgress(
                phase: .validating,
                processed: previousSnapshot.indexedAssetMembershipCount,
                total: previousSnapshot.indexedAssetMembershipCount,
                currentPath: nil,
                message: "系统变更记录未发现照片库变化"
            ))
            var snapshot = previousSnapshot
            snapshot.photoLibraryChangeTokenData = changes.latestTokenData
                ?? manifestProvider.currentPhotoLibraryChangeTokenData()
            let diagnostics = changes.diagnosticsFields(
                mode: .persistentChangeTokenVerified,
                startedAt: startedAt
            )
            recordIndexDiagnostic("photo_library_index_persistent_change_verified", fields: diagnostics)
            return PhotoLibraryIndexBuildOutcome(
                snapshot: snapshot,
                mode: .persistentChangeTokenVerified,
                diagnostics: diagnostics
            )
        }

        if let verification = verifyUpdatedAssetChangesDoNotAffectIndex(
            previousSnapshot: previousSnapshot,
            changes: changes
        ) {
            progress(PhotoLibraryIndexBuildProgress(
                phase: .validating,
                processed: verification.checkedAssetCount,
                total: verification.checkedAssetCount,
                currentPath: nil,
                message: "系统变更未影响照片库索引字段"
            ))
            let diagnostics = indexedFieldsUnchangedDiagnostics(
                changes: changes,
                verification: verification,
                startedAt: startedAt
            )
            recordIndexDiagnostic("photo_library_index_persistent_change_verified", fields: diagnostics)
            return PhotoLibraryIndexBuildOutcome(
                snapshot: verification.snapshot,
                mode: .persistentChangeTokenVerified,
                diagnostics: diagnostics
            )
        }

        guard let scan = try manifestProvider.makeIncrementalManifest(
            previousSnapshot: previousSnapshot,
            changes: changes,
            progress: progress
        ) else {
            recordIndexDiagnostic("photo_library_index_persistent_change_unavailable", fields: [
                "reason": "incremental_manifest_unavailable",
                "change_count": "\(changes.changeCount)"
            ])
            return nil
        }

        let snapshot = try makeIndexSnapshot(from: scan, previousSnapshot: previousSnapshot)
        let diagnostics = changes.diagnosticsFields(
            mode: .incrementalRefresh,
            startedAt: startedAt
        ).merging(scan.diagnosticsFields(
            mode: .incrementalRefresh,
            summary: nil,
            startedAt: startedAt
        )) { _, fresh in fresh }
        recordIndexDiagnostic("photo_library_index_persistent_change_incremental_refresh", fields: diagnostics)
        return PhotoLibraryIndexBuildOutcome(
            snapshot: snapshot,
            mode: .incrementalRefresh,
            diagnostics: diagnostics
        )
    }

    private func runPhotoLibraryChangeNotificationLoop() {
        while true {
            waitForPhotoLibraryChangeNotificationCoalescingInterval()
            photoLibraryChangeNotificationCondition.lock()
            hasPendingPhotoLibraryChangeNotification = false
            photoLibraryChangeNotificationCondition.unlock()

            processPhotoLibraryChangeNotificationOnce()

            photoLibraryChangeNotificationCondition.lock()
            if hasPendingPhotoLibraryChangeNotification {
                photoLibraryChangeNotificationCondition.unlock()
                continue
            }
            isProcessingPhotoLibraryChangeNotification = false
            photoLibraryChangeNotificationCondition.broadcast()
            photoLibraryChangeNotificationCondition.unlock()
            break
        }
    }

    private func waitForPhotoLibraryChangeNotificationProcessing() {
        let startedAt = Date()
        var waitCount = 0
        photoLibraryChangeNotificationCondition.lock()
        while isProcessingPhotoLibraryChangeNotification {
            waitCount += 1
            photoLibraryChangeNotificationCondition.wait()
        }
        photoLibraryChangeNotificationCondition.unlock()
        guard waitCount > 0 else {
            return
        }
        recordIndexDiagnostic("photo_library_change_notification_wait", fields: [
            "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            "wait_count": "\(waitCount)"
        ])
    }

    private func processPhotoLibraryChangeNotificationOnce() {
        let startedAt = Date()
        guard let previousSnapshot = index.trustedSnapshot() else {
            recordIndexDiagnostic("photo_library_change_notification_fallback", fields: [
                "reason": "missing_trusted_snapshot"
            ])
            markPhotoLibraryIndexDirty(reason: "照片库发生变化")
            startPhotoLibraryIndexRefresh(reason: "刷新照片库变化")
            return
        }

        do {
            guard let outcome = try resolvePhotoLibraryChangeNotification(
                previousSnapshot: previousSnapshot,
                startedAt: startedAt
            ) else {
                markPhotoLibraryIndexDirty(reason: "照片库发生变化")
                startPhotoLibraryIndexRefresh(reason: "刷新照片库变化")
                return
            }

            let applied = index.applyResolvedChangeNotificationSnapshot(
                outcome.snapshot,
                previousVersion: previousSnapshot.version,
                mode: outcome.mode
            )
            var fields = outcome.diagnostics
            fields["applied"] = "\(applied)"
            recordIndexDiagnostic("photo_library_change_notification_resolved", fields: fields)
        } catch {
            recordIndexDiagnostic("photo_library_change_notification_fallback", fields: [
                "reason": "resolution_failed",
                "error": error.localizedDescription
            ])
            markPhotoLibraryIndexDirty(reason: "照片库发生变化")
            startPhotoLibraryIndexRefresh(reason: "刷新照片库变化")
        }
    }

    private func resolvePhotoLibraryChangeNotification(
        previousSnapshot: PhotoLibraryIndexSnapshot,
        startedAt: Date
    ) throws -> PhotoLibraryChangeNotificationOutcome? {
        guard let tokenData = previousSnapshot.photoLibraryChangeTokenData else {
            recordIndexDiagnostic("photo_library_change_notification_fallback", fields: [
                "reason": "missing_saved_token"
            ])
            return nil
        }
        guard previousSnapshot.authorizationStatusRawValue == authorizationStatus().rawValue else {
            recordIndexDiagnostic("photo_library_change_notification_fallback", fields: [
                "reason": "authorization_changed"
            ])
            return nil
        }
        guard let changes = try manifestProvider.photoLibraryPersistentChanges(since: tokenData) else {
            recordIndexDiagnostic("photo_library_change_notification_fallback", fields: [
                "reason": "provider_unavailable"
            ])
            return nil
        }

        if !changes.hasRelevantChanges {
            var snapshot = previousSnapshot
            snapshot.photoLibraryChangeTokenData = changes.latestTokenData
                ?? manifestProvider.currentPhotoLibraryChangeTokenData()
            var diagnostics = changes.diagnosticsFields(
                mode: .persistentChangeTokenVerified,
                startedAt: startedAt
            )
            diagnostics["indexed_change"] = "false"
            diagnostics["resolution"] = "persistent_change_token_noop"
            return PhotoLibraryChangeNotificationOutcome(
                snapshot: snapshot,
                mode: .persistentChangeTokenVerified,
                diagnostics: diagnostics
            )
        }

        if let verification = verifyUpdatedAssetChangesDoNotAffectIndex(
            previousSnapshot: previousSnapshot,
            changes: changes
        ) {
            let diagnostics = indexedFieldsUnchangedDiagnostics(
                changes: changes,
                verification: verification,
                startedAt: startedAt
            )
            return PhotoLibraryChangeNotificationOutcome(
                snapshot: verification.snapshot,
                mode: .persistentChangeTokenVerified,
                diagnostics: diagnostics
            )
        }

        guard let scan = try manifestProvider.makeIncrementalManifest(
            previousSnapshot: previousSnapshot,
            changes: changes,
            progress: { _ in }
        ) else {
            recordIndexDiagnostic("photo_library_change_notification_fallback", fields: [
                "reason": "incremental_manifest_unavailable",
                "change_count": "\(changes.changeCount)"
            ])
            return nil
        }

        let summary = PhotoLibraryManifestChangeSummary(
            previousSnapshot: previousSnapshot,
            scan: scan
        )
        if !summary.hasChanges {
            var snapshot = previousSnapshot
            snapshot.photoLibraryChangeTokenData = changes.latestTokenData
                ?? manifestProvider.currentPhotoLibraryChangeTokenData()
            var diagnostics = changes.diagnosticsFields(
                mode: .persistentChangeTokenVerified,
                startedAt: startedAt
            ).merging(scan.diagnosticsFields(
                mode: .persistentChangeTokenVerified,
                summary: summary,
                startedAt: startedAt
            )) { _, fresh in fresh }
            diagnostics["indexed_change"] = "false"
            diagnostics["resolution"] = "indexed_fields_unchanged"
            return PhotoLibraryChangeNotificationOutcome(
                snapshot: snapshot,
                mode: .persistentChangeTokenVerified,
                diagnostics: diagnostics
            )
        }

        let snapshot = try makeIndexSnapshot(from: scan, previousSnapshot: previousSnapshot)
        var diagnostics = changes.diagnosticsFields(
            mode: .incrementalRefresh,
            startedAt: startedAt
        ).merging(scan.diagnosticsFields(
            mode: .incrementalRefresh,
            summary: summary,
            startedAt: startedAt
        )) { _, fresh in fresh }
        diagnostics["indexed_change"] = "true"
        diagnostics["resolution"] = "incremental_refresh"
        return PhotoLibraryChangeNotificationOutcome(
            snapshot: snapshot,
            mode: .incrementalRefresh,
            diagnostics: diagnostics
        )
    }

    static func uniqued(_ rawName: String, usedNames: inout Set<String>) -> String {
        let name = sanitizedPathComponent(rawName)
        guard usedNames.contains(name) else {
            usedNames.insert(name)
            return name
        }

        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !usedNames.contains(candidate) {
                usedNames.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    static func sanitizedPathComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "未命名" : trimmed
        let replaced = fallback.map { character -> String in
            switch character {
            case "/", ":", "\0":
                return "_"
            default:
                return String(character)
            }
        }
        return replaced.joined()
    }

    static func normalizeVirtualPath(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".", "":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func join(_ parent: String, _ child: String) -> String {
        let normalizedParent = normalizeVirtualPath(parent)
        return normalizedParent == "/" ? "/" + child : normalizedParent + "/" + child
    }

    static func parentPath(of path: String) -> String? {
        let normalized = normalizeVirtualPath(path)
        guard normalized != "/" else {
            return nil
        }
        var components = normalized.split(separator: "/").map(String.init)
        components.removeLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func assetFileNames(
        for records: [PhotoLibraryManifestAssetRecord]
    ) -> [String: String] {
        let preferredHashLengths = [12, 16, 24, 32]
        var usedNames = Set<String>()
        var namesByLocalIdentifier: [String: String] = [:]
        namesByLocalIdentifier.reserveCapacity(records.count)

        for record in records {
            guard namesByLocalIdentifier[record.localIdentifier] == nil else {
                continue
            }
            let fileExtension = safeFileExtension(record.fileExtension)
            let digest = stableIdentifierDigest(record.localIdentifier)
            for length in preferredHashLengths {
                let name = String(digest.prefix(length)) + "." + fileExtension
                guard usedNames.insert(name).inserted else {
                    continue
                }
                namesByLocalIdentifier[record.localIdentifier] = name
                break
            }

            if namesByLocalIdentifier[record.localIdentifier] == nil {
                let fallbackStem = escapedIdentifierStem(record.localIdentifier)
                var name = fallbackStem + "." + fileExtension
                var suffix = 2
                while !usedNames.insert(name).inserted {
                    name = fallbackStem + "-" + String(suffix) + "." + fileExtension
                    suffix += 1
                }
                namesByLocalIdentifier[record.localIdentifier] = name
            }
        }

        return namesByLocalIdentifier
    }

    private static func safeFileExtension(_ rawExtension: String) -> String {
        let filtered = rawExtension.lowercased().filter { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
        return filtered.isEmpty ? "dat" : String(filtered.prefix(16))
    }

    private static func stableIdentifierDigest(_ localIdentifier: String) -> String {
        let first = fnv1a64(localIdentifier, seed: 14_695_981_039_346_656_037)
        let second = fnv1a64(localIdentifier, seed: 7_809_841_778_573_932_672)
        return String(format: "%016llx%016llx", first, second)
    }

    private static func fnv1a64(_ value: String, seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func escapedIdentifierStem(_ localIdentifier: String) -> String {
        let bytes = localIdentifier.utf8.map {
            String(format: "%02x", $0)
        }.joined()
        return bytes.isEmpty ? "asset" : bytes
    }

    private func currentOCRPreheatState() -> PhotoSorterMediaOCRPreheatState {
        ocrPreheatCondition.lock()
        defer {
            ocrPreheatCondition.unlock()
        }
        return ocrPreheatState
    }

    private func beginForegroundPhotoLibraryActivity() {
        foregroundPhotoLibraryActivityCondition.lock()
        foregroundPhotoLibraryActivityCount += 1
        foregroundPhotoLibraryActivityCondition.broadcast()
        foregroundPhotoLibraryActivityCondition.unlock()

        photoLibraryChangeNotificationCondition.lock()
        photoLibraryChangeNotificationForegroundActivityCount += 1
        photoLibraryChangeNotificationCondition.broadcast()
        photoLibraryChangeNotificationCondition.unlock()
    }

    private func endForegroundPhotoLibraryActivity() {
        foregroundPhotoLibraryActivityCondition.lock()
        foregroundPhotoLibraryActivityCount = max(0, foregroundPhotoLibraryActivityCount - 1)
        foregroundPhotoLibraryActivityCondition.broadcast()
        foregroundPhotoLibraryActivityCondition.unlock()

        photoLibraryChangeNotificationCondition.lock()
        photoLibraryChangeNotificationForegroundActivityCount = max(
            0,
            photoLibraryChangeNotificationForegroundActivityCount - 1
        )
        photoLibraryChangeNotificationCondition.broadcast()
        photoLibraryChangeNotificationCondition.unlock()
    }

    private func waitForForegroundPhotoLibraryActivityToFinish() -> Bool {
        foregroundPhotoLibraryActivityCondition.lock()
        while foregroundPhotoLibraryActivityCount > 0 {
            _ = foregroundPhotoLibraryActivityCondition.wait(until: Date().addingTimeInterval(0.25))
            if Task.isCancelled {
                foregroundPhotoLibraryActivityCondition.unlock()
                return false
            }
        }
        foregroundPhotoLibraryActivityCondition.unlock()
        return true
    }

    private func waitForPhotoLibraryChangeNotificationCoalescingInterval() {
        let deadline = Date().addingTimeInterval(
            TimeInterval(Self.photoLibraryChangeNotificationCoalescingNanoseconds) / 1_000_000_000
        )
        photoLibraryChangeNotificationCondition.lock()
        while photoLibraryChangeNotificationForegroundActivityCount == 0 {
            if !photoLibraryChangeNotificationCondition.wait(until: deadline) {
                break
            }
        }
        photoLibraryChangeNotificationCondition.unlock()
    }

    private func setOCRPreheatState(_ state: PhotoSorterMediaOCRPreheatState) {
        ocrPreheatCondition.lock()
        ocrPreheatState = state
        ocrPreheatCondition.broadcast()
        ocrPreheatCondition.unlock()
    }

    private func updateOCRPreheatProgress(processed: Int, limit: Int) {
        ocrPreheatCondition.lock()
        let isPaused = ocrPreheatState.isPaused
        ocrPreheatState = PhotoSorterMediaOCRPreheatState(
            isRunning: !isPaused,
            isPaused: isPaused,
            processed: processed,
            limit: limit,
            message: ocrPreheatProgressMessage(
                prefix: isPaused ? "OCR 缓存已暂停" : "OCR 缓存",
                processed: processed,
                limit: limit
            )
        )
        ocrPreheatCondition.broadcast()
        ocrPreheatCondition.unlock()
    }

    private func waitForOCRPreheatToContinue() -> Bool {
        while true {
            ocrPreheatCondition.lock()
            while ocrPreheatState.isPaused {
                _ = ocrPreheatCondition.wait(until: Date().addingTimeInterval(0.25))
                if Task.isCancelled {
                    ocrPreheatCondition.unlock()
                    return false
                }
            }
            let shouldContinue = ocrPreheatState.isRunning
            ocrPreheatCondition.unlock()
            guard shouldContinue else {
                return false
            }
            guard waitForForegroundPhotoLibraryActivityToFinish() else {
                return false
            }
            if Task.isCancelled {
                return false
            }
            ocrPreheatCondition.lock()
            let isPaused = ocrPreheatState.isPaused
            let shouldContinueAfterForegroundActivity = ocrPreheatState.isRunning
            ocrPreheatCondition.unlock()
            if isPaused {
                continue
            }
            return shouldContinueAfterForegroundActivity
        }
    }

    private func ocrPreheatProgressMessage(prefix: String, processed: Int, limit: Int) -> String {
        guard limit > 0 else {
            return prefix
        }
        return "\(prefix) \(processed)/\(limit)"
    }

    private func currentVLMPreheatState() -> PhotoSorterMediaVLMPreheatState {
        vlmPreheatCondition.lock()
        defer {
            vlmPreheatCondition.unlock()
        }
        return vlmPreheatState
    }

    private func currentVLMForegroundBackgroundTransitionGeneration() -> UInt64 {
        vlmPreheatCondition.lock()
        defer {
            vlmPreheatCondition.unlock()
        }
        return vlmForegroundBackgroundTransitionGeneration
    }

    private func currentVLMProviderStatus() -> PhotoSorterMediaVLMProviderStatus {
        vlmSummaryProvider.status(
            for: currentVLMModelBundle()
        )
    }

    private func currentVLMModelBundle() -> PhotoSorterFastVLMModelBundle {
        PhotoSorterFastVLMModelBundle.discover(
            directoryURL: vlmModelBundleDirectoryURL
        )
    }

    private func currentOCRCacheCoverage() -> (cachedCount: Int, totalCount: Int) {
        guard let snapshot = index.cachedSnapshotForStatus() else {
            return (0, 0)
        }
        let cacheGeneration = ocrCache.generation
        cacheCoverageLock.lock()
        if let coverage = ocrCacheCoverage,
           coverage.indexVersion == snapshot.version,
           coverage.cacheGeneration == cacheGeneration {
            cacheCoverageLock.unlock()
            return (coverage.cachedCount, coverage.totalCount)
        }
        cacheCoverageLock.unlock()

        let requests = snapshot.assetsByLocalIdentifier.values.compactMap { asset -> PhotoSorterMediaOCRCacheRequest? in
            guard Self.isImage(asset) else {
                return nil
            }
            return PhotoSorterMediaOCRCacheRequest(
                localIdentifier: asset.localIdentifier,
                assetVersion: Self.ocrAssetVersion(for: asset)
            )
        }
        let count = ocrCache.validEntryCount(for: requests)
        let coverage = PhotoSorterMediaOCRCacheCoverage(
            indexVersion: snapshot.version,
            cacheGeneration: count.generation,
            cachedCount: count.validCount,
            totalCount: requests.count
        )
        cacheCoverageLock.lock()
        ocrCacheCoverage = coverage
        cacheCoverageLock.unlock()
        return (coverage.cachedCount, coverage.totalCount)
    }

    private func currentVLMSummaryCacheCoverage(
        providerStatus: PhotoSorterMediaVLMProviderStatus
    ) -> (cachedCount: Int, totalCount: Int) {
        guard let snapshot = index.cachedSnapshotForStatus() else {
            return (0, 0)
        }
        let cacheGeneration = vlmSummaryCache.generation
        cacheCoverageLock.lock()
        if let coverage = vlmCacheCoverage,
           coverage.indexVersion == snapshot.version,
           coverage.cacheGeneration == cacheGeneration,
           coverage.processorConfigFingerprint == providerStatus.processorConfigFingerprint {
            cacheCoverageLock.unlock()
            return (coverage.cachedCount, coverage.totalCount)
        }
        cacheCoverageLock.unlock()

        let keys = snapshot.assetsByLocalIdentifier.values.compactMap { asset -> PhotoSorterMediaVLMSummaryCacheKey? in
            guard Self.isImage(asset) else {
                return nil
            }
            return Self.vlmCacheKey(
                for: asset,
                processorConfigFingerprint: providerStatus.processorConfigFingerprint
            )
        }
        let count = vlmSummaryCache.validEntryCount(for: keys)
        let coverage = PhotoSorterMediaVLMCacheCoverage(
            indexVersion: snapshot.version,
            cacheGeneration: count.generation,
            processorConfigFingerprint: providerStatus.processorConfigFingerprint,
            cachedCount: count.validCount,
            totalCount: keys.count
        )
        cacheCoverageLock.lock()
        vlmCacheCoverage = coverage
        cacheCoverageLock.unlock()
        return (coverage.cachedCount, coverage.totalCount)
    }

    private func currentPlaceCacheCoverage() -> (cachedCount: Int, totalCount: Int) {
        guard let snapshot = index.cachedSnapshotForStatus() else {
            return (0, 0)
        }
        let cacheGeneration = placeCache.generation
        cacheCoverageLock.lock()
        if let coverage = placeCacheCoverage,
           coverage.indexVersion == snapshot.version,
           coverage.cacheGeneration == cacheGeneration {
            cacheCoverageLock.unlock()
            return (coverage.cachedCount, coverage.totalCount)
        }
        cacheCoverageLock.unlock()

        let requests = snapshot.assetsByLocalIdentifier.values.compactMap { asset -> PhotoSorterMediaPlaceCacheRequest? in
            guard Self.hasLocation(asset) else {
                return nil
            }
            return PhotoSorterMediaPlaceCacheRequest(
                localIdentifier: asset.localIdentifier,
                locationVersion: Self.placeLocationVersion(for: asset)
            )
        }
        let count = placeCache.validEntryCount(for: requests)
        let coverage = PhotoSorterMediaPlaceCacheCoverage(
            indexVersion: snapshot.version,
            cacheGeneration: count.generation,
            cachedCount: count.validCount,
            totalCount: requests.count
        )
        cacheCoverageLock.lock()
        placeCacheCoverage = coverage
        cacheCoverageLock.unlock()
        return (coverage.cachedCount, coverage.totalCount)
    }

    private func recordOCRCacheStore(insertedValidEntry: Bool, generation: UInt64) {
        cacheCoverageLock.lock()
        defer {
            cacheCoverageLock.unlock()
        }
        guard var coverage = ocrCacheCoverage else {
            return
        }
        guard coverage.cacheGeneration &+ 1 == generation else {
            ocrCacheCoverage = nil
            return
        }
        if insertedValidEntry {
            coverage.cachedCount = min(coverage.cachedCount + 1, coverage.totalCount)
        }
        coverage.cacheGeneration = generation
        ocrCacheCoverage = coverage
    }

    private func recordVLMSummaryCacheStore(insertedValidEntry: Bool, generation: UInt64) {
        cacheCoverageLock.lock()
        defer {
            cacheCoverageLock.unlock()
        }
        guard var coverage = vlmCacheCoverage else {
            return
        }
        guard coverage.cacheGeneration &+ 1 == generation else {
            vlmCacheCoverage = nil
            return
        }
        if insertedValidEntry {
            coverage.cachedCount = min(coverage.cachedCount + 1, coverage.totalCount)
        }
        coverage.cacheGeneration = generation
        vlmCacheCoverage = coverage
    }

    private func recordPlaceCacheStore(insertedValidEntry: Bool, generation: UInt64) {
        cacheCoverageLock.lock()
        defer {
            cacheCoverageLock.unlock()
        }
        guard var coverage = placeCacheCoverage else {
            return
        }
        guard coverage.cacheGeneration &+ 1 == generation else {
            placeCacheCoverage = nil
            return
        }
        if insertedValidEntry {
            coverage.cachedCount = min(coverage.cachedCount + 1, coverage.totalCount)
        }
        coverage.cacheGeneration = generation
        placeCacheCoverage = coverage
    }

    private func setVLMPreheatState(_ state: PhotoSorterMediaVLMPreheatState) {
        vlmPreheatCondition.lock()
        vlmPreheatState = state
        vlmPreheatCondition.broadcast()
        vlmPreheatCondition.unlock()
    }

    private func vlmPreheatProgressMessage(prefix: String, processed: Int, limit: Int) -> String {
        guard limit > 0 else {
            return prefix
        }
        return "\(prefix) \(processed)/\(limit)"
    }

    private func updateVLMPreheatProgress(
        processed: Int,
        limit: Int,
        failed: Int,
        skipped: Int
    ) {
        vlmPreheatCondition.lock()
        let isPaused = vlmPreheatState.isPaused
        let isWaitingForForeground = !isPaused && !vlmForegroundInferenceAllowed
        vlmPreheatState = PhotoSorterMediaVLMPreheatState(
            isRunning: !isPaused && !isWaitingForForeground,
            isPaused: isPaused,
            isWaitingForForeground: isWaitingForForeground,
            processed: processed,
            limit: limit,
            failed: failed,
            skipped: skipped,
            message: vlmPreheatProgressMessage(
                prefix: isPaused
                    ? "视觉摘要缓存已暂停"
                    : isWaitingForForeground
                        ? "等待前台继续视觉摘要"
                        : "视觉摘要缓存",
                processed: processed,
                limit: limit
            )
        )
        vlmPreheatCondition.broadcast()
        vlmPreheatCondition.unlock()
    }

    private func waitForVLMPreheatToContinue() -> Bool {
        while true {
            vlmPreheatCondition.lock()
            while vlmPreheatState.isPaused || !vlmForegroundInferenceAllowed {
                if !vlmPreheatState.isPaused, !vlmPreheatState.isWaitingForForeground {
                    vlmPreheatState.isRunning = false
                    vlmPreheatState.isWaitingForForeground = true
                    vlmPreheatState.message = vlmPreheatProgressMessage(
                        prefix: "等待前台继续视觉摘要",
                        processed: vlmPreheatState.processed,
                        limit: vlmPreheatState.limit
                    )
                    vlmPreheatCondition.broadcast()
                }
                _ = vlmPreheatCondition.wait(until: Date().addingTimeInterval(0.25))
                if Task.isCancelled {
                    vlmPreheatCondition.unlock()
                    return false
                }
            }
            if vlmPreheatState.isWaitingForForeground {
                vlmPreheatState.isRunning = true
                vlmPreheatState.isWaitingForForeground = false
                vlmPreheatState.message = vlmPreheatProgressMessage(
                    prefix: "继续视觉摘要缓存",
                    processed: vlmPreheatState.processed,
                    limit: vlmPreheatState.limit
                )
                vlmPreheatCondition.broadcast()
            }
            let shouldContinue = vlmPreheatState.isRunning
            vlmPreheatCondition.unlock()
            guard shouldContinue else {
                return false
            }
            guard waitForForegroundPhotoLibraryActivityToFinish() else {
                return false
            }
            if Task.isCancelled {
                return false
            }
            vlmPreheatCondition.lock()
            let isPaused = vlmPreheatState.isPaused
            let isWaitingForForeground = vlmPreheatState.isWaitingForForeground
            let shouldContinueAfterForegroundActivity = vlmPreheatState.isRunning
            vlmPreheatCondition.unlock()
            if isPaused || isWaitingForForeground {
                continue
            }
            return shouldContinueAfterForegroundActivity
        }
    }

    private func currentPlacePreheatState() -> PhotoSorterMediaPlacePreheatState {
        placePreheatCondition.lock()
        defer {
            placePreheatCondition.unlock()
        }
        return placePreheatState
    }

    private func setPlacePreheatState(_ state: PhotoSorterMediaPlacePreheatState) {
        placePreheatCondition.lock()
        placePreheatState = state
        placePreheatCondition.broadcast()
        placePreheatCondition.unlock()
    }

    private func updatePlacePreheatProgress(processed: Int, limit: Int) {
        placePreheatCondition.lock()
        let isPaused = placePreheatState.isPaused
        placePreheatState = PhotoSorterMediaPlacePreheatState(
            isRunning: !isPaused,
            isPaused: isPaused,
            hasActiveTask: true,
            processed: processed,
            limit: limit,
            message: placePreheatProgressMessage(
                prefix: isPaused ? "地点缓存已暂停" : "地点缓存",
                processed: processed,
                limit: limit
            )
        )
        placePreheatCondition.broadcast()
        placePreheatCondition.unlock()
    }

    private func waitForPlacePreheatToContinue() -> Bool {
        while true {
            placePreheatCondition.lock()
            while placePreheatState.isPaused {
                _ = placePreheatCondition.wait(until: Date().addingTimeInterval(0.25))
                if Task.isCancelled {
                    placePreheatCondition.unlock()
                    return false
                }
            }
            let shouldContinue = placePreheatState.isRunning
            placePreheatCondition.unlock()
            guard shouldContinue else {
                return false
            }
            guard waitForForegroundPhotoLibraryActivityToFinish() else {
                return false
            }
            if Task.isCancelled {
                return false
            }
            placePreheatCondition.lock()
            let isPaused = placePreheatState.isPaused
            let shouldContinueAfterForegroundActivity = placePreheatState.isRunning
            placePreheatCondition.unlock()
            if isPaused {
                continue
            }
            return shouldContinueAfterForegroundActivity
        }
    }

    private func placePreheatProgressMessage(prefix: String, processed: Int, limit: Int) -> String {
        guard limit > 0 else {
            return prefix
        }
        return "\(prefix) \(processed)/\(limit)"
    }

    private func runOCRCachePreheatBatch(limit: Int?, snapshot: PhotoLibraryIndexSnapshot) async {
        var candidates = snapshot.assetsByLocalIdentifier.values
            .filter { asset in
                Self.isImage(asset)
                    && !ocrCache.containsValidEntry(
                        localIdentifier: asset.localIdentifier,
                        assetVersion: Self.ocrAssetVersion(for: asset)
                    )
            }
            .sorted { lhs, rhs in
                if lhs.creationDate != rhs.creationDate {
                    return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
                }
                return lhs.localIdentifier < rhs.localIdentifier
            }
        if let limit {
            candidates = Array(candidates.prefix(limit))
        }
        let batchLimit = candidates.count
        guard batchLimit > 0 else {
            setOCRPreheatState(PhotoSorterMediaOCRPreheatState(
                isRunning: false,
                isPaused: false,
                processed: 0,
                limit: 0,
                message: "OCR 缓存已完成"
            ))
            return
        }
        recordIndexDiagnostic("photo_library_ocr_preheat_start", fields: [
            "batch_limit": "\(batchLimit)"
        ])
        updateOCRPreheatProgress(processed: 0, limit: batchLimit)
        defer {
            try? ocrCache.flush()
        }

        var processed = 0
        var cachedInBatch = 0
        var skippedInBatch = 0
        var failedInBatch = 0
        var stoppedEarly = false
        for asset in candidates {
            guard !Task.isCancelled, waitForOCRPreheatToContinue() else {
                stoppedEarly = true
                break
            }
            let mountedAsset = asset.mountedAsset(in: "/图库")
            let ocrPlan = Self.ocrImagePlan(for: mountedAsset)
            let startedAt = Date()
            do {
                let result = try await recognizeOCRText(
                    for: mountedAsset,
                    outputPath: mountedAsset.virtualPath,
                    persistImmediately: false
                )
                let resultText: String
                if result == nil {
                    skippedInBatch += 1
                    resultText = "skipped"
                } else {
                    cachedInBatch += 1
                    resultText = "cached"
                }
                let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                if Self.shouldRecordOCRPreheatAssetDiagnostic(
                    processed: processed + 1,
                    durationMilliseconds: durationMilliseconds
                ) {
                    recordIndexDiagnostic("photo_library_ocr_preheat_asset_finish", fields: [
                        "duration_ms": "\(durationMilliseconds)",
                        "processed": "\(processed + 1)",
                        "batch_limit": "\(batchLimit)",
                        "source_size": "\(mountedAsset.pixelWidth)x\(mountedAsset.pixelHeight)",
                        "ocr_target_size": Self.pixelSizeText(ocrPlan.targetSize),
                        "ocr_tile_count": "\(ocrPlan.estimatedTileCount)",
                        "result": resultText
                    ])
                }
            } catch {
                failedInBatch += 1
                let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                if Self.shouldRecordOCRPreheatAssetDiagnostic(
                    processed: processed + 1,
                    durationMilliseconds: durationMilliseconds
                ) {
                    recordIndexDiagnostic("photo_library_ocr_preheat_asset_finish", fields: [
                        "duration_ms": "\(durationMilliseconds)",
                        "processed": "\(processed + 1)",
                        "batch_limit": "\(batchLimit)",
                        "source_size": "\(mountedAsset.pixelWidth)x\(mountedAsset.pixelHeight)",
                        "ocr_target_size": Self.pixelSizeText(ocrPlan.targetSize),
                        "ocr_tile_count": "\(ocrPlan.estimatedTileCount)",
                        "result": "failed",
                        "error": String(describing: error)
                    ])
                }
            }
            processed += 1
            updateOCRPreheatProgress(processed: processed, limit: batchLimit)
            await Task.yield()
            if Self.ocrPreheatAssetDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: Self.ocrPreheatAssetDelayNanoseconds)
            }
        }

        recordIndexDiagnostic("photo_library_ocr_preheat_finish", fields: [
            "processed": "\(processed)",
            "batch_limit": "\(batchLimit)",
            "cached": "\(cachedInBatch)",
            "skipped": "\(skippedInBatch)",
            "failed": "\(failedInBatch)",
            "stopped_early": "\(stoppedEarly)"
        ])
        setOCRPreheatState(PhotoSorterMediaOCRPreheatState(
            isRunning: false,
            isPaused: false,
            processed: processed,
            limit: batchLimit,
            message: processed == 0 && !stoppedEarly
                ? "没有需要预热的 OCR"
                : processed == batchLimit
                    ? Self.ocrPreheatFinishedMessage(
                        processed: processed,
                        limit: batchLimit,
                        cached: cachedInBatch,
                        skipped: skippedInBatch,
                        failed: failedInBatch
                    )
                    : "OCR 缓存已停止 \(processed)/\(batchLimit)"
        ))
    }

    private static func shouldRecordOCRPreheatAssetDiagnostic(
        processed: Int,
        durationMilliseconds: Int
    ) -> Bool {
        processed <= 5 || durationMilliseconds >= 1_000 || processed.isMultiple(of: 50)
    }

    private static func ocrPreheatFinishedMessage(
        processed: Int,
        limit: Int,
        cached: Int,
        skipped: Int,
        failed: Int
    ) -> String {
        guard cached == limit, skipped == 0, failed == 0 else {
            return "OCR 缓存本轮已处理 \(processed)/\(limit)，写入 \(cached)"
        }
        return "OCR 缓存已全部完成"
    }

    private func runVLMSummaryCachePreheatBatch(
        limit: Int?,
        snapshot: PhotoLibraryIndexSnapshot
    ) async {
        let providerStatus = currentVLMProviderStatus()
        var candidates = snapshot.assetsByLocalIdentifier.values
            .filter { asset in
                Self.isImage(asset)
                    && !vlmSummaryCache.containsValidEntry(
                        for: Self.vlmCacheKey(
                            for: asset,
                            processorConfigFingerprint: providerStatus.processorConfigFingerprint
                        )
                    )
            }
            .sorted { lhs, rhs in
                if lhs.creationDate != rhs.creationDate {
                    return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
                }
                return lhs.localIdentifier < rhs.localIdentifier
            }
        let totalCandidateCount = candidates.count
        if let limit {
            candidates = Array(candidates.prefix(limit))
        }
        let remainingAfterBatch = max(totalCandidateCount - candidates.count, 0)

        let batchLimit = candidates.count
        guard batchLimit > 0 else {
            setVLMPreheatState(PhotoSorterMediaVLMPreheatState(
                isRunning: false,
                isPaused: false,
                isWaitingForForeground: false,
                processed: 0,
                limit: 0,
                failed: 0,
                skipped: 0,
                message: "视觉摘要缓存已完成"
            ))
            return
        }

        recordIndexDiagnostic("photo_library_vlm_preheat_start", fields: [
            "batch_limit": "\(batchLimit)",
            "remaining_after_batch": "\(remainingAfterBatch)",
            "total_candidate_count": "\(totalCandidateCount)"
        ])
        updateVLMPreheatProgress(processed: 0, limit: batchLimit, failed: 0, skipped: 0)
        defer {
            try? vlmSummaryCache.flush()
        }

        var processed = 0
        var cachedInBatch = 0
        var skippedInBatch = 0
        var failedInBatch = 0
        var foregroundDeferredInBatch = 0
        var stoppedEarly = false
        var candidateIndex = 0
        while candidateIndex < candidates.count {
            guard !Task.isCancelled, waitForVLMPreheatToContinue() else {
                stoppedEarly = true
                break
            }
            let asset = candidates[candidateIndex]
            let mountedAsset = asset.mountedAsset(in: "/图库")
            let startedAt = Date()
            let backgroundTransitionGeneration = currentVLMForegroundBackgroundTransitionGeneration()
            do {
                let result = try await summarizeVLM(
                    for: mountedAsset,
                    outputPath: mountedAsset.virtualPath,
                    persistImmediately: true
                )
                let resultText: String
                if result == nil {
                    skippedInBatch += 1
                    resultText = "skipped"
                } else {
                    cachedInBatch += 1
                    resultText = "cached"
                }
                let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                if Self.shouldRecordVLMPreheatAssetDiagnostic(
                    processed: processed + 1,
                    durationMilliseconds: durationMilliseconds
                ) {
                    recordIndexDiagnostic("photo_library_vlm_preheat_asset_finish", fields: [
                        "duration_ms": "\(durationMilliseconds)",
                        "processed": "\(processed + 1)",
                        "batch_limit": "\(batchLimit)",
                        "path": mountedAsset.virtualPath,
                        "local_identifier": mountedAsset.localIdentifier,
                        "source_size": "\(mountedAsset.pixelWidth)x\(mountedAsset.pixelHeight)",
                        "result": resultText
                    ])
                }
            } catch {
                if Self.isVLMForegroundExecutionDenied(error),
                   deferVLMPreheatForForeground(
                        processed: processed,
                        limit: batchLimit,
                        failed: failedInBatch,
                        skipped: skippedInBatch,
                        backgroundTransitionGeneration: backgroundTransitionGeneration
                   ) {
                    foregroundDeferredInBatch += 1
                    let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    recordIndexDiagnostic("photo_library_vlm_preheat_asset_finish", fields: [
                        "duration_ms": "\(durationMilliseconds)",
                        "processed": "\(processed)",
                        "batch_limit": "\(batchLimit)",
                        "path": mountedAsset.virtualPath,
                        "local_identifier": mountedAsset.localIdentifier,
                        "source_size": "\(mountedAsset.pixelWidth)x\(mountedAsset.pixelHeight)",
                        "result": "foreground_deferred",
                        "error": String(describing: error)
                    ])
                    continue
                }
                failedInBatch += 1
                let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                if Self.shouldRecordVLMPreheatAssetDiagnostic(
                    processed: processed + 1,
                    durationMilliseconds: durationMilliseconds
                ) {
                    recordIndexDiagnostic("photo_library_vlm_preheat_asset_finish", fields: [
                        "duration_ms": "\(durationMilliseconds)",
                        "processed": "\(processed + 1)",
                        "batch_limit": "\(batchLimit)",
                        "path": mountedAsset.virtualPath,
                        "local_identifier": mountedAsset.localIdentifier,
                        "source_size": "\(mountedAsset.pixelWidth)x\(mountedAsset.pixelHeight)",
                        "result": "failed",
                        "error": String(describing: error)
                    ])
                }
            }
            processed += 1
            candidateIndex += 1
            updateVLMPreheatProgress(
                processed: processed,
                limit: batchLimit,
                failed: failedInBatch,
                skipped: skippedInBatch
            )
            await Task.yield()
            if Self.vlmPreheatAssetDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: Self.vlmPreheatAssetDelayNanoseconds)
            }
        }

        recordIndexDiagnostic("photo_library_vlm_preheat_finish", fields: [
            "processed": "\(processed)",
            "batch_limit": "\(batchLimit)",
            "remaining_after_batch": "\(remainingAfterBatch)",
            "total_candidate_count": "\(totalCandidateCount)",
            "cached": "\(cachedInBatch)",
            "skipped": "\(skippedInBatch)",
            "failed": "\(failedInBatch)",
            "foreground_deferred": "\(foregroundDeferredInBatch)",
            "stopped_early": "\(stoppedEarly)"
        ])
        setVLMPreheatState(PhotoSorterMediaVLMPreheatState(
            isRunning: false,
            isPaused: false,
            isWaitingForForeground: false,
            processed: processed,
            limit: batchLimit,
            failed: failedInBatch,
            skipped: skippedInBatch,
            message: processed == 0 && !stoppedEarly
                ? "没有需要预热的视觉摘要"
                : processed == batchLimit
                    ? Self.vlmPreheatFinishedMessage(
                        processed: processed,
                        limit: batchLimit,
                        cached: cachedInBatch,
                        skipped: skippedInBatch,
                        failed: failedInBatch,
                        remainingAfterBatch: remainingAfterBatch
                    )
                    : "视觉摘要缓存已停止 \(processed)/\(batchLimit)"
        ))
    }

    private static func shouldRecordVLMPreheatAssetDiagnostic(
        processed: Int,
        durationMilliseconds: Int
    ) -> Bool {
        processed <= 5 || durationMilliseconds >= 1_000 || processed.isMultiple(of: 10)
    }

    private func deferVLMPreheatForForeground(
        processed: Int,
        limit: Int,
        failed: Int,
        skipped: Int,
        backgroundTransitionGeneration: UInt64
    ) -> Bool {
        vlmPreheatCondition.lock()
        let isPaused = vlmPreheatState.isPaused
        let transitionedToBackground = vlmForegroundBackgroundTransitionGeneration != backgroundTransitionGeneration
        guard isPaused || !vlmForegroundInferenceAllowed || transitionedToBackground else {
            vlmPreheatCondition.unlock()
            return false
        }
        if !isPaused && vlmForegroundInferenceAllowed {
            vlmPreheatState = PhotoSorterMediaVLMPreheatState(
                isRunning: true,
                isPaused: false,
                isWaitingForForeground: false,
                processed: processed,
                limit: limit,
                failed: failed,
                skipped: skipped,
                message: vlmPreheatProgressMessage(
                    prefix: "继续视觉摘要缓存",
                    processed: processed,
                    limit: limit
                )
            )
            vlmPreheatCondition.broadcast()
            vlmPreheatCondition.unlock()
            try? vlmSummaryCache.flush()
            return true
        }
        vlmPreheatState = PhotoSorterMediaVLMPreheatState(
            isRunning: false,
            isPaused: isPaused,
            isWaitingForForeground: !isPaused,
            processed: processed,
            limit: limit,
            failed: failed,
            skipped: skipped,
            message: vlmPreheatProgressMessage(
                prefix: isPaused ? "视觉摘要缓存已暂停" : "等待前台继续视觉摘要",
                processed: processed,
                limit: limit
            )
        )
        vlmPreheatCondition.broadcast()
        vlmPreheatCondition.unlock()
        try? vlmSummaryCache.flush()
        return true
    }

    static func isVLMForegroundExecutionDenied(_ error: Error) -> Bool {
        let text = [
            String(describing: error),
            error.localizedDescription
        ].joined(separator: "\n").lowercased()
        return text.contains("backgroundexecutionnotpermitted")
            || text.contains("kiogpucommandbuffercallbackerrorbackgroundexecutionnotpermitted")
            || text.contains("submit gpu work from background")
    }

    private static func vlmPreheatFinishedMessage(
        processed: Int,
        limit: Int,
        cached: Int,
        skipped: Int,
        failed: Int,
        remainingAfterBatch: Int
    ) -> String {
        guard cached == limit, skipped == 0, failed == 0 else {
            return "视觉摘要缓存本轮已处理 \(processed)/\(limit)，写入 \(cached)，跳过 \(skipped)，失败 \(failed)"
        }
        if remainingAfterBatch > 0 {
            return "视觉摘要缓存本批已完成 \(processed)/\(limit)，剩余约 \(remainingAfterBatch)"
        }
        return "视觉摘要缓存已全部完成"
    }

    private func runPlaceCachePreheatBatch(limit: Int?, snapshot: PhotoLibraryIndexSnapshot) async {
        var candidates = snapshot.assetsByLocalIdentifier.values
            .filter { asset in
                Self.hasLocation(asset)
                    && !placeCache.containsValidEntry(
                        localIdentifier: asset.localIdentifier,
                        locationVersion: Self.placeLocationVersion(for: asset)
                    )
            }
            .sorted { lhs, rhs in
                if lhs.creationDate != rhs.creationDate {
                    return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
                }
                return lhs.localIdentifier < rhs.localIdentifier
            }
        if let limit {
            candidates = Array(candidates.prefix(limit))
        }

        let batchLimit = candidates.count
        guard batchLimit > 0 else {
            setPlacePreheatState(PhotoSorterMediaPlacePreheatState(
                isRunning: false,
                isPaused: false,
                hasActiveTask: false,
                processed: 0,
                limit: 0,
                message: "地点缓存已完成"
            ))
            return
        }

        setPlacePreheatState(PhotoSorterMediaPlacePreheatState(
            isRunning: true,
            isPaused: false,
            hasActiveTask: true,
            processed: 0,
            limit: batchLimit,
            message: "地点缓存 0/\(batchLimit)"
        ))
        defer {
            try? placeCache.flush()
        }

        var processed = 0
        var stoppedEarly = false
        for asset in candidates {
            guard !Task.isCancelled, waitForPlacePreheatToContinue() else {
                stoppedEarly = true
                break
            }
            if let location = Self.location(for: asset),
               let place = try? await resolveChinesePlace(for: location) {
                if let storeResult = try? placeCache.store(
                    place: place,
                    localIdentifier: asset.localIdentifier,
                    locationVersion: Self.placeLocationVersion(for: asset),
                    persistImmediately: false
                ) {
                    recordPlaceCacheStore(
                        insertedValidEntry: storeResult.insertedValidEntry,
                        generation: storeResult.generation
                    )
                }
            }
            processed += 1
            updatePlacePreheatProgress(processed: processed, limit: batchLimit)
            if placePreheatDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: placePreheatDelayNanoseconds)
            }
        }

        setPlacePreheatState(PhotoSorterMediaPlacePreheatState(
            isRunning: false,
            isPaused: false,
            hasActiveTask: false,
            processed: processed,
            limit: batchLimit,
            message: processed == 0 && !stoppedEarly
                ? "没有需要缓存的地点"
                : processed == batchLimit
                    ? "地点缓存已全部完成"
                    : "地点缓存已停止 \(processed)/\(batchLimit)"
        ))
    }

    private func recognizeOCRText(
        for mountedAsset: MountedAsset,
        outputPath: String,
        persistImmediately: Bool = true
    ) async throws -> PhotoSorterMediaOCRResult? {
        guard mountedAsset.mediaType == .image else {
            throw PhotoSorterMediaOCRError.unsupported("OCR supports images only")
        }
        let assetVersion = Self.ocrAssetVersion(for: mountedAsset)
        if let ocrRecognitionOverride {
            guard let text = try await ocrRecognitionOverride(mountedAsset, outputPath) else {
                return nil
            }
            let storeResult = try ocrCache.store(
                text: text,
                localIdentifier: mountedAsset.localIdentifier,
                assetVersion: assetVersion,
                persistImmediately: persistImmediately
            )
            recordOCRCacheStore(
                insertedValidEntry: storeResult.insertedValidEntry,
                generation: storeResult.generation
            )
            return PhotoSorterMediaOCRResult(
                path: outputPath,
                text: text,
                source: .live
            )
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [mountedAsset.localIdentifier],
            options: nil
        ).firstObject else {
            return nil
        }

        let (image, orientation) = try await localOCRImage(for: asset, mountedAsset: mountedAsset)
        let contentFingerprint = PhotoSorterVisualContentFingerprint.make(
            from: image,
            orientation: orientation
        )
        if let candidate = ocrCache.lookup(
            localIdentifier: mountedAsset.localIdentifier,
            assetVersion: assetVersion
        ), candidate.requiresContentValidation,
           let contentFingerprint,
           candidate.contentFingerprint == contentFingerprint {
            let storeResult = try ocrCache.store(
                text: candidate.text,
                localIdentifier: mountedAsset.localIdentifier,
                assetVersion: assetVersion,
                contentFingerprint: contentFingerprint,
                persistImmediately: persistImmediately
            )
            recordOCRCacheStore(
                insertedValidEntry: storeResult.insertedValidEntry,
                generation: storeResult.generation
            )
            return PhotoSorterMediaOCRResult(
                path: outputPath,
                text: candidate.text,
                source: .cache
            )
        }
        let recognition = try await Self.recognizedOCRText(from: image, orientation: orientation)
        let text = recognition.text
        if recognition.tileCount > 1 {
            recordIndexDiagnostic("photo_library_ocr_tiled_image", fields: [
                "path": outputPath,
                "source_size": "\(mountedAsset.pixelWidth)x\(mountedAsset.pixelHeight)",
                "ocr_input_size": "\(image.width)x\(image.height)",
                "ocr_tile_count": "\(recognition.tileCount)"
            ])
        }
        let storeResult = try ocrCache.store(
            text: text,
            localIdentifier: mountedAsset.localIdentifier,
            assetVersion: assetVersion,
            contentFingerprint: contentFingerprint,
            persistImmediately: persistImmediately
        )
        recordOCRCacheStore(
            insertedValidEntry: storeResult.insertedValidEntry,
            generation: storeResult.generation
        )
        return PhotoSorterMediaOCRResult(
            path: outputPath,
            text: text,
            source: .live
        )
    }

    private func localOCRImage(
        for asset: PHAsset,
        mountedAsset: MountedAsset,
        timeout: TimeInterval = 6
    ) async throws -> (CGImage, CGImagePropertyOrientation) {
#if canImport(UIKit) || canImport(AppKit)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact

        return try await withCheckedThrowingContinuation { continuation in
            let state = PhotoSorterMediaImageRequestState()
            let timeoutWorkItem = DispatchWorkItem {
                guard let resume = state.markResumed() else {
                    return
                }
                if let requestID = resume.requestID {
                    self.imageManager.cancelImageRequest(requestID)
                }
                continuation.resume(throwing: PhotoSorterMediaOCRError.unavailable(
                    "local OCR image timed out; image may need iCloud download"
                ))
            }
            state.setTimeoutWorkItem(timeoutWorkItem)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(timeout, 0.1),
                execute: timeoutWorkItem
            )

            let requestID = self.imageManager.requestImage(
                for: asset,
                targetSize: Self.ocrImageTargetSize(for: mountedAsset),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }
                let isCancelled = info?[PHImageCancelledKey] as? Bool ?? false
                if isCancelled {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: PhotoSorterMediaOCRError.unavailable(
                        "local OCR image request was cancelled"
                    ))
                    return
                }
                guard !Self.imageRequestResultIsDegraded(info) else {
                    return
                }
                guard let image else {
                    guard state.markResumed() != nil else {
                        return
                    }
                    let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                    let message = isInCloud
                        ? "local OCR image is unavailable; image may need iCloud download"
                        : "unable to read local OCR image"
                    continuation.resume(throwing: PhotoSorterMediaOCRError.unavailable(message))
                    return
                }
                guard let resolvedImage = Self.cgImageForOCR(from: image) else {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: PhotoSorterMediaOCRError.unavailable(
                        "unable to decode local OCR image"
                    ))
                    return
                }
                guard state.markResumed() != nil else {
                    return
                }
                continuation.resume(returning: resolvedImage)
            }
            if state.setRequestID(requestID) {
                self.imageManager.cancelImageRequest(requestID)
            }
        }
#else
        throw PhotoSorterMediaOCRError.unsupported("OCR image loading is unsupported on this platform")
#endif
    }

    static func ocrImageTargetSize(for asset: MountedAsset) -> CGSize {
        ocrImagePlan(for: asset).targetSize
    }

    static func ocrImagePlan(for asset: MountedAsset) -> OCRImagePlan {
        ocrImagePlan(width: asset.pixelWidth, height: asset.pixelHeight)
    }

    static func ocrImagePlan(width: Int, height: Int) -> OCRImagePlan {
        let targetSize = PhotoSorterModelImageSizing.targetSize(
            width: width,
            height: height
        )
        let longDimension = Int(ceil(max(targetSize.width, targetSize.height)))
        let tileCount = ocrTileStartOffsets(forLongDimension: longDimension).count
        return OCRImagePlan(
            targetSize: targetSize,
            usesTiling: tileCount > 1,
            estimatedTileCount: tileCount
        )
    }

    static func ocrImageTiles(for image: CGImage) -> [OCRImageTile] {
        let width = max(image.width, 1)
        let height = max(image.height, 1)
        let isVertical = height >= width
        let longDimension = isVertical ? height : width
        let starts = ocrTileStartOffsets(forLongDimension: longDimension)
        guard starts.count > 1 else {
            return [
                OCRImageTile(
                    index: 0,
                    count: 1,
                    rect: CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(width),
                        height: CGFloat(height)
                    )
                )
            ]
        }
        return starts.enumerated().map { offset, start in
            let length = min(Self.ocrTileMaximumLongPixelDimension, longDimension - start)
            let rect = isVertical
                ? CGRect(
                    x: 0,
                    y: CGFloat(start),
                    width: CGFloat(width),
                    height: CGFloat(length)
                )
                : CGRect(
                    x: CGFloat(start),
                    y: 0,
                    width: CGFloat(length),
                    height: CGFloat(height)
                )
            return OCRImageTile(index: offset, count: starts.count, rect: rect)
        }
    }

    static func mergedOCRTileTexts(_ tileTexts: [String]) -> String {
        var mergedLines: [String] = []
        for text in tileTexts {
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for line in lines where !mergedLines.suffix(4).contains(line) {
                mergedLines.append(line)
            }
        }
        return mergedLines.joined(separator: "\n")
    }

    private static func ocrTileStartOffsets(forLongDimension longDimension: Int) -> [Int] {
        let longDimension = max(longDimension, 1)
        guard longDimension > Self.ocrUntiledMaximumLongPixelDimension else {
            return [0]
        }
        let tileLength = min(Self.ocrTileMaximumLongPixelDimension, longDimension)
        let overlap = min(max(Self.ocrTileOverlapPixelDimension, 0), max(tileLength - 1, 0))
        let stride = max(tileLength - overlap, 1)
        let finalStart = max(longDimension - tileLength, 0)
        var starts = [0]
        var current = 0
        while current < finalStart {
            let next = min(current + stride, finalStart)
            guard next > current else {
                break
            }
            starts.append(next)
            current = next
        }
        return starts
    }

    private static func pixelSizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

#if canImport(UIKit)
    private static func cgImageForOCR(from image: UIImage) -> (CGImage, CGImagePropertyOrientation)? {
        guard let cgImage = image.cgImage else {
            return nil
        }
        return (cgImage, cgImagePropertyOrientation(from: image.imageOrientation))
    }

    private static func cgImagePropertyOrientation(
        from imageOrientation: UIImage.Orientation
    ) -> CGImagePropertyOrientation {
        switch imageOrientation {
        case .up:
            return .up
        case .upMirrored:
            return .upMirrored
        case .down:
            return .down
        case .downMirrored:
            return .downMirrored
        case .left:
            return .left
        case .leftMirrored:
            return .leftMirrored
        case .right:
            return .right
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }
#elseif canImport(AppKit)
    private static func cgImageForOCR(from image: NSImage) -> (CGImage, CGImagePropertyOrientation)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return (cgImage, .up)
    }
#endif

    private static func recognizedOCRText(
        from image: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> (text: String, tileCount: Int) {
        let tiles = ocrImageTiles(for: image)
        guard tiles.count > 1 else {
            return (try recognizedText(from: image, orientation: orientation), 1)
        }

        var tileTexts: [String] = []
        var firstError: Error?
        for tile in tiles {
            guard let croppedImage = image.cropping(to: tile.rect) else {
                firstError = firstError ?? PhotoSorterMediaOCRError.unavailable(
                    "unable to crop OCR tile \(tile.index + 1)/\(tile.count)"
                )
                continue
            }
            do {
                // Cropped CGImages are already pixel-upright; reusing the source orientation can confuse Vision.
                let text = try recognizedText(from: croppedImage, orientation: .up)
                tileTexts.append(text)
            } catch {
                firstError = firstError ?? error
            }
            await Task.yield()
        }

        let mergedText = mergedOCRTileTexts(tileTexts)
        if mergedText.isEmpty, let firstError {
            throw firstError
        }
        return (mergedText, tiles.count)
    }

    private static func recognizedText(
        from image: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> String {
#if canImport(Vision)
        let observations = try PhotoSorterVisionOCRExceptionGuard
            .performTextRecognition(image: image, orientation: orientation)
            .sorted { lhs, rhs in
                let lhsBox = lhs.boundingBox
                let rhsBox = rhs.boundingBox
                if abs(lhsBox.midY - rhsBox.midY) > 0.015 {
                    return lhsBox.midY > rhsBox.midY
                }
                return lhsBox.minX < rhsBox.minX
            }
        return observations.compactMap { observation in
            observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
#else
        throw PhotoSorterMediaOCRError.unsupported("OCR is unsupported on this platform")
#endif
    }

    private static func ocrAssetVersion(for asset: MountedAsset) -> String {
        ocrAssetVersion(
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private static func ocrAssetVersion(for asset: PhotoLibraryIndexAsset) -> String {
        ocrAssetVersion(
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private static func ocrAssetVersion(
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> String {
        // The cache canonicalizes this value without modificationDate for stable
        // lookup. The observed date remains available as a cheap signal that a
        // visual fingerprint may need validation before reuse.
        let modified = modificationDate.map {
            String(format: "%.6f", $0.timeIntervalSinceReferenceDate)
        } ?? "unknown"
        let longImageSuffix = ocrImagePlan(width: pixelWidth, height: pixelHeight).usesTiling
            ? "|long-ocr:tiles-v1"
            : ""
        return "modified:\(modified)|size:\(pixelWidth)x\(pixelHeight)|ocr-config:\(PhotoSorterMediaOCRCache.configurationVersion)\(longImageSuffix)"
    }

    private func vlmCacheKey(for asset: MountedAsset) -> PhotoSorterMediaVLMSummaryCacheKey {
        Self.vlmCacheKey(
            for: asset,
            processorConfigFingerprint: currentVLMProviderStatus().processorConfigFingerprint
        )
    }

    private func vlmCacheKey(for asset: PhotoLibraryIndexAsset) -> PhotoSorterMediaVLMSummaryCacheKey {
        Self.vlmCacheKey(
            for: asset,
            processorConfigFingerprint: currentVLMProviderStatus().processorConfigFingerprint
        )
    }

    private static func vlmCacheKey(
        for asset: MountedAsset,
        processorConfigFingerprint: String
    ) -> PhotoSorterMediaVLMSummaryCacheKey {
        PhotoSorterMediaVLMConfiguration.cacheKey(
            localIdentifier: asset.localIdentifier,
            assetVersion: vlmAssetVersion(
                modificationDate: asset.modificationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ),
            processorConfigFingerprint: processorConfigFingerprint
        )
    }

    private static func vlmCacheKey(
        for asset: PhotoLibraryIndexAsset,
        processorConfigFingerprint: String
    ) -> PhotoSorterMediaVLMSummaryCacheKey {
        PhotoSorterMediaVLMConfiguration.cacheKey(
            localIdentifier: asset.localIdentifier,
            assetVersion: vlmAssetVersion(
                modificationDate: asset.modificationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ),
            processorConfigFingerprint: processorConfigFingerprint
        )
    }

    private static func vlmAssetVersion(
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> String {
        let modified = modificationDate.map {
            String(format: "%.6f", $0.timeIntervalSinceReferenceDate)
        } ?? "unknown"
        return "modified:\(modified)|size:\(pixelWidth)x\(pixelHeight)|vlm-cache:\(PhotoSorterMediaVLMSummaryCache.configurationVersion)"
    }

    private func scheduleOCRContentValidation(
        for mountedAsset: MountedAsset
    ) {
        let assetVersion = Self.ocrAssetVersion(for: mountedAsset)
        guard let lookup = ocrCache.lookup(
            localIdentifier: mountedAsset.localIdentifier,
            assetVersion: assetVersion
        ), lookup.requiresContentValidation,
           beginVisualContentValidation(
            localIdentifier: mountedAsset.localIdentifier,
            kind: .ocr
           ) else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.endVisualContentValidation(
                    localIdentifier: mountedAsset.localIdentifier,
                    kind: .ocr
                )
            }
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [mountedAsset.localIdentifier],
                options: nil
            ).firstObject,
                  let (image, orientation) = try? await self.localOCRImage(
                    for: asset,
                    mountedAsset: mountedAsset
                  ),
                  let fingerprint = PhotoSorterVisualContentFingerprint.make(
                    from: image,
                    orientation: orientation
                  ) else {
                return
            }

            if lookup.contentFingerprint == fingerprint {
                _ = try? self.ocrCache.store(
                    text: lookup.text,
                    localIdentifier: mountedAsset.localIdentifier,
                    assetVersion: assetVersion,
                    contentFingerprint: fingerprint
                )
            } else {
                _ = try? self.ocrCache.remove(
                    localIdentifier: mountedAsset.localIdentifier,
                    assetVersion: assetVersion,
                    expectedContentFingerprint: lookup.contentFingerprint
                )
            }
            self.invalidateVisualCacheCoverage(kind: .ocr)
        }
    }

    private func scheduleVLMContentValidation(
        for mountedAsset: MountedAsset,
        cacheKey: PhotoSorterMediaVLMSummaryCacheKey
    ) {
        guard let lookup = vlmSummaryCache.lookup(for: cacheKey),
              lookup.requiresContentValidation,
              beginVisualContentValidation(
                localIdentifier: mountedAsset.localIdentifier,
                kind: .vlm
              ) else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.endVisualContentValidation(
                    localIdentifier: mountedAsset.localIdentifier,
                    kind: .vlm
                )
            }
            guard let image = try? await self.vlmCIImage(for: mountedAsset),
                  let fingerprint = PhotoSorterVisualContentFingerprint.make(from: image) else {
                return
            }

            if lookup.contentFingerprint == fingerprint {
                _ = try? self.vlmSummaryCache.store(
                    summary: lookup.summary,
                    for: cacheKey,
                    contentFingerprint: fingerprint
                )
            } else {
                _ = try? self.vlmSummaryCache.remove(
                    for: cacheKey,
                    expectedContentFingerprint: lookup.contentFingerprint
                )
            }
            self.invalidateVisualCacheCoverage(kind: .vlm)
        }
    }

    private enum VisualCacheValidationKind {
        case ocr
        case vlm
    }

    private func beginVisualContentValidation(
        localIdentifier: String,
        kind: VisualCacheValidationKind
    ) -> Bool {
        visualCacheValidationLock.lock()
        defer { visualCacheValidationLock.unlock() }
        switch kind {
        case .ocr:
            return ocrAssetsUnderContentValidation.insert(localIdentifier).inserted
        case .vlm:
            return vlmAssetsUnderContentValidation.insert(localIdentifier).inserted
        }
    }

    private func endVisualContentValidation(
        localIdentifier: String,
        kind: VisualCacheValidationKind
    ) {
        visualCacheValidationLock.lock()
        switch kind {
        case .ocr:
            ocrAssetsUnderContentValidation.remove(localIdentifier)
        case .vlm:
            vlmAssetsUnderContentValidation.remove(localIdentifier)
        }
        visualCacheValidationLock.unlock()
    }

    private func invalidateVisualCacheCoverage(kind: VisualCacheValidationKind) {
        cacheCoverageLock.lock()
        switch kind {
        case .ocr:
            ocrCacheCoverage = nil
        case .vlm:
            vlmCacheCoverage = nil
        }
        cacheCoverageLock.unlock()
    }

    private func summarizeVLM(
        for mountedAsset: MountedAsset,
        outputPath: String,
        persistImmediately: Bool = true
    ) async throws -> PhotoSorterMediaVLMSummaryResult? {
        let modelBundle = currentVLMModelBundle()
        let providerStatus = vlmSummaryProvider.status(for: modelBundle)
        let cacheKey = Self.vlmCacheKey(
            for: mountedAsset,
            processorConfigFingerprint: providerStatus.processorConfigFingerprint
        )
        let cachedLookup = vlmSummaryCache.lookup(for: cacheKey)
        if let cachedLookup, !cachedLookup.requiresContentValidation {
            return PhotoSorterMediaVLMSummaryResult(
                path: outputPath,
                summary: cachedLookup.summary,
                source: .cache
            )
        }
        let image = try await vlmCIImage(for: mountedAsset)
        let contentFingerprint = PhotoSorterVisualContentFingerprint.make(from: image)
        if let cachedLookup,
           cachedLookup.requiresContentValidation,
           let contentFingerprint,
           cachedLookup.contentFingerprint == contentFingerprint {
            let storeResult = try vlmSummaryCache.store(
                summary: cachedLookup.summary,
                for: cacheKey,
                contentFingerprint: contentFingerprint,
                persistImmediately: persistImmediately
            )
            recordVLMSummaryCacheStore(
                insertedValidEntry: storeResult.insertedValidEntry,
                generation: storeResult.generation
            )
            return PhotoSorterMediaVLMSummaryResult(
                path: outputPath,
                summary: cachedLookup.summary,
                source: .cache
            )
        }
        guard providerStatus.isLiveSummarizationAvailable else {
            throw PhotoSorterMediaVLMError.unavailable(
                providerStatus.reason ?? "local FastVLM is unavailable"
            )
        }
        let summary = try await vlmSummaryProvider.summarize(
            image: image,
            modelBundle: modelBundle
        )
        let storeResult = try vlmSummaryCache.store(
            summary: summary,
            for: cacheKey,
            contentFingerprint: contentFingerprint,
            persistImmediately: persistImmediately
        )
        recordVLMSummaryCacheStore(
            insertedValidEntry: storeResult.insertedValidEntry,
            generation: storeResult.generation
        )
        return PhotoSorterMediaVLMSummaryResult(
            path: outputPath,
            summary: summary,
            source: .live
        )
    }

    private func vlmCIImage(for mountedAsset: MountedAsset) async throws -> CIImage {
        if let image = try await vlmImageOverride?(mountedAsset) {
            return Self.vlmPreparedImage(image, for: mountedAsset)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [mountedAsset.localIdentifier],
            options: nil
        ).firstObject else {
            throw PhotoSorterMediaVLMError.unavailable("media asset not found")
        }

#if canImport(UIKit) || canImport(AppKit)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        options.version = .current
        let targetSize = Self.vlmImageTargetSize(for: mountedAsset)

        return try await withCheckedThrowingContinuation { continuation in
            let state = PhotoSorterMediaImageRequestState()
            let timeoutWorkItem = DispatchWorkItem {
                guard let resume = state.markResumed() else {
                    return
                }
                if let requestID = resume.requestID {
                    self.imageManager.cancelImageRequest(requestID)
                }
                continuation.resume(throwing: PhotoSorterMediaVLMError.unavailable(
                    "local image request timed out; image may need iCloud download"
                ))
            }
            state.setTimeoutWorkItem(timeoutWorkItem)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 6,
                execute: timeoutWorkItem
            )

            let requestID = self.imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }
                let isCancelled = info?[PHImageCancelledKey] as? Bool ?? false
                if isCancelled {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: PhotoSorterMediaVLMError.unavailable(
                        "local image request was cancelled"
                    ))
                    return
                }
                guard !Self.imageRequestResultIsDegraded(info) else {
                    return
                }
                guard let image,
                      let ciImage = Self.ciImage(from: image)
                else {
                    let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                    guard state.markResumed() != nil else {
                        return
                    }
                    let message = isInCloud
                        ? "local image is unavailable; image may need iCloud download"
                        : "unable to read local image"
                    continuation.resume(throwing: PhotoSorterMediaVLMError.unavailable(message))
                    return
                }
                guard state.markResumed() != nil else {
                    return
                }
                continuation.resume(returning: Self.vlmPreparedImage(ciImage, for: mountedAsset))
            }
            if state.setRequestID(requestID) {
                self.imageManager.cancelImageRequest(requestID)
            }
        }
#else
        throw PhotoSorterMediaVLMError.unavailable("local image request is unsupported on this platform")
#endif
    }

    private static func vlmImageTargetSize(for mountedAsset: MountedAsset) -> CGSize {
        let width = CGFloat(max(mountedAsset.pixelWidth, 1))
        let height = CGFloat(max(mountedAsset.pixelHeight, 1))
        let longest = max(width, height)
        let scale = min(1, CGFloat(vlmMaximumInputLongPixelDimension) / longest)
        return CGSize(
            width: max((width * scale).rounded(), 1),
            height: max((height * scale).rounded(), 1)
        )
    }

    private static func vlmPreparedImage(
        _ image: CIImage,
        for mountedAsset: MountedAsset
    ) -> CIImage {
        let targetSize = vlmImageTargetSize(for: mountedAsset)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return image
        }
        let scale = min(
            1,
            targetSize.width / extent.width,
            targetSize.height / extent.height
        )
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        guard scale < 1 else {
            return normalized
        }
        let scaledSize = CGSize(
            width: max((extent.width * scale).rounded(), 1),
            height: max((extent.height * scale).rounded(), 1)
        )
        return normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: scaledSize))
    }

#if canImport(UIKit)
    private static func ciImage(from image: UIImage) -> CIImage? {
        if let ciImage = image.ciImage {
            return ciImage
        }
        if let cgImage = image.cgImage {
            return CIImage(cgImage: cgImage)
        }
        return nil
    }
#elseif canImport(AppKit)
    private static func ciImage(from image: NSImage) -> CIImage? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CIImage(cgImage: cgImage)
        }
        return nil
    }
#endif

    private static func isImage(_ asset: PhotoLibraryIndexAsset) -> Bool {
        asset.mediaTypeRawValue == PHAssetMediaType.image.rawValue
    }

    private static func hasLocation(_ asset: PhotoLibraryIndexAsset) -> Bool {
        asset.locationLatitude != nil && asset.locationLongitude != nil
    }

    private static func hasLocation(_ asset: MountedAsset) -> Bool {
        asset.locationLatitude != nil && asset.locationLongitude != nil
    }

    private static func location(for asset: PhotoLibraryIndexAsset) -> CLLocation? {
        guard let latitude = asset.locationLatitude,
              let longitude = asset.locationLongitude
        else {
            return nil
        }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: asset.locationHorizontalAccuracy ?? kCLLocationAccuracyThreeKilometers,
            verticalAccuracy: -1,
            timestamp: asset.creationDate ?? Date()
        )
    }

    private static func placeLocationVersion(for asset: PhotoLibraryIndexAsset) -> String {
        placeLocationVersion(
            latitude: asset.locationLatitude,
            longitude: asset.locationLongitude,
            horizontalAccuracy: asset.locationHorizontalAccuracy
        )
    }

    private static func placeLocationVersion(for asset: MountedAsset) -> String {
        placeLocationVersion(
            latitude: asset.locationLatitude,
            longitude: asset.locationLongitude,
            horizontalAccuracy: asset.locationHorizontalAccuracy
        )
    }

    private static func placeLocationVersion(
        latitude: Double?,
        longitude: Double?,
        horizontalAccuracy: Double?
    ) -> String {
        guard let latitude, let longitude else {
            return "location:none"
        }
        let accuracy = horizontalAccuracy.map { String(format: "%.1f", $0) } ?? "unknown"
        return String(format: "lat:%.6f|lon:%.6f|hacc:%@", latitude, longitude, accuracy)
    }

    private func resolveChinesePlace(for location: CLLocation) async throws -> String? {
        if let placeResolutionOverride {
            return try await placeResolutionOverride(location)
        }
        return try await Self.resolveChinesePlace(for: location)
    }

    private static func resolveChinesePlace(for location: CLLocation) async throws -> String? {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                return nil
            }
            request.preferredLocale = Locale(identifier: "zh_CN")
            let mapItems = try await request.mapItems
            return mapItems.compactMap(Self.chinesePlaceText).first
        } else {
            return try await resolveChinesePlaceWithCLGeocoder(for: location)
        }
    }

    private static func resolveChinesePlaceWithCLGeocoder(for location: CLLocation) async throws -> String? {
        let geocoder = CLGeocoder()
        let placemarks: [CLPlacemark] = try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(
                location,
                preferredLocale: Locale(identifier: "zh_CN")
            ) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: placemarks ?? [])
            }
        }
        return placemarks.compactMap(Self.chinesePlaceText).first
    }

    private static func chinesePlaceText(for mapItem: MKMapItem) -> String? {
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) else {
            return nil
        }
        let representations = mapItem.addressRepresentations
        let candidates = [
            representations?.fullAddress(includingRegion: true, singleLine: true),
            representations?.cityWithContext(.full),
            representations?.cityWithContext,
            representations?.cityName,
            representations?.regionName,
            mapItem.address?.fullAddress,
            mapItem.address?.shortAddress,
            mapItem.name
        ]
        return candidates.compactMap(Self.normalizedChinesePlaceCandidate).first
    }

    private static func chinesePlaceText(for placemark: CLPlacemark) -> String? {
        let parts = [
            placemark.country,
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare
        ]
        var seen = Set<String>()
        let text = parts.compactMap { rawPart -> String? in
            guard let part = normalizedChinesePlaceCandidate(rawPart),
                  seen.insert(part).inserted
            else {
                return nil
            }
            return part
        }.joined()
        if !text.isEmpty {
            return text
        }
        return normalizedChinesePlaceCandidate(placemark.name)
    }

    private static func normalizedChinesePlaceCandidate(_ rawText: String?) -> String? {
        guard let rawText else {
            return nil
        }
        let text = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              containsCJK(text),
              !containsASCIIAlpha(text)
        else {
            return nil
        }
        return text
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2A6DF,
                 0x2A700...0x2B73F,
                 0x2B740...0x2B81F,
                 0x2B820...0x2CEAF:
                return true
            default:
                return false
            }
        }
    }

    private static func containsASCIIAlpha(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
    }

    private static let manifestBatchSize = 500
    private static let photoLibraryChangeNotificationCoalescingNanoseconds: UInt64 = 250_000_000

    private func recordIndexDiagnostic(_ event: String, fields: [String: String]) {
        guard let diagnosticsLog else {
            return
        }
        Task {
            await diagnosticsLog.record(event, fields: fields)
        }
    }

    private func indexSnapshotRequestFields(
        reason: String,
        startedAt: Date,
        startStatus: PhotoLibraryIndexStatus,
        endStatus: PhotoLibraryIndexStatus,
        result: String
    ) -> [String: String] {
        [
            "reason": reason,
            "result": result,
            "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            "waited_for_index": "\(startStatus.phase != .ready)",
            "start_phase": startStatus.phase.rawValue,
            "start_version": "\(startStatus.version)",
            "start_processed": "\(startStatus.processed)",
            "start_total": startStatus.total.map(String.init) ?? "",
            "end_phase": endStatus.phase.rawValue,
            "end_version": "\(endStatus.version)",
            "end_processed": "\(endStatus.processed)",
            "end_total": endStatus.total.map(String.init) ?? ""
        ]
    }
}

extension PhotoLibraryMount: PhotoSorterMediaImageProviding {
    func photoSorterModelImage(
        for virtualPath: String,
        maxPixelDimension: Int
    ) async throws -> PhotoSorterOriginalImage? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        let mountedAsset = try cachedAsset(at: normalized) ?? asset(at: normalized)
        guard let mountedAsset else {
            return nil
        }
        guard mountedAsset.mediaType == .image else {
            throw PhotoSorterMediaImageError.unsupported("image view supports images only")
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [mountedAsset.localIdentifier],
            options: nil
        ).firstObject else {
            return nil
        }

        let targetSize = Self.modelImageTargetSize(
            for: mountedAsset,
            maxPixelDimension: maxPixelDimension
        )
        let image = try await modelImageData(
            for: asset,
            fileName: mountedAsset.name,
            targetSize: targetSize
        )
        return PhotoSorterOriginalImage(
            path: normalized,
            fileName: mountedAsset.name,
            mimeType: image.mimeType,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            data: image.data
        )
    }

    private func modelImageData(
        for asset: PHAsset,
        fileName: String,
        targetSize: CGSize,
        timeout: TimeInterval = 30
    ) async throws -> (data: Data, mimeType: String, pixelWidth: Int, pixelHeight: Int) {
#if canImport(UIKit) || canImport(AppKit)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact

        return try await withCheckedThrowingContinuation { continuation in
            let state = PhotoSorterMediaImageRequestState()
            let timeoutWorkItem = DispatchWorkItem {
                guard let resume = state.markResumed() else {
                    return
                }
                if let requestID = resume.requestID {
                    self.imageManager.cancelImageRequest(requestID)
                }
                continuation.resume(throwing: PhotoSorterMediaImageError.unavailable(
                    "image preview timed out while downloading from iCloud"
                ))
            }
            state.setTimeoutWorkItem(timeoutWorkItem)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(timeout, 0.1),
                execute: timeoutWorkItem
            )

            let requestID = self.imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }
                let isCancelled = info?[PHImageCancelledKey] as? Bool ?? false
                if isCancelled {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: PhotoSorterMediaImageError.unavailable(
                        "local image preview was cancelled"
                    ))
                    return
                }
                guard !Self.imageRequestResultIsDegraded(info) else {
                    return
                }
                guard let image else {
                    let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                    guard state.markResumed() != nil else {
                        return
                    }
                    let message = isInCloud
                        ? "local high-quality image is unavailable; image may need iCloud download"
                        : "unable to read high-quality local image"
                    continuation.resume(throwing: PhotoSorterMediaImageError.unavailable(
                        message
                    ))
                    return
                }
                guard let encoded = Self.encodedModelImageData(from: image, fileName: fileName) else {
                    guard state.markResumed() != nil else {
                        return
                    }
                    continuation.resume(throwing: PhotoSorterMediaImageError.unavailable(
                        "unable to encode image preview"
                    ))
                    return
                }
                guard state.markResumed() != nil else {
                    return
                }
                continuation.resume(returning: encoded)
            }
            if state.setRequestID(requestID) {
                self.imageManager.cancelImageRequest(requestID)
            }
        }
#else
        throw PhotoSorterMediaImageError.unsupported("image view is unsupported on this platform")
#endif
    }

    private static func modelImageTargetSize(
        for asset: MountedAsset,
        maxPixelDimension: Int
    ) -> CGSize {
        PhotoSorterModelImageSizing.targetSize(
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            preferredMaximumPixelDimension: maxPixelDimension
        )
    }

#if canImport(UIKit)
    private static func encodedModelImageData(
        from image: UIImage,
        fileName: String
    ) -> (data: Data, mimeType: String, pixelWidth: Int, pixelHeight: Int)? {
        let pixelWidth = image.cgImage?.width ?? Int((image.size.width * image.scale).rounded())
        let pixelHeight = image.cgImage?.height ?? Int((image.size.height * image.scale).rounded())
        if shouldEncodeModelImageAsPNG(fileName: fileName),
           let data = image.pngData() {
            return (data, "image/png", pixelWidth, pixelHeight)
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            return nil
        }
        return (data, "image/jpeg", pixelWidth, pixelHeight)
    }
#elseif canImport(AppKit)
    private static func encodedModelImageData(
        from image: NSImage,
        fileName: String
    ) -> (data: Data, mimeType: String, pixelWidth: Int, pixelHeight: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        guard let encoded = encodedModelImageData(from: cgImage, fileName: fileName) else {
            return nil
        }
        return (encoded.data, encoded.mimeType, cgImage.width, cgImage.height)
    }
#endif

    private static func encodedModelImageData(
        from image: CGImage,
        fileName: String
    ) -> (data: Data, mimeType: String)? {
        let keepsPNG = shouldEncodeModelImageAsPNG(fileName: fileName)
        let outputType = keepsPNG ? "public.png" : "public.jpeg"
        let outputMimeType = keepsPNG ? "image/png" : "image/jpeg"
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            outputType as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = keepsPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return (data as Data, outputMimeType)
    }

    private static func shouldEncodeModelImageAsPNG(fileName: String) -> Bool {
        URL(fileURLWithPath: fileName).pathExtension.lowercased() == "png"
    }

    static func imageRequestResultIsDegraded(_ info: [AnyHashable: Any]?) -> Bool {
        info?[PHImageResultIsDegradedKey] as? Bool ?? false
    }

}

extension PhotoLibraryMount: PhotoSorterMediaReviewProviding {
    func photoSorterReviewMedia(
        for virtualPath: String,
        maxPixelDimension: Int
    ) async throws -> PhotoSorterMediaViewItem? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        let mountedAsset = try cachedAsset(at: normalized) ?? asset(at: normalized)
        guard let mountedAsset else {
            return nil
        }
        guard let kind = Self.mediaPreviewKind(for: mountedAsset) else {
            throw PhotoSorterMediaImageError.unsupported("media review supports images, videos, and Live Photos only")
        }
        if kind == .image {
            guard let image = try await photoSorterModelImage(
                for: normalized,
                maxPixelDimension: maxPixelDimension
            ) else {
                return nil
            }
            return PhotoSorterMediaViewItem(image: image)
        }
        let targetSize = CGSize(
            width: max(maxPixelDimension, 1),
            height: max(maxPixelDimension, 1)
        )
        let preview = await mediaPreview(
            for: mountedAsset,
            kind: kind,
            targetSize: targetSize
        )
        return PhotoSorterMediaViewItem(preview: preview)
    }
}

extension PhotoLibraryMount: PhotoSorterMediaAskExclusionTracking {
    func photoSorterMediaAskExcludedCountsByUser(for virtualPaths: [String]) -> [Int] {
        virtualPaths.map { path in
            let normalized = Self.normalizeVirtualPath(path)
            guard let mountedAsset = cachedAsset(at: normalized) ?? (try? asset(at: normalized)) else {
                return 0
            }
            return askExclusionCache.count(localIdentifier: mountedAsset.localIdentifier)
        }
    }

    func recordPhotoSorterMediaAskExclusionsByUser(at virtualPaths: [String]) throws {
        let identifiers = virtualPaths.compactMap { path -> String? in
            let normalized = Self.normalizeVirtualPath(path)
            return (cachedAsset(at: normalized) ?? (try? asset(at: normalized)))?.localIdentifier
        }
        try askExclusionCache.increment(localIdentifiers: identifiers)
    }
}

private struct PhotoSorterMediaImageRequestResume {
    var requestID: PHImageRequestID?
}

private final class PhotoSorterMediaImageRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var requestID: PHImageRequestID?
    private var timeoutWorkItem: DispatchWorkItem?

    func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        lock.lock()
        timeoutWorkItem = workItem
        let shouldCancel = didResume
        lock.unlock()
        if shouldCancel {
            workItem.cancel()
        }
    }

    func setRequestID(_ requestID: PHImageRequestID) -> Bool {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = didResume
        lock.unlock()
        return shouldCancel
    }

    func markResumed() -> PhotoSorterMediaImageRequestResume? {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return nil
        }
        didResume = true
        let requestID = requestID
        let timeoutWorkItem = timeoutWorkItem
        lock.unlock()

        timeoutWorkItem?.cancel()
        return PhotoSorterMediaImageRequestResume(requestID: requestID)
    }
}

private final class PhotoLibraryResourceReadState: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var data = Data()
    private var completionError: Error?

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish(_ error: Error?) {
        lock.lock()
        completionError = error
        lock.unlock()
        semaphore.signal()
    }

    func waitForResult() throws -> Data {
        semaphore.wait()
        lock.lock()
        let snapshot = data
        let error = completionError
        lock.unlock()
        if let error {
            throw error
        }
        return snapshot
    }
}

extension PhotoLibraryMount {
    func photoSorterMediaMetadata(for virtualPaths: [String]) -> [PhotoSorterMediaMetadataLookup] {
        guard !virtualPaths.isEmpty else {
            return []
        }
        let normalizedPaths = virtualPaths.map(Self.normalizeVirtualPath)
        let snapshot: PhotoLibraryIndexSnapshot
        do {
            snapshot = try currentIndexSnapshot(reason: "读取媒体元数据")
        } catch {
            return normalizedPaths.map { _ in
                .unavailable(String(describing: error))
            }
        }

        return normalizedPaths.map { normalized in
            let mountedAsset = workspaceOverlay.snapshot.effectiveAsset(
                at: normalized,
                baseAsset: snapshot.asset(at: normalized)
            ) { identifier in
                Self.mountedAsset(localIdentifier: identifier, from: snapshot)
            }
            guard let mountedAsset else {
                return .unavailable("media asset not found")
            }
            return .hit(PhotoSorterMediaMetadata(
                path: normalized,
                pixelWidth: mountedAsset.pixelWidth,
                pixelHeight: mountedAsset.pixelHeight,
                creationDate: mountedAsset.creationDate,
                cachedPlace: cachedPlace(for: mountedAsset)
            ))
        }
    }
}

extension PhotoLibraryMount: PhotoSorterMediaOCRProviding {
    func cachedPhotoSorterMediaOCRText(for virtualPath: String) throws -> PhotoSorterMediaOCRCacheLookup {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let mountedAsset = try asset(at: normalized) else {
            return .unavailable("media asset not found")
        }
        guard mountedAsset.mediaType == .image else {
            return .unavailable("OCR supports images only")
        }
        let assetVersion = Self.ocrAssetVersion(for: mountedAsset)
        guard let lookup = ocrCache.lookup(
            localIdentifier: mountedAsset.localIdentifier,
            assetVersion: assetVersion
        ) else {
            return .miss
        }
        if lookup.requiresContentValidation {
            scheduleOCRContentValidation(for: mountedAsset)
        }
        return .hit(PhotoSorterMediaOCRResult(
            path: normalized,
            text: lookup.text,
            source: .cache
        ))
    }

    func cachedPhotoSorterMediaOCRTexts(for virtualPaths: [String]) -> [PhotoSorterMediaOCRCacheLookup] {
        guard !virtualPaths.isEmpty else {
            return []
        }
        let normalizedPaths = virtualPaths.map(Self.normalizeVirtualPath)
        let snapshot: PhotoLibraryIndexSnapshot
        do {
            snapshot = try currentIndexSnapshot(reason: "读取媒体文件")
        } catch {
            return normalizedPaths.map { _ in
                .unavailable(String(describing: error))
            }
        }

        let overlaySnapshot = workspaceOverlay.snapshot
        var lookups = Array<PhotoSorterMediaOCRCacheLookup>(
            repeating: .miss,
            count: normalizedPaths.count
        )
        var cacheRequests: [PhotoSorterMediaOCRCacheRequest] = []
        var cacheRequestIndexes: [Int] = []
        cacheRequests.reserveCapacity(normalizedPaths.count)
        cacheRequestIndexes.reserveCapacity(normalizedPaths.count)

        for (index, normalized) in normalizedPaths.enumerated() {
            let mountedAsset = overlaySnapshot.effectiveAsset(
                at: normalized,
                baseAsset: snapshot.asset(at: normalized)
            ) { identifier in
                Self.mountedAsset(localIdentifier: identifier, from: snapshot)
            }
            guard let mountedAsset else {
                lookups[index] = .unavailable("media asset not found")
                continue
            }
            guard mountedAsset.mediaType == .image else {
                lookups[index] = .unavailable("OCR supports images only")
                continue
            }
            cacheRequests.append(PhotoSorterMediaOCRCacheRequest(
                localIdentifier: mountedAsset.localIdentifier,
                assetVersion: Self.ocrAssetVersion(for: mountedAsset)
            ))
            cacheRequestIndexes.append(index)
        }

        let cachedTexts = ocrCache.texts(for: cacheRequests)
        for (requestOffset, index) in cacheRequestIndexes.enumerated() {
            guard cachedTexts.indices.contains(requestOffset),
                  let text = cachedTexts[requestOffset] else {
                lookups[index] = .miss
                continue
            }
            lookups[index] = .hit(PhotoSorterMediaOCRResult(
                path: normalizedPaths[index],
                text: text,
                source: .cache
            ))
        }
        return lookups
    }

    func recognizePhotoSorterMediaOCRText(for virtualPath: String) async throws -> PhotoSorterMediaOCRResult? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let mountedAsset = try asset(at: normalized) else {
            return nil
        }
        return try await recognizeOCRText(for: mountedAsset, outputPath: normalized)
    }
}

extension PhotoLibraryMount: PhotoSorterVLMProviding {
    func photoSorterVLMStatus() -> PhotoSorterMediaVLMStatus {
        photoLibraryVLMSummaryCacheStatus
    }

    func cachedPhotoSorterVLMSummary(for virtualPath: String) throws -> PhotoSorterMediaVLMCacheLookup {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let mountedAsset = try asset(at: normalized) else {
            return .unavailable("media asset not found")
        }
        guard mountedAsset.mediaType == .image else {
            return .unavailable("VLM supports images only")
        }
        let cacheKey = vlmCacheKey(for: mountedAsset)
        guard let lookup = vlmSummaryCache.lookup(for: cacheKey) else {
            return .miss
        }
        if lookup.requiresContentValidation {
            scheduleVLMContentValidation(for: mountedAsset, cacheKey: cacheKey)
        }
        return .hit(PhotoSorterMediaVLMSummaryResult(
            path: normalized,
            summary: lookup.summary,
            source: .cache
        ))
    }

    func cachedPhotoSorterVLMSummaries(for virtualPaths: [String]) -> [PhotoSorterMediaVLMCacheLookup] {
        guard !virtualPaths.isEmpty else {
            return []
        }
        let normalizedPaths = virtualPaths.map(Self.normalizeVirtualPath)
        let snapshot: PhotoLibraryIndexSnapshot
        do {
            snapshot = try currentIndexSnapshot(reason: "读取视觉摘要缓存")
        } catch {
            return normalizedPaths.map { _ in
                .unavailable(String(describing: error))
            }
        }

        return normalizedPaths.map { normalized in
            let mountedAsset = workspaceOverlay.snapshot.effectiveAsset(
                at: normalized,
                baseAsset: snapshot.asset(at: normalized)
            ) { identifier in
                Self.mountedAsset(localIdentifier: identifier, from: snapshot)
            }
            guard let mountedAsset else {
                return .unavailable("media asset not found")
            }
            guard mountedAsset.mediaType == .image else {
                return .unavailable("VLM supports images only")
            }
            guard let summary = vlmSummaryCache.summary(for: vlmCacheKey(for: mountedAsset)) else {
                return .miss
            }
            return .hit(PhotoSorterMediaVLMSummaryResult(
                path: normalized,
                summary: summary,
                source: .cache
            ))
        }
    }

    func summarizePhotoSorterMediaVLM(for virtualPath: String) async throws -> PhotoSorterMediaVLMSummaryResult? {
        let normalized = Self.normalizeVirtualPath(virtualPath)
        guard let mountedAsset = try asset(at: normalized) else {
            return nil
        }
        guard mountedAsset.mediaType == .image else {
            throw PhotoSorterMediaVLMError.unsupported("VLM supports images only")
        }
        return try await summarizeVLM(for: mountedAsset, outputPath: normalized)
    }
}

private struct PhotoLibraryChangeNotificationOutcome {
    var snapshot: PhotoLibraryIndexSnapshot
    var mode: PhotoLibraryIndexUpdateMode
    var diagnostics: [String: String]
}

private struct PhotoLibraryUpdatedAssetChangeVerification {
    var snapshot: PhotoLibraryIndexSnapshot
    var checkedAssetCount: Int
}

extension PhotoLibraryMount: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handlePhotoLibraryChangeNotification()
    }
}

protocol PhotoLibraryManifestProviding: AnyObject, Sendable {
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus
    func hasReadAccess() -> Bool
    func currentPhotoLibraryChangeTokenData() -> Data?
    func photoLibraryPersistentChanges(since tokenData: Data) throws -> PhotoLibraryPersistentChangeSummary?
    func resourceData(forLocalIdentifier localIdentifier: String) throws -> Data?
    func presentationUserAlbums() -> [PhotoLibraryMount.MountedAlbum]?
    func manifestAssetRecords(
        for localIdentifiers: Set<String>
    ) -> [String: PhotoLibraryManifestAssetRecord]
    func presentationAssetRecords(
        in virtualDirectoryPath: String,
        offset: Int,
        limit: Int?
    ) -> [PhotoLibraryManifestAssetRecord]?
    func makeManifest(
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void,
        hasPreviousSnapshot: Bool
    ) -> PhotoLibraryManifestScan
    func makeIncrementalManifest(
        previousSnapshot: PhotoLibraryIndexSnapshot,
        changes: PhotoLibraryPersistentChangeSummary,
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void
    ) throws -> PhotoLibraryManifestScan?
    func applyWorkspaceChanges(_ changeSet: PhotoLibraryWorkspaceSyncChangeSet) async throws
    func registerChangeObserver(_ observer: PHPhotoLibraryChangeObserver)
    func unregisterChangeObserver(_ observer: PHPhotoLibraryChangeObserver)
}

final class PhotoKitPhotoLibraryManifestProvider: PhotoLibraryManifestProviding, @unchecked Sendable {
    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let status = authorizationStatus()
        switch status {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { freshStatus in
                    continuation.resume(returning: freshStatus)
                }
            }
        default:
            return status
        }
    }

    func hasReadAccess() -> Bool {
        switch authorizationStatus() {
        case .authorized, .limited:
            return true
        case .notDetermined, .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func registerChangeObserver(_ observer: PHPhotoLibraryChangeObserver) {
        PHPhotoLibrary.shared().register(observer)
    }

    func unregisterChangeObserver(_ observer: PHPhotoLibraryChangeObserver) {
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
    }

    func currentPhotoLibraryChangeTokenData() -> Data? {
        Self.encodedChangeToken(PHPhotoLibrary.shared().currentChangeToken)
    }

    func photoLibraryPersistentChanges(since tokenData: Data) throws -> PhotoLibraryPersistentChangeSummary? {
        guard let token = Self.decodedChangeToken(from: tokenData) else {
            return nil
        }

        let fetchResult = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)

        var summary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: currentPhotoLibraryChangeTokenData()
        )
        for change in fetchResult {
            summary.changeCount += 1
            summary.latestTokenData = Self.encodedChangeToken(change.changeToken) ?? summary.latestTokenData

            let assetDetails = try change.changeDetails(for: PHObjectType.asset)
            summary.insertedAssetLocalIdentifiers.formUnion(assetDetails.insertedLocalIdentifiers)
            summary.updatedAssetLocalIdentifiers.formUnion(assetDetails.updatedLocalIdentifiers)
            summary.deletedAssetLocalIdentifiers.formUnion(assetDetails.deletedLocalIdentifiers)

            let assetCollectionDetails = try change.changeDetails(for: PHObjectType.assetCollection)
            summary.insertedAssetCollectionLocalIdentifiers.formUnion(assetCollectionDetails.insertedLocalIdentifiers)
            summary.updatedAssetCollectionLocalIdentifiers.formUnion(assetCollectionDetails.updatedLocalIdentifiers)
            summary.deletedAssetCollectionLocalIdentifiers.formUnion(assetCollectionDetails.deletedLocalIdentifiers)

            let collectionListDetails = try change.changeDetails(for: PHObjectType.collectionList)
            summary.insertedCollectionListLocalIdentifiers.formUnion(collectionListDetails.insertedLocalIdentifiers)
            summary.updatedCollectionListLocalIdentifiers.formUnion(collectionListDetails.updatedLocalIdentifiers)
            summary.deletedCollectionListLocalIdentifiers.formUnion(collectionListDetails.deletedLocalIdentifiers)
        }
        summary.latestTokenData = summary.latestTokenData ?? currentPhotoLibraryChangeTokenData()
        return summary
    }

    func resourceData(forLocalIdentifier localIdentifier: String) throws -> Data? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject else {
            return nil
        }
        guard let resource = Self.preferredResource(for: asset) else {
            return nil
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let state = PhotoLibraryResourceReadState()
        PHAssetResourceManager.default().requestData(
            for: resource,
            options: options
        ) { chunk in
            state.append(chunk)
        } completionHandler: { error in
            state.finish(error)
        }
        return try state.waitForResult()
    }

    func presentationUserAlbums() -> [PhotoLibraryMount.MountedAlbum]? {
        guard hasReadAccess() else {
            return nil
        }
        return fetchUserAlbumsFromPhotos()
    }

    func manifestAssetRecords(
        for localIdentifiers: Set<String>
    ) -> [String: PhotoLibraryManifestAssetRecord] {
        Self.manifestAssetRecords(for: localIdentifiers)
    }

    func presentationAssetRecords(
        in virtualDirectoryPath: String,
        offset: Int,
        limit: Int?
    ) -> [PhotoLibraryManifestAssetRecord]? {
        guard hasReadAccess(),
              let fetchResult = fetchResult(for: virtualDirectoryPath)
        else {
            return nil
        }

        let startIndex = min(max(offset, 0), fetchResult.count)
        let endIndex = limit
            .map { min(startIndex + max($0, 0), fetchResult.count) }
            ?? fetchResult.count
        guard startIndex < endIndex else {
            return []
        }

        return (startIndex..<endIndex).map { index in
            PhotoLibraryManifestAssetRecord(asset: fetchResult.object(at: index))
        }
    }

    func makeManifest(
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void,
        hasPreviousSnapshot: Bool
    ) -> PhotoLibraryManifestScan {
        let authorizationStatus = authorizationStatus()
        let canReadPhotos = hasReadAccess()
        let albums = canReadPhotos ? fetchUserAlbumsFromPhotos() : []
        var directories = makeBaseIndexDirectories(userAlbums: albums)
        var assetRecordsByLocalIdentifier: [String: PhotoLibraryManifestAssetRecord] = [:]
        let assetDirectoryPaths = ["/图库"]
            + PhotoLibraryMount.systemAlbumDirectoryPaths
            + albums.map(\.virtualPath)

        let fetchResults: [(String, PHFetchResult<PHAsset>)] = canReadPhotos
            ? assetDirectoryPaths.compactMap { path in
                fetchResult(for: path, userAlbums: albums).map { (path, $0) }
            }
            : []
        let total = fetchResults.reduce(0) { $0 + $1.1.count }
        var processed = 0
        progress(PhotoLibraryIndexBuildProgress(
            phase: hasPreviousSnapshot ? .validating : .building,
            processed: processed,
            total: total,
            currentPath: nil,
            message: hasPreviousSnapshot ? "校验照片库索引" : "建立照片库索引"
        ))

        for (path, fetchResult) in fetchResults {
            var localIdentifiers: [String] = []
            localIdentifiers.reserveCapacity(fetchResult.count)
            var index = 0
            while index < fetchResult.count {
                let batchEnd = min(index + Self.manifestBatchSize, fetchResult.count)
                let batch = (index..<batchEnd).map { fetchResult.object(at: $0) }
                for asset in batch {
                    localIdentifiers.append(asset.localIdentifier)
                    assetRecordsByLocalIdentifier[asset.localIdentifier] = PhotoLibraryManifestAssetRecord(
                        localIdentifier: asset.localIdentifier,
                        fileExtension: Self.fileExtension(for: asset),
                        mediaTypeRawValue: asset.mediaType.rawValue,
                        mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        creationDate: asset.creationDate,
                        modificationDate: asset.modificationDate,
                        locationLatitude: asset.location?.coordinate.latitude,
                        locationLongitude: asset.location?.coordinate.longitude,
                        locationHorizontalAccuracy: asset.location?.horizontalAccuracy
                    )
                }
                processed += batch.count
                progress(PhotoLibraryIndexBuildProgress(
                    phase: hasPreviousSnapshot ? .validating : .building,
                    processed: processed,
                    total: total,
                    currentPath: path,
                    message: hasPreviousSnapshot ? "校验 \(path)" : "同步 \(path)"
                ))
                index = batchEnd
            }
            directories[path]?.assetLocalIdentifiers = localIdentifiers
        }

        return PhotoLibraryManifestScan(
            authorizationStatusRawValue: authorizationStatus.rawValue,
            libraryScopeFingerprint: Self.libraryScopeFingerprint(for: authorizationStatus),
            directories: directories,
            assetRecords: assetRecordsByLocalIdentifier,
            photosFetchCount: fetchResults.count,
            indexedAssetMembershipCount: total
        )
    }

    func makeIncrementalManifest(
        previousSnapshot: PhotoLibraryIndexSnapshot,
        changes: PhotoLibraryPersistentChangeSummary,
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void
    ) throws -> PhotoLibraryManifestScan? {
        guard hasReadAccess(),
              previousSnapshot.authorizationStatusRawValue == authorizationStatus().rawValue
        else {
            return nil
        }

        progress(PhotoLibraryIndexBuildProgress(
            phase: .refreshing,
            processed: 0,
            total: changes.approximateChangedObjectCount,
            currentPath: nil,
            message: "读取系统照片库变更"
        ))

        let shouldRefreshUserAlbums = changes.hasAssetCollectionChanges || changes.hasCollectionListChanges
        let userAlbums = shouldRefreshUserAlbums
            ? fetchUserAlbumsFromPhotos()
            : previousSnapshot.userAlbums
        var directories = shouldRefreshUserAlbums
            ? makeBaseIndexDirectories(userAlbums: userAlbums)
            : previousSnapshot.directories
        preserveUnchangedMemberships(
            in: &directories,
            previousSnapshot: previousSnapshot,
            userAlbumsRefreshed: shouldRefreshUserAlbums
        )

        var assetRecords = previousSnapshot.assetsByLocalIdentifier.mapValues {
            PhotoLibraryManifestAssetRecord(indexedAsset: $0)
        }
        for localIdentifier in changes.deletedAssetLocalIdentifiers {
            assetRecords.removeValue(forKey: localIdentifier)
        }
        removeDeletedAssets(changes.deletedAssetLocalIdentifiers, from: &directories)

        let changedAssetIdentifiers = changes.insertedAssetLocalIdentifiers
            .union(changes.updatedAssetLocalIdentifiers)
            .subtracting(changes.deletedAssetLocalIdentifiers)
        if !changedAssetIdentifiers.isEmpty {
            let changedRecords = Self.manifestAssetRecords(for: changedAssetIdentifiers)
            assetRecords.merge(changedRecords) { _, fresh in fresh }
        }

        var pathsToRefresh = Set<String>()
        if changes.hasAssetChanges {
            pathsToRefresh.formUnion(Self.assetChangeSensitiveDirectoryPaths)
        }
        if shouldRefreshUserAlbums {
            pathsToRefresh.formUnion(userAlbums.map(\.virtualPath))
        }

        var processed = 0
        let total = max(pathsToRefresh.count + changedAssetIdentifiers.count, 1)
        for path in pathsToRefresh.sorted() {
            guard let identifiers = assetLocalIdentifiers(in: path, userAlbums: userAlbums) else {
                return nil
            }
            directories[path]?.assetLocalIdentifiers = identifiers
            let missingIdentifiers = Set(identifiers).subtracting(assetRecords.keys)
            if !missingIdentifiers.isEmpty {
                let missingRecords = Self.manifestAssetRecords(for: missingIdentifiers)
                assetRecords.merge(missingRecords) { _, fresh in fresh }
            }
            processed += 1
            progress(PhotoLibraryIndexBuildProgress(
                phase: .refreshing,
                processed: min(processed, total),
                total: total,
                currentPath: path,
                message: "增量刷新 \(path)"
            ))
        }

        sortDirectoryMemberships(&directories, using: assetRecords)
        let indexedMembershipCount = directories.values.reduce(0) { total, directory in
            total + directory.assetLocalIdentifiers.count
        }
        progress(PhotoLibraryIndexBuildProgress(
            phase: .refreshing,
            processed: total,
            total: total,
            currentPath: nil,
            message: "照片库变更已增量合并"
        ))

        return PhotoLibraryManifestScan(
            authorizationStatusRawValue: authorizationStatus().rawValue,
            libraryScopeFingerprint: Self.libraryScopeFingerprint(for: authorizationStatus()),
            directories: directories,
            assetRecords: assetRecords,
            photosFetchCount: pathsToRefresh.count,
            indexedAssetMembershipCount: indexedMembershipCount
        )
    }

    func applyWorkspaceChanges(_ changeSet: PhotoLibraryWorkspaceSyncChangeSet) async throws {
        guard !changeSet.isEmpty else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                var albumCreationRequestsByPath: [String: PHAssetCollectionChangeRequest] = [:]
                for album in changeSet.createdAlbums {
                    albumCreationRequestsByPath[album.virtualPath] = PHAssetCollectionChangeRequest
                        .creationRequestForAssetCollection(withTitle: album.name)
                }

                for change in changeSet.membershipAdditions {
                    let fetchResult = PHAsset.fetchAssets(
                        withLocalIdentifiers: change.assetLocalIdentifiers,
                        options: nil
                    )
                    guard fetchResult.count > 0 else {
                        continue
                    }
                    if let albumLocalIdentifier = change.albumLocalIdentifier,
                       let collection = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [albumLocalIdentifier],
                        options: nil
                       ).firstObject {
                        PHAssetCollectionChangeRequest(for: collection)?.addAssets(fetchResult)
                    } else {
                        albumCreationRequestsByPath[change.albumVirtualPath]?.addAssets(fetchResult)
                    }
                }

                for change in changeSet.membershipRemovals {
                    guard let albumLocalIdentifier = change.albumLocalIdentifier else {
                        continue
                    }
                    let fetchResult = PHAsset.fetchAssets(
                        withLocalIdentifiers: change.assetLocalIdentifiers,
                        options: nil
                    )
                    guard fetchResult.count > 0,
                          let collection = PHAssetCollection.fetchAssetCollections(
                            withLocalIdentifiers: [albumLocalIdentifier],
                            options: nil
                          ).firstObject
                    else {
                        continue
                    }
                    PHAssetCollectionChangeRequest(for: collection)?.removeAssets(fetchResult)
                }

                let deletedAlbumIdentifiers = changeSet.deletedAlbums.compactMap(\.albumLocalIdentifier)
                if !deletedAlbumIdentifiers.isEmpty {
                    let fetchResult = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: deletedAlbumIdentifiers,
                        options: nil
                    )
                    if fetchResult.count > 0 {
                        PHAssetCollectionChangeRequest.deleteAssetCollections(fetchResult)
                    }
                }

                if !changeSet.trashedAssetLocalIdentifiers.isEmpty {
                    let fetchResult = PHAsset.fetchAssets(
                        withLocalIdentifiers: changeSet.trashedAssetLocalIdentifiers,
                        options: nil
                    )
                    if fetchResult.count > 0 {
                        PHAssetChangeRequest.deleteAssets(fetchResult)
                    }
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.userCancelled))
                }
            }
        }
    }

    private func makeBaseIndexDirectories(userAlbums: [PhotoLibraryMount.MountedAlbum]) -> [String: PhotoLibraryIndexDirectory] {
        var directories: [String: PhotoLibraryIndexDirectory] = [:]
        func addDirectory(
            name: String,
            path: String,
            parentPath: String?,
            collectionLocalIdentifier: String? = nil,
            childDirectoryPaths: [String] = []
        ) {
            directories[path] = PhotoLibraryIndexDirectory(
                name: name,
                path: path,
                parentPath: parentPath,
                collectionLocalIdentifier: collectionLocalIdentifier,
                childDirectoryPaths: childDirectoryPaths,
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: !childDirectoryPaths.isEmpty
            )
        }

        let systemPaths = PhotoLibraryMount.systemAlbumDirectoryPaths
        addDirectory(
            name: "图库",
            path: "/图库",
            parentPath: "/"
        )
        addDirectory(
            name: "相册",
            path: PhotoLibraryMount.albumRootPath,
            parentPath: "/",
            childDirectoryPaths: [PhotoLibraryMount.systemAlbumRootPath, PhotoLibraryMount.userAlbumRootPath]
        )
        addDirectory(
            name: "系统",
            path: PhotoLibraryMount.systemAlbumRootPath,
            parentPath: PhotoLibraryMount.albumRootPath,
            childDirectoryPaths: systemPaths
        )
        addDirectory(
            name: "用户",
            path: PhotoLibraryMount.userAlbumRootPath,
            parentPath: PhotoLibraryMount.albumRootPath,
            childDirectoryPaths: userAlbums.map(\.virtualPath)
        )
        for (name, path) in zip(PhotoLibraryMount.systemAlbumDirectories, systemPaths) {
            addDirectory(
                name: name,
                path: path,
                parentPath: PhotoLibraryMount.systemAlbumRootPath
            )
        }
        for album in userAlbums {
            addDirectory(
                name: album.name,
                path: album.virtualPath,
                parentPath: PhotoLibraryMount.userAlbumRootPath,
                collectionLocalIdentifier: album.localIdentifier
            )
        }
        return directories
    }

    private func fetchUserAlbumsFromPhotos() -> [PhotoLibraryMount.MountedAlbum] {
        guard hasReadAccess() else {
            return []
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: fetchOptions
        )

        var usedNames = Set<String>()
        var albums: [PhotoLibraryMount.MountedAlbum] = []
        collections.enumerateObjects { collection, _, _ in
            let baseName = PhotoLibraryMount.sanitizedPathComponent(collection.localizedTitle ?? "未命名相册")
            let name = PhotoLibraryMount.uniqued(baseName, usedNames: &usedNames)
            albums.append(
                PhotoLibraryMount.MountedAlbum(
                    name: name,
                    virtualPath: PhotoLibraryMount.join(PhotoLibraryMount.userAlbumRootPath, name),
                    localIdentifier: collection.localIdentifier
                )
            )
        }
        return albums
    }

    private func fetchResult(
        for virtualDirectoryPath: String,
        userAlbums: [PhotoLibraryMount.MountedAlbum]? = nil
    ) -> PHFetchResult<PHAsset>? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(virtualDirectoryPath)
        switch normalized {
        case "/图库":
            return smartAlbumAssets(.smartAlbumUserLibrary)
        default:
            if let subtype = PhotoLibraryMount.systemAlbumSubtype(for: normalized) {
                return smartAlbumAssets(subtype)
            }
            guard normalized.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/"),
                  let album = (userAlbums ?? fetchUserAlbumsFromPhotos()).first(where: { $0.virtualPath == normalized }),
                  let collection = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [album.localIdentifier],
                    options: nil
                  ).firstObject
            else {
                return nil
            }
            return assets(in: collection)
        }
    }

    private func smartAlbumAssets(_ subtype: PHAssetCollectionSubtype) -> PHFetchResult<PHAsset>? {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: subtype,
            options: nil
        )
        guard let collection = collections.firstObject else {
            return nil
        }
        return assets(in: collection)
    }

    private func assetLocalIdentifiers(
        in virtualDirectoryPath: String,
        userAlbums: [PhotoLibraryMount.MountedAlbum]
    ) -> [String]? {
        guard let fetchResult = fetchResult(for: virtualDirectoryPath, userAlbums: userAlbums) else {
            return nil
        }
        var identifiers: [String] = []
        identifiers.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            identifiers.append(asset.localIdentifier)
        }
        return identifiers
    }

    private func assets(in collection: PHAssetCollection) -> PHFetchResult<PHAsset> {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        return PHAsset.fetchAssets(in: collection, options: fetchOptions)
    }

    static func fileExtension(for asset: PHAsset) -> String {
        let resourceName = PHAssetResource.assetResources(for: asset)
            .first?
            .originalFilename
        if let ext = resourceName.flatMap({ URL(fileURLWithPath: $0).pathExtension.lowercased() }),
           !ext.isEmpty {
            return ext
        }
        switch asset.mediaType {
        case .video:
            return "mov"
        case .image:
            return asset.mediaSubtypes.contains(.photoScreenshot) ? "png" : "jpg"
        default:
            return "dat"
        }
    }

    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .image:
            return resources.first { $0.type == .fullSizePhoto }
                ?? resources.first { $0.type == .photo }
                ?? resources.first
        case .video:
            return resources.first { $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .video }
                ?? resources.first
        default:
            return resources.first
        }
    }

    private static func manifestAssetRecords(
        for localIdentifiers: Set<String>
    ) -> [String: PhotoLibraryManifestAssetRecord] {
        guard !localIdentifiers.isEmpty else {
            return [:]
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(localIdentifiers), options: nil)
        var records: [String: PhotoLibraryManifestAssetRecord] = [:]
        records.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            records[asset.localIdentifier] = PhotoLibraryManifestAssetRecord(asset: asset)
        }
        return records
    }

    private func preserveUnchangedMemberships(
        in directories: inout [String: PhotoLibraryIndexDirectory],
        previousSnapshot: PhotoLibraryIndexSnapshot,
        userAlbumsRefreshed: Bool
    ) {
        for (path, previousDirectory) in previousSnapshot.directories {
            guard var directory = directories[path],
                  directory.collectionLocalIdentifier == nil
            else {
                continue
            }
            directory.assetLocalIdentifiers = previousDirectory.assetLocalIdentifiers
            directories[path] = directory
        }

        let previousAlbumDirectoriesByIdentifier = Dictionary(
            uniqueKeysWithValues: previousSnapshot.directories.values.compactMap { directory in
                directory.collectionLocalIdentifier.map { ($0, directory) }
            }
        )
        for path in Array(directories.keys) {
            guard var directory = directories[path],
                  let localIdentifier = directory.collectionLocalIdentifier,
                  let previousDirectory = previousAlbumDirectoriesByIdentifier[localIdentifier]
            else {
                continue
            }
            directory.assetLocalIdentifiers = userAlbumsRefreshed
                ? []
                : previousDirectory.assetLocalIdentifiers
            directories[path] = directory
        }
    }

    private func removeDeletedAssets(
        _ localIdentifiers: Set<String>,
        from directories: inout [String: PhotoLibraryIndexDirectory]
    ) {
        guard !localIdentifiers.isEmpty else {
            return
        }
        for path in Array(directories.keys) {
            guard var directory = directories[path],
                  !directory.assetLocalIdentifiers.isEmpty
            else {
                continue
            }
            directory.assetLocalIdentifiers.removeAll { localIdentifiers.contains($0) }
            directories[path] = directory
        }
    }

    private func sortDirectoryMemberships(
        _ directories: inout [String: PhotoLibraryIndexDirectory],
        using assetRecords: [String: PhotoLibraryManifestAssetRecord]
    ) {
        for path in Array(directories.keys) {
            guard var directory = directories[path],
                  directory.assetLocalIdentifiers.count > 1
            else {
                continue
            }
            directory.assetLocalIdentifiers.sort { lhs, rhs in
                Self.assetSortPrecedes(lhs, rhs, records: assetRecords)
            }
            directories[path] = directory
        }
    }

    private static func assetSortPrecedes(
        _ lhs: String,
        _ rhs: String,
        records: [String: PhotoLibraryManifestAssetRecord]
    ) -> Bool {
        let lhsDate = records[lhs]?.creationDate
        let rhsDate = records[rhs]?.creationDate
        if lhsDate != rhsDate {
            guard let lhsDate else {
                return false
            }
            guard let rhsDate else {
                return true
            }
            return lhsDate > rhsDate
        }
        return lhs < rhs
    }

    private static func encodedChangeToken(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodedChangeToken(from data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private static func libraryScopeFingerprint(for authorizationStatus: PHAuthorizationStatus) -> String {
        "authorization:\(authorizationStatus.rawValue)"
    }

    private static let assetChangeSensitiveDirectoryPaths = [
        "/图库"
    ] + PhotoLibraryMount.systemAlbumDirectoryPaths

    private static let manifestBatchSize = 500
}

struct PhotoLibraryManifestScan {
    var authorizationStatusRawValue: Int
    var libraryScopeFingerprint: String
    var directories: [String: PhotoLibraryIndexDirectory]
    var assetRecords: [String: PhotoLibraryManifestAssetRecord]
    var photosFetchCount: Int
    var indexedAssetMembershipCount: Int

    func orderedUniqueAssetRecords() -> [PhotoLibraryManifestAssetRecord] {
        var seen = Set<String>()
        var records: [PhotoLibraryManifestAssetRecord] = []
        records.reserveCapacity(assetRecords.count)
        for path in stableDirectoryTraversalOrder() {
            guard let directory = directories[path] else {
                continue
            }
            for localIdentifier in directory.assetLocalIdentifiers where seen.insert(localIdentifier).inserted {
                guard let record = assetRecords[localIdentifier] else {
                    continue
                }
                records.append(record)
            }
        }
        for localIdentifier in assetRecords.keys.sorted() where seen.insert(localIdentifier).inserted {
            guard let record = assetRecords[localIdentifier] else {
                continue
            }
            records.append(record)
        }
        return records
    }

    private func stableDirectoryTraversalOrder() -> [String] {
        var orderedPaths: [String] = []
        var seen = Set<String>()

        func appendTree(_ path: String) {
            guard seen.insert(path).inserted else {
                return
            }
            orderedPaths.append(path)
            for childPath in directories[path]?.childDirectoryPaths ?? [] {
                appendTree(childPath)
            }
        }

        appendTree("/图库")
        appendTree(PhotoLibraryMount.albumRootPath)
        for path in directories.keys.sorted() where !seen.contains(path) {
            appendTree(path)
        }
        return orderedPaths
    }

    func diagnosticsFields(
        mode: PhotoLibraryIndexUpdateMode,
        summary: PhotoLibraryManifestChangeSummary?,
        startedAt: Date
    ) -> [String: String] {
        var fields: [String: String] = [
            "mode": mode.rawValue,
            "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            "authorization_status": "\(authorizationStatusRawValue)",
            "library_scope_fingerprint": libraryScopeFingerprint,
            "directory_count": "\(directories.count)",
            "asset_count": "\(assetRecords.count)",
            "indexed_asset_membership_count": "\(indexedAssetMembershipCount)",
            "photos_fetch_count": "\(photosFetchCount)"
        ]
        if let summary {
            fields.merge(summary.diagnosticsFields) { _, fresh in fresh }
        }
        return fields
    }
}

struct PhotoLibraryPersistentChangeSummary: Sendable, Equatable {
    var latestTokenData: Data?
    var changeCount = 0
    var insertedAssetLocalIdentifiers = Set<String>()
    var updatedAssetLocalIdentifiers = Set<String>()
    var deletedAssetLocalIdentifiers = Set<String>()
    var insertedAssetCollectionLocalIdentifiers = Set<String>()
    var updatedAssetCollectionLocalIdentifiers = Set<String>()
    var deletedAssetCollectionLocalIdentifiers = Set<String>()
    var insertedCollectionListLocalIdentifiers = Set<String>()
    var updatedCollectionListLocalIdentifiers = Set<String>()
    var deletedCollectionListLocalIdentifiers = Set<String>()

    var hasAssetChanges: Bool {
        !insertedAssetLocalIdentifiers.isEmpty
            || !updatedAssetLocalIdentifiers.isEmpty
            || !deletedAssetLocalIdentifiers.isEmpty
    }

    var hasAssetCollectionChanges: Bool {
        !insertedAssetCollectionLocalIdentifiers.isEmpty
            || !updatedAssetCollectionLocalIdentifiers.isEmpty
            || !deletedAssetCollectionLocalIdentifiers.isEmpty
    }

    var hasCollectionListChanges: Bool {
        !insertedCollectionListLocalIdentifiers.isEmpty
            || !updatedCollectionListLocalIdentifiers.isEmpty
            || !deletedCollectionListLocalIdentifiers.isEmpty
    }

    var hasRelevantChanges: Bool {
        hasAssetChanges || hasAssetCollectionChanges || hasCollectionListChanges
    }

    var hasOnlyUpdatedAssetChanges: Bool {
        !updatedAssetLocalIdentifiers.isEmpty
            && insertedAssetLocalIdentifiers.isEmpty
            && deletedAssetLocalIdentifiers.isEmpty
            && !hasAssetCollectionChanges
            && !hasCollectionListChanges
    }

    var approximateChangedObjectCount: Int {
        insertedAssetLocalIdentifiers.count
            + updatedAssetLocalIdentifiers.count
            + deletedAssetLocalIdentifiers.count
            + insertedAssetCollectionLocalIdentifiers.count
            + updatedAssetCollectionLocalIdentifiers.count
            + deletedAssetCollectionLocalIdentifiers.count
            + insertedCollectionListLocalIdentifiers.count
            + updatedCollectionListLocalIdentifiers.count
            + deletedCollectionListLocalIdentifiers.count
    }

    func diagnosticsFields(
        mode: PhotoLibraryIndexUpdateMode,
        startedAt: Date
    ) -> [String: String] {
        [
            "mode": mode.rawValue,
            "duration_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            "persistent_change_count": "\(changeCount)",
            "inserted_asset_count": "\(insertedAssetLocalIdentifiers.count)",
            "updated_asset_count": "\(updatedAssetLocalIdentifiers.count)",
            "deleted_asset_count": "\(deletedAssetLocalIdentifiers.count)",
            "inserted_asset_collection_count": "\(insertedAssetCollectionLocalIdentifiers.count)",
            "updated_asset_collection_count": "\(updatedAssetCollectionLocalIdentifiers.count)",
            "deleted_asset_collection_count": "\(deletedAssetCollectionLocalIdentifiers.count)",
            "inserted_collection_list_count": "\(insertedCollectionListLocalIdentifiers.count)",
            "updated_collection_list_count": "\(updatedCollectionListLocalIdentifiers.count)",
            "deleted_collection_list_count": "\(deletedCollectionListLocalIdentifiers.count)"
        ]
    }
}

struct PhotoLibraryManifestAssetRecord {
    var localIdentifier: String
    var fileExtension: String
    var mediaTypeRawValue: Int
    var mediaSubtypesRawValue: UInt
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date?
    var locationLatitude: Double?
    var locationLongitude: Double?
    var locationHorizontalAccuracy: Double?

    init(
        localIdentifier: String,
        fileExtension: String,
        mediaTypeRawValue: Int,
        mediaSubtypesRawValue: UInt,
        pixelWidth: Int,
        pixelHeight: Int,
        creationDate: Date?,
        modificationDate: Date?,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        locationHorizontalAccuracy: Double? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.fileExtension = fileExtension
        self.mediaTypeRawValue = mediaTypeRawValue
        self.mediaSubtypesRawValue = mediaSubtypesRawValue
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.locationHorizontalAccuracy = locationHorizontalAccuracy
    }

    init(indexedAsset: PhotoLibraryIndexAsset) {
        self.init(
            localIdentifier: indexedAsset.localIdentifier,
            fileExtension: indexedAsset.fileExtension,
            mediaTypeRawValue: indexedAsset.mediaTypeRawValue,
            mediaSubtypesRawValue: indexedAsset.mediaSubtypesRawValue,
            pixelWidth: indexedAsset.pixelWidth,
            pixelHeight: indexedAsset.pixelHeight,
            creationDate: indexedAsset.creationDate,
            modificationDate: indexedAsset.modificationDate,
            locationLatitude: indexedAsset.locationLatitude,
            locationLongitude: indexedAsset.locationLongitude,
            locationHorizontalAccuracy: indexedAsset.locationHorizontalAccuracy
        )
    }

    init(asset: PHAsset) {
        let location = asset.location
        self.init(
            localIdentifier: asset.localIdentifier,
            fileExtension: PhotoKitPhotoLibraryManifestProvider.fileExtension(for: asset),
            mediaTypeRawValue: asset.mediaType.rawValue,
            mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            locationLatitude: location?.coordinate.latitude,
            locationLongitude: location?.coordinate.longitude,
            locationHorizontalAccuracy: location?.horizontalAccuracy
        )
    }

    func metadataMatches(_ indexedAsset: PhotoLibraryIndexAsset) -> Bool {
        indexedAsset.mediaTypeRawValue == mediaTypeRawValue
            && indexedAsset.mediaSubtypesRawValue == mediaSubtypesRawValue
            && indexedAsset.pixelWidth == pixelWidth
            && indexedAsset.pixelHeight == pixelHeight
            && indexedAsset.fileExtension == fileExtension
            && indexedAsset.creationDate == creationDate
            && indexedAsset.modificationDate == modificationDate
            && indexedAsset.locationLatitude == locationLatitude
            && indexedAsset.locationLongitude == locationLongitude
            && indexedAsset.locationHorizontalAccuracy == locationHorizontalAccuracy
    }
}

struct PhotoLibraryManifestChangeSummary {
    var authorizationChanged = false
    var libraryScopeChanged = false
    var unchangedDirectoryCount = 0
    var unchangedDirectoryPaths: [String] = []
    var addedDirectoryPaths: [String] = []
    var removedDirectoryPaths: [String] = []
    var changedDirectoryPaths: [String] = []
    var addedAssetIdentifiers: [String] = []
    var removedAssetIdentifiers: [String] = []
    var metadataChangedAssetIdentifiers: [String] = []

    init(previousSnapshot: PhotoLibraryIndexSnapshot, scan: PhotoLibraryManifestScan) {
        authorizationChanged = previousSnapshot.authorizationStatusRawValue != scan.authorizationStatusRawValue
        libraryScopeChanged = previousSnapshot.libraryScopeFingerprint != scan.libraryScopeFingerprint

        let previousDirectoryPaths = Set(previousSnapshot.directories.keys)
        let currentDirectoryPaths = Set(scan.directories.keys)
        addedDirectoryPaths = Array(currentDirectoryPaths.subtracting(previousDirectoryPaths)).sorted()
        removedDirectoryPaths = Array(previousDirectoryPaths.subtracting(currentDirectoryPaths)).sorted()

        for path in previousDirectoryPaths.intersection(currentDirectoryPaths).sorted() {
            guard let previous = previousSnapshot.directories[path],
                  let current = scan.directories[path]
            else {
                continue
            }
            if previous.name != current.name
                || previous.parentPath != current.parentPath
                || previous.collectionLocalIdentifier != current.collectionLocalIdentifier
                || previous.childDirectoryPaths != current.childDirectoryPaths
                || previous.assetLocalIdentifiers != current.assetLocalIdentifiers {
                changedDirectoryPaths.append(path)
            } else {
                unchangedDirectoryCount += 1
                unchangedDirectoryPaths.append(path)
            }
        }

        let previousAssetIdentifiers = Set(previousSnapshot.assetsByLocalIdentifier.keys)
        let currentAssetIdentifiers = Set(scan.assetRecords.keys)
        addedAssetIdentifiers = Array(currentAssetIdentifiers.subtracting(previousAssetIdentifiers)).sorted()
        removedAssetIdentifiers = Array(previousAssetIdentifiers.subtracting(currentAssetIdentifiers)).sorted()

        for identifier in previousAssetIdentifiers.intersection(currentAssetIdentifiers).sorted() {
            guard let previous = previousSnapshot.assetsByLocalIdentifier[identifier],
                  let current = scan.assetRecords[identifier],
                  !current.metadataMatches(previous)
            else {
                continue
            }
            metadataChangedAssetIdentifiers.append(identifier)
        }
    }

    var hasChanges: Bool {
        authorizationChanged
            || libraryScopeChanged
            || !addedDirectoryPaths.isEmpty
            || !removedDirectoryPaths.isEmpty
            || !changedDirectoryPaths.isEmpty
            || !addedAssetIdentifiers.isEmpty
            || !removedAssetIdentifiers.isEmpty
            || !metadataChangedAssetIdentifiers.isEmpty
    }

    var diagnosticsFields: [String: String] {
        [
            "authorization_changed": "\(authorizationChanged)",
            "library_scope_changed": "\(libraryScopeChanged)",
            "unchanged_directory_count": "\(unchangedDirectoryCount)",
            "added_directory_count": "\(addedDirectoryPaths.count)",
            "removed_directory_count": "\(removedDirectoryPaths.count)",
            "changed_directory_count": "\(changedDirectoryPaths.count)",
            "added_asset_count": "\(addedAssetIdentifiers.count)",
            "removed_asset_count": "\(removedAssetIdentifiers.count)",
            "metadata_changed_asset_count": "\(metadataChangedAssetIdentifiers.count)",
            "unchanged_directory_paths": unchangedDirectoryPaths.prefix(20).joined(separator: ","),
            "changed_directory_paths": changedDirectoryPaths.prefix(20).joined(separator: ",")
        ]
    }
}

private extension Array {
    func sliced(offset: Int, limit: Int?) -> [Element] {
        let startIndex = Swift.min(Swift.max(offset, 0), count)
        let endIndex = limit.map { Swift.min(startIndex + Swift.max($0, 0), count) } ?? count
        guard startIndex < endIndex else {
            return []
        }
        return Array(self[startIndex..<endIndex])
    }
}

private extension PHFetchResult where ObjectType == PHAsset {
    func containsAsset(withLocalIdentifier localIdentifier: String) -> Bool {
        for index in 0..<count where object(at: index).localIdentifier == localIdentifier {
            return true
        }
        return false
    }
}
