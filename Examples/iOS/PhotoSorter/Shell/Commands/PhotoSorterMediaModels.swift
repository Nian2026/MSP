import CoreGraphics
import Foundation

struct PhotoSorterMediaMetadata: Sendable, Equatable {
    var path: String
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date? = nil
    var mediaType: PhotoSorterMediaType = .unknown
    var cachedPlace: String? = nil
}

enum PhotoSorterMediaType: String, Sendable, Equatable {
    case image
    case video
    case all
    case unknown
}

enum PhotoSorterMediaListSort: String, Sendable, Equatable {
    case created
    case modified
    case name
}

enum PhotoSorterMediaListOrder: String, Sendable, Equatable {
    case asc
    case desc
}

enum PhotoSorterMediaStatsGroup: String, Sendable, Equatable {
    case month
    case type
}

enum PhotoSorterMediaStatsDateField: String, Sendable, Equatable {
    case created
    case modified
}

struct PhotoSorterMediaListItem: Sendable, Equatable {
    var path: String
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var modificationDate: Date?
    var mediaType: PhotoSorterMediaType
}

struct PhotoSorterMediaListPage: Sendable, Equatable {
    var items: [PhotoSorterMediaListItem]
    var totalCount: Int
    var offset: Int
    var limit: Int
}

struct PhotoSorterMediaStatsBucket: Sendable, Equatable {
    var key: String
    var count: Int
}

struct PhotoSorterOriginalImage: Sendable, Equatable {
    var path: String
    var fileName: String
    var mimeType: String
    var pixelWidth: Int
    var pixelHeight: Int
    var data: Data
}

enum PhotoSorterMediaPreviewKind: String, Sendable, Equatable {
    case image
    case video
    case livePhoto
}

struct PhotoSorterMediaPreview: Sendable, Equatable {
    var path: String
    var fileName: String
    var kind: PhotoSorterMediaPreviewKind
    var pixelWidth: Int
    var pixelHeight: Int
    var thumbnailData: Data?
    var photoLibraryLocalIdentifier: String?
    var fileURL: URL?
}

enum PhotoSorterModelImageSizing {
    static let preferredMaximumPixelDimension = 2048
    static let minimumShortPixelDimension = 1080

    static func targetSize(
        width: Int,
        height: Int,
        preferredMaximumPixelDimension: Int = Self.preferredMaximumPixelDimension,
        minimumShortPixelDimension: Int = Self.minimumShortPixelDimension
    ) -> CGSize {
        let width = CGFloat(max(width, 1))
        let height = CGFloat(max(height, 1))
        let largestDimension = max(width, height)
        let shortestDimension = min(width, height)
        let preferredMaximumPixelDimension = CGFloat(max(preferredMaximumPixelDimension, 1))
        let minimumShortPixelDimension = CGFloat(max(minimumShortPixelDimension, 1))

        let preferredScale = min(1, preferredMaximumPixelDimension / largestDimension)
        let readableScale = min(1, minimumShortPixelDimension / shortestDimension)
        let scale = max(preferredScale, readableScale)
        return CGSize(
            width: max(width * scale, 1),
            height: max(height * scale, 1)
        )
    }
}

struct PhotoSorterMediaViewItem: Identifiable, Sendable, Equatable {
    var id = UUID()
    var image: PhotoSorterOriginalImage?
    var preview: PhotoSorterMediaPreview

    init(id: UUID = UUID(), image: PhotoSorterOriginalImage) {
        self.id = id
        self.image = image
        self.preview = PhotoSorterMediaPreview(
            path: image.path,
            fileName: image.fileName,
            kind: .image,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            thumbnailData: image.data,
            photoLibraryLocalIdentifier: nil,
            fileURL: nil
        )
    }

    init(id: UUID = UUID(), preview: PhotoSorterMediaPreview) {
        self.id = id
        self.image = nil
        self.preview = preview
    }

    var path: String { preview.path }
    var fileName: String { preview.fileName }
    var kind: PhotoSorterMediaPreviewKind { preview.kind }
    var pixelWidth: Int { preview.pixelWidth }
    var pixelHeight: Int { preview.pixelHeight }
    var thumbnailData: Data? { preview.thumbnailData }
}

struct PhotoSorterMediaViewFailure: Sendable, Equatable {
    var path: String
    var message: String
}

struct PhotoSorterMediaAskReason: Sendable, Equatable {
    var path: String
    var title: String?
    var confidence: String?
    var basis: [String] = []
    var matchedTerms: [String] = []
    var risk: String?
    var detail: String?

    var titleLine: String? {
        switch (title, confidence) {
        case (.some(let title), .some(let confidence)):
            return "\(title) · \(confidence)"
        case (.some(let title), .none):
            return title
        case (.none, .some(let confidence)):
            return confidence
        case (.none, .none):
            return nil
        }
    }

    var hasDisplayContent: Bool {
        titleLine != nil
            || !basis.isEmpty
            || !matchedTerms.isEmpty
            || risk != nil
            || detail != nil
    }
}

struct PhotoSorterMediaViewLoadResult: Sendable, Equatable {
    var index: Int
    var item: PhotoSorterMediaViewItem?
    var failure: PhotoSorterMediaViewFailure?
}

struct PhotoSorterMediaViewItemLoader: Sendable {
    private let loadHandler: @Sendable (_ index: Int, _ path: String) async -> PhotoSorterMediaViewLoadResult

    init(
        loadHandler: @escaping @Sendable (_ index: Int, _ path: String) async -> PhotoSorterMediaViewLoadResult
    ) {
        self.loadHandler = loadHandler
    }

