import ModelShellProxy
import MSPCore

struct PhotoSorterCommandPack: MSPCommandPack {
    var name: String { "photosorter" }

    private let mediaProvider: any PhotoSorterMediaMetadataProviding
    private let mediaLister: (any PhotoSorterMediaListing)?
    private let mediaStatsProvider: (any PhotoSorterMediaStatsProviding)?
    private let ocrProvider: (any PhotoSorterMediaOCRProviding)?
    private let vlmProvider: (any PhotoSorterVLMProviding)?
    private let imageProvider: (any PhotoSorterMediaImageProviding)?
    private let reviewProvider: (any PhotoSorterMediaReviewProviding)?
    private let askExclusionTracker: (any PhotoSorterMediaAskExclusionTracking)?
    private let albumManager: (any PhotoSorterAlbumManaging)?
    private let assetTrashBatcher: (any PhotoSorterAssetTrashBatching)?
    private let assetTrashRestorer: (any PhotoSorterAssetTrashRestoring)?
    private let cacheStatusProvider: (any PhotoSorterMediaCacheStatusProviding)?
    private let fileTreeSnapshotProvider: (any PhotoSorterFileTreeSnapshotProviding)?
    private let agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding
    private let sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding
    private let mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)?
    private let mediaPreviewLoadTimeoutNanoseconds: UInt64

    init(
        mediaProvider: any PhotoSorterMediaMetadataProviding,
        mediaLister: (any PhotoSorterMediaListing)? = nil,
        mediaStatsProvider: (any PhotoSorterMediaStatsProviding)? = nil,
        ocrProvider: (any PhotoSorterMediaOCRProviding)? = nil,
        vlmProvider: (any PhotoSorterVLMProviding)? = nil,
        imageProvider: (any PhotoSorterMediaImageProviding)? = nil,
        reviewProvider: (any PhotoSorterMediaReviewProviding)? = nil,
        askExclusionTracker: (any PhotoSorterMediaAskExclusionTracking)? = nil,
        albumManager: (any PhotoSorterAlbumManaging)? = nil,
        assetTrashBatcher: (any PhotoSorterAssetTrashBatching)? = nil,
        assetTrashRestorer: (any PhotoSorterAssetTrashRestoring)? = nil,
        cacheStatusProvider: (any PhotoSorterMediaCacheStatusProviding)? = nil,
        fileTreeSnapshotProvider: (any PhotoSorterFileTreeSnapshotProviding)? = nil,
        agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding = PhotoSorterAgentAccessModeState(),
        sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding = PhotoSorterSensitiveReadPolicyState(),
        mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)? = nil,
        mediaPreviewLoadTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.mediaProvider = mediaProvider
        self.mediaLister = mediaLister ?? (mediaProvider as? any PhotoSorterMediaListing)
        self.mediaStatsProvider = mediaStatsProvider ?? (mediaProvider as? any PhotoSorterMediaStatsProviding)
        self.ocrProvider = ocrProvider ?? (mediaProvider as? any PhotoSorterMediaOCRProviding)
        self.vlmProvider = vlmProvider ?? (mediaProvider as? any PhotoSorterVLMProviding)
        self.imageProvider = imageProvider ?? (mediaProvider as? any PhotoSorterMediaImageProviding)
        self.reviewProvider = reviewProvider ?? (mediaProvider as? any PhotoSorterMediaReviewProviding)
        self.askExclusionTracker = askExclusionTracker ?? (mediaProvider as? any PhotoSorterMediaAskExclusionTracking)
        self.albumManager = albumManager ?? (mediaProvider as? any PhotoSorterAlbumManaging)
        self.assetTrashBatcher = assetTrashBatcher ?? (mediaProvider as? any PhotoSorterAssetTrashBatching)
        self.assetTrashRestorer = assetTrashRestorer ?? (mediaProvider as? any PhotoSorterAssetTrashRestoring)
        self.cacheStatusProvider = cacheStatusProvider ?? (mediaProvider as? any PhotoSorterMediaCacheStatusProviding)
        self.fileTreeSnapshotProvider = fileTreeSnapshotProvider ?? (mediaProvider as? any PhotoSorterFileTreeSnapshotProviding)
        self.agentAccessModeProvider = agentAccessModeProvider
        self.sensitiveReadPolicyProvider = sensitiveReadPolicyProvider
        self.mediaViewAuthorizer = mediaViewAuthorizer
        self.mediaPreviewLoadTimeoutNanoseconds = mediaPreviewLoadTimeoutNanoseconds
    }

    init(
        photoLibraryMount: PhotoLibraryMount,
        agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding,
        sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding,
        mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)? = nil,
        mediaPreviewLoadTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.mediaProvider = photoLibraryMount
        self.mediaLister = photoLibraryMount
        self.mediaStatsProvider = photoLibraryMount
        self.ocrProvider = photoLibraryMount
        self.vlmProvider = photoLibraryMount
        self.imageProvider = photoLibraryMount
        self.reviewProvider = photoLibraryMount
        self.askExclusionTracker = photoLibraryMount
        self.albumManager = photoLibraryMount
        self.assetTrashBatcher = photoLibraryMount
        self.assetTrashRestorer = photoLibraryMount
        self.cacheStatusProvider = photoLibraryMount
        self.fileTreeSnapshotProvider = photoLibraryMount
        self.agentAccessModeProvider = agentAccessModeProvider
        self.sensitiveReadPolicyProvider = sensitiveReadPolicyProvider
        self.mediaViewAuthorizer = mediaViewAuthorizer
        self.mediaPreviewLoadTimeoutNanoseconds = mediaPreviewLoadTimeoutNanoseconds
    }

    func registerCommands(into registry: MSPCommandRegistry) throws {
        try registry.register(PhotoSorterMediaCommand(
            mediaProvider: mediaProvider,
            mediaLister: mediaLister,
            mediaStatsProvider: mediaStatsProvider,
            ocrProvider: ocrProvider,
            vlmProvider: vlmProvider,
            imageProvider: imageProvider,
            reviewProvider: reviewProvider,
            askExclusionTracker: askExclusionTracker,
            assetTrashBatcher: assetTrashBatcher,
            assetTrashRestorer: assetTrashRestorer,
            cacheStatusProvider: cacheStatusProvider,
            agentAccessModeProvider: agentAccessModeProvider,
            sensitiveReadPolicyProvider: sensitiveReadPolicyProvider,
            mediaViewAuthorizer: mediaViewAuthorizer,
            mediaPreviewLoadTimeoutNanoseconds: mediaPreviewLoadTimeoutNanoseconds
        ))
        if let albumManager {
            try registry.register(PhotoSorterAlbumCommand(albumManager: albumManager))
        }
        if let fileTreeSnapshotProvider {
            try registry.register(PhotoSorterFileTreeCommand(snapshotProvider: fileTreeSnapshotProvider))
        }
        try registry.register(PhotoSorterRmCommand(assetTrashBatcher: assetTrashBatcher))
    }
}
