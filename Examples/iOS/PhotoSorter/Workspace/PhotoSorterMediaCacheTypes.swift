import Foundation

struct PhotoSorterMediaOCRCacheStatus: Sendable, Equatable {
    var cachedCount: Int
    var totalCount: Int
    var isPreheating: Bool
    var isPaused: Bool
    var processedInCurrentBatch: Int
    var batchLimit: Int
    var message: String?

    static let idle = PhotoSorterMediaOCRCacheStatus(
        cachedCount: 0,
        totalCount: 0,
        isPreheating: false,
        isPaused: false,
        processedInCurrentBatch: 0,
        batchLimit: 0,
        message: nil
    )

    var progressFraction: Double? {
        guard totalCount > 0, isPreheating || isPaused else {
            return nil
        }
        return min(max(Double(cachedCount) / Double(totalCount), 0), 1)
    }
}

struct PhotoSorterMediaOCRPreheatState: Sendable, Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var processed: Int
    var limit: Int
    var message: String?

    static let idle = PhotoSorterMediaOCRPreheatState(
        isRunning: false,
        isPaused: false,
        processed: 0,
        limit: 0,
        message: nil
    )
}

struct PhotoSorterMediaVLMPreheatState: Sendable, Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var isWaitingForForeground: Bool
    var processed: Int
    var limit: Int
    var failed: Int
    var skipped: Int
    var message: String?

    static let idle = PhotoSorterMediaVLMPreheatState(
        isRunning: false,
        isPaused: false,
        isWaitingForForeground: false,
        processed: 0,
        limit: 0,
        failed: 0,
        skipped: 0,
        message: nil
    )
}

struct PhotoSorterMediaOCRCacheCoverage: Sendable, Equatable {
    var indexVersion: Int
    var cacheGeneration: UInt64
    var cachedCount: Int
    var totalCount: Int
}

struct PhotoSorterMediaVLMCacheCoverage: Sendable, Equatable {
    var indexVersion: Int
    var cacheGeneration: UInt64
    var processorConfigFingerprint: String
    var cachedCount: Int
    var totalCount: Int
}

struct PhotoSorterMediaPlaceCacheCoverage: Sendable, Equatable {
    var indexVersion: Int
    var cacheGeneration: UInt64
    var cachedCount: Int
    var totalCount: Int
}

struct PhotoSorterMediaPlaceCacheStatus: Sendable, Equatable {
    var cachedCount: Int
    var totalCount: Int
    var isPreheating: Bool
    var isPaused: Bool
    var processedInCurrentBatch: Int
    var batchLimit: Int
    var message: String?

    static let idle = PhotoSorterMediaPlaceCacheStatus(
        cachedCount: 0,
        totalCount: 0,
        isPreheating: false,
        isPaused: false,
        processedInCurrentBatch: 0,
        batchLimit: 0,
        message: nil
    )

    var progressFraction: Double? {
        guard batchLimit > 0, isPreheating || isPaused else {
            return nil
        }
        return min(max(Double(processedInCurrentBatch) / Double(batchLimit), 0), 1)
    }
}

struct PhotoSorterMediaPlacePreheatState: Sendable, Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var hasActiveTask: Bool
    var processed: Int
    var limit: Int
    var message: String?

    static let idle = PhotoSorterMediaPlacePreheatState(
        isRunning: false,
        isPaused: false,
        hasActiveTask: false,
        processed: 0,
        limit: 0,
        message: nil
    )
}

struct PhotoSorterMediaOCRCacheRequest: Hashable, Sendable, Equatable {
    var localIdentifier: String
    var assetVersion: String
}

struct PhotoSorterMediaPlaceCacheRequest: Hashable, Sendable, Equatable {
    var localIdentifier: String
    var locationVersion: String
}


enum PhotoSorterMediaOCRError: LocalizedError {
    case unsupported(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .unavailable(let message):
            return message
        }
    }
}

enum PhotoSorterMediaVLMError: LocalizedError {
    case unsupported(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .unavailable(let message):
            return message
        }
    }
}