    func load(index: Int, path: String) async -> PhotoSorterMediaViewLoadResult {
        await loadHandler(index, path)
    }
}

enum PhotoSorterMediaViewAuthorizationPurpose: Sendable, Equatable {
    case sendToModel
    case askUser
}

struct PhotoSorterMediaViewAuthorizationRequest: Identifiable, Sendable {
    var id = UUID()
    var purpose: PhotoSorterMediaViewAuthorizationPurpose = .sendToModel
    var message: String? = nil
    var items: [PhotoSorterMediaViewItem]
    var pendingPaths: [String] = []
    var reasonsByPath: [String: PhotoSorterMediaAskReason] = [:]
    var itemLoader: PhotoSorterMediaViewItemLoader? = nil
    var limitSkippedPaths: [String]
}

extension PhotoSorterMediaViewAuthorizationRequest: Equatable {
    static func == (
        lhs: PhotoSorterMediaViewAuthorizationRequest,
        rhs: PhotoSorterMediaViewAuthorizationRequest
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.purpose == rhs.purpose
            && lhs.message == rhs.message
            && lhs.items == rhs.items
            && lhs.pendingPaths == rhs.pendingPaths
            && lhs.reasonsByPath == rhs.reasonsByPath
            && lhs.limitSkippedPaths == rhs.limitSkippedPaths
    }
}

struct PhotoSorterMediaViewAuthorizationDecision: Sendable, Equatable {
    var allowedItemIDs: Set<UUID>
    var note: String = ""
    var cancelled: Bool = false
    var reviewedItems: [PhotoSorterMediaViewItem] = []
    var skippedFailures: [PhotoSorterMediaViewFailure] = []

    static let denyAll = PhotoSorterMediaViewAuthorizationDecision(allowedItemIDs: [])
    static let cancel = PhotoSorterMediaViewAuthorizationDecision(allowedItemIDs: [], cancelled: true)
}

protocol PhotoSorterMediaViewAuthorizing: Sendable {
    @MainActor
    func authorizeMediaView(_ request: PhotoSorterMediaViewAuthorizationRequest) async -> PhotoSorterMediaViewAuthorizationDecision
}

enum PhotoSorterMediaImageError: LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case .unavailable(let message):
            return message
        }
    }
}

enum PhotoSorterMediaOCRSource: String, Sendable, Equatable {
    case cache
    case live
}

struct PhotoSorterMediaOCRResult: Sendable, Equatable {
    var path: String
    var text: String
    var source: PhotoSorterMediaOCRSource
}

enum PhotoSorterMediaOCRCacheLookup: Sendable, Equatable {
    case hit(PhotoSorterMediaOCRResult)
    case miss
    case unavailable(String)
}

enum PhotoSorterMediaVLMSource: String, Sendable, Equatable {
    case cache
    case live
}

struct PhotoSorterMediaVLMSummaryResult: Sendable, Equatable {
    var path: String
    var summary: String
    var source: PhotoSorterMediaVLMSource
}

enum PhotoSorterMediaVLMCacheLookup: Sendable, Equatable {
    case hit(PhotoSorterMediaVLMSummaryResult)
    case miss
    case unavailable(String)
}

enum PhotoSorterMediaVLMModelState: String, Sendable, Equatable {
    case notInstalled = "not installed"
    case installed = "installed"
    case unavailable = "unavailable"
    case running = "running"
}

struct PhotoSorterMediaVLMProviderStatus: Sendable, Equatable {
    var kind: String
    var backend: String
    var modelID: String
    var modelVersion: String
    var modelState: PhotoSorterMediaVLMModelState
    var isLiveSummarizationAvailable: Bool
    var processorConfigFingerprint: String
    var reason: String?
}

struct PhotoSorterMediaVLMStatus: Sendable, Equatable {
    var primaryProvider: PhotoSorterMediaVLMProviderStatus
    var systemProvider: PhotoSorterMediaVLMProviderStatus
    var cachedCount: Int
    var totalCount: Int
    var isPreheating: Bool
    var isPaused: Bool
    var processedInCurrentBatch: Int
    var batchLimit: Int
    var failedInCurrentBatch: Int
    var skippedInCurrentBatch: Int
    var message: String?
    var promptVersion: String
    var prompt: String
    var language: String
    var summarySchemaVersion: Int

    static let unavailable = PhotoSorterMediaVLMStatus(
        primaryProvider: PhotoSorterMediaVLMConfiguration.bundledFastVLMUnavailableProviderStatus,
        systemProvider: PhotoSorterMediaVLMConfiguration.systemUnavailableProviderStatus,
        cachedCount: 0,
        totalCount: 0,
        isPreheating: false,
        isPaused: false,
        processedInCurrentBatch: 0,
        batchLimit: 0,
        failedInCurrentBatch: 0,
        skippedInCurrentBatch: 0,
        message: "local FastVLM model is not installed",
        promptVersion: PhotoSorterMediaVLMConfiguration.promptVersion,
        prompt: PhotoSorterMediaVLMConfiguration.prompt,
        language: PhotoSorterMediaVLMConfiguration.language,
        summarySchemaVersion: PhotoSorterMediaVLMConfiguration.summarySchemaVersion
    )

    var progressFraction: Double? {
        guard batchLimit > 0, isPreheating || isPaused else {
            return nil
        }
        return min(max(Double(processedInCurrentBatch) / Double(batchLimit), 0), 1)
    }
}
