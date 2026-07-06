import Foundation

extension PhotoSorterMediaCommand {
    struct PhotoSorterMediaShowRecord {
        var metadata: PhotoSorterMediaMetadata
        var ocrCacheAvailable: Bool?
        var vlmCacheAvailable: Bool?
        var mediaAskExcludedCountByUser: Int
    }

    struct PhotoSorterMediaAskRecord {
        var itemID: UUID
        var path: String
        var dateText: String
        var dimensionsText: String
        var ocrCacheAvailable: Bool?
        var vlmCacheAvailable: Bool?
        var reason: PhotoSorterMediaAskReason?
    }

    struct PhotoSorterMediaAskWriteResult {
        var label: String
        var count: Int
        var path: String
    }

    final class PhotoSorterMediaViewLoadRace: @unchecked Sendable {
        let lock = NSLock()
        private var continuation: CheckedContinuation<PhotoSorterMediaViewLoadResult, Never>?
        private var didResume = false

        init(continuation: CheckedContinuation<PhotoSorterMediaViewLoadResult, Never>) {
            self.continuation = continuation
        }

        func setLoadTask(_: Task<Void, Never>) -> Bool {
            lock.lock()
            let shouldCancel = didResume
            lock.unlock()
            return shouldCancel
        }

        @discardableResult
        func resume(_ result: PhotoSorterMediaViewLoadResult) -> Bool {
            lock.lock()
            guard !didResume, let continuation else {
                lock.unlock()
                return false
            }
            didResume = true
            self.continuation = nil
            lock.unlock()

            continuation.resume(returning: result)
            return true
        }
    }
}
