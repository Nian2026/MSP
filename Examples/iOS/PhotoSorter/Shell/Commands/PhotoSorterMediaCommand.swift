import Foundation
import ModelShellProxy
import MSPCore

struct PhotoSorterMediaCommand: MSPCommand {
    let name = "media"
    let summary: String? = "Inspect mounted Photos media metadata."

    let mediaProvider: any PhotoSorterMediaMetadataProviding
    let mediaLister: (any PhotoSorterMediaListing)?
    let mediaStatsProvider: (any PhotoSorterMediaStatsProviding)?
    let ocrProvider: (any PhotoSorterMediaOCRProviding)?
    let vlmProvider: (any PhotoSorterVLMProviding)?
    let imageProvider: (any PhotoSorterMediaImageProviding)?
    let reviewProvider: (any PhotoSorterMediaReviewProviding)?
    let askExclusionTracker: (any PhotoSorterMediaAskExclusionTracking)?
    let assetTrashBatcher: (any PhotoSorterAssetTrashBatching)?
    let assetTrashRestorer: (any PhotoSorterAssetTrashRestoring)?
    let cacheStatusProvider: (any PhotoSorterMediaCacheStatusProviding)?
    let agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding
    let sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding
    let mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)?
    let mediaPreviewLoadTimeoutNanoseconds: UInt64
    static let liveOCRLimit = PhotoSorterMediaLiveOCRBudget.defaultLimit
    static let liveVLMLimit = PhotoSorterMediaLiveVLMBudget.defaultLimit
    static let mediaViewLimit = 20
    static let mediaAskLimit = 200
    static let defaultListLimit = 3000
    static let defaultMediaPreviewLoadTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let mediaViewPreferredMaximumPixelDimension = PhotoSorterModelImageSizing.preferredMaximumPixelDimension
    static let mediaSearchSnippetMaximumLength = 180
    static let mediaSearchUnavailableSampleLimit = 10

    init(
        mediaProvider: any PhotoSorterMediaMetadataProviding,
        mediaLister: (any PhotoSorterMediaListing)? = nil,
        mediaStatsProvider: (any PhotoSorterMediaStatsProviding)? = nil,
        ocrProvider: (any PhotoSorterMediaOCRProviding)? = nil,
        vlmProvider: (any PhotoSorterVLMProviding)? = nil,
        imageProvider: (any PhotoSorterMediaImageProviding)? = nil,
        reviewProvider: (any PhotoSorterMediaReviewProviding)? = nil,
        askExclusionTracker: (any PhotoSorterMediaAskExclusionTracking)? = nil,
        assetTrashBatcher: (any PhotoSorterAssetTrashBatching)? = nil,
        assetTrashRestorer: (any PhotoSorterAssetTrashRestoring)? = nil,
        cacheStatusProvider: (any PhotoSorterMediaCacheStatusProviding)? = nil,
        agentAccessModeProvider: any PhotoSorterAgentAccessModeProviding = PhotoSorterAgentAccessModeState(),
        sensitiveReadPolicyProvider: any PhotoSorterSensitiveReadPolicyProviding = PhotoSorterSensitiveReadPolicyState(),
        mediaViewAuthorizer: (any PhotoSorterMediaViewAuthorizing)? = nil,
        mediaPreviewLoadTimeoutNanoseconds: UInt64 = PhotoSorterMediaCommand.defaultMediaPreviewLoadTimeoutNanoseconds
    ) {
        self.mediaProvider = mediaProvider
        self.mediaLister = mediaLister ?? (mediaProvider as? any PhotoSorterMediaListing)
        self.mediaStatsProvider = mediaStatsProvider ?? (mediaProvider as? any PhotoSorterMediaStatsProviding)
        self.ocrProvider = ocrProvider ?? (mediaProvider as? any PhotoSorterMediaOCRProviding)
        self.vlmProvider = vlmProvider ?? (mediaProvider as? any PhotoSorterVLMProviding)
        self.imageProvider = imageProvider ?? (mediaProvider as? any PhotoSorterMediaImageProviding)
        self.reviewProvider = reviewProvider ?? (mediaProvider as? any PhotoSorterMediaReviewProviding)
        self.askExclusionTracker = askExclusionTracker ?? (mediaProvider as? any PhotoSorterMediaAskExclusionTracking)
        self.assetTrashBatcher = assetTrashBatcher ?? (mediaProvider as? any PhotoSorterAssetTrashBatching)
        self.assetTrashRestorer = assetTrashRestorer ?? (mediaProvider as? any PhotoSorterAssetTrashRestoring)
        self.cacheStatusProvider = cacheStatusProvider ?? (mediaProvider as? any PhotoSorterMediaCacheStatusProviding)
        self.agentAccessModeProvider = agentAccessModeProvider
        self.sensitiveReadPolicyProvider = sensitiveReadPolicyProvider
        self.mediaViewAuthorizer = mediaViewAuthorizer
        self.mediaPreviewLoadTimeoutNanoseconds = mediaPreviewLoadTimeoutNanoseconds
    }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let help = Self.help.result(for: invocation.arguments) {
            return help
        }
        guard let subcommand = invocation.arguments.first else {
            return usageFailure("media: usage: media list|show|search|view|ask|status|stats|trash|restore ...\nTry 'media help' for more information.")
        }

        switch subcommand {
        case "list", "ls":
            return runList(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "show":
            return await runShow(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "search", "grep":
            return runSearch(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "vlm":
            return runVLM(
                arguments: Array(invocation.arguments.dropFirst())
            )
        case "status":
            return runStatus(arguments: Array(invocation.arguments.dropFirst()))
        case "cache":
            return runCache(arguments: Array(invocation.arguments.dropFirst()))
        case "stats":
            return runStats(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "view":
            return await runView(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "ask":
            return await runAsk(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "trash":
            return runTrash(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        case "restore":
            return runRestore(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        default:
            return usageFailure("media: unsupported subcommand \(subcommand)\nTry 'media help' for more information.")
        }
    }
}
