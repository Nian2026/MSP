import Foundation
@testable import MSPAgentBridge

enum MSPChatNamingTestError: Error {
    case failed
}

actor MSPChatNamingMemoryStore: MSPChatTitlePersisting {
    private var records: [String: MSPChatTitleRecord] = [:]
    private var revisions: [String: Int] = [:]
    private var writeConditions: [MSPChatTitleWriteCondition] = []
    private var readFailure: Error?

    func seed(_ record: MSPChatTitleRecord) {
        records[record.chatID] = record
        revisions[record.chatID, default: 0] += 1
    }

    func failReads(with error: Error) {
        readFailure = error
    }

    func titleMetadata(for chatID: String) async throws -> MSPChatTitleMetadata {
        if let readFailure {
            throw readFailure
        }
        return metadata(for: chatID)
    }

    func writeTitle(
        _ record: MSPChatTitleRecord,
        condition: MSPChatTitleWriteCondition
    ) async throws -> MSPChatTitleWriteResult {
        writeConditions.append(condition)
        let current = metadata(for: record.chatID)
        let allowed: Bool
        switch condition {
        case .always:
            allowed = true
        case .onlyIfUntitled:
            allowed = current.isUntitled
        case .ifRevision(let expected):
            allowed = current.revision == expected
        }

        guard allowed else {
            return MSPChatTitleWriteResult(
                disposition: .notUpdated,
                metadata: current
            )
        }
        records[record.chatID] = record
        revisions[record.chatID, default: 0] += 1
        return MSPChatTitleWriteResult(
            disposition: .updated,
            metadata: metadata(for: record.chatID)
        )
    }

    func snapshot(for chatID: String) -> MSPChatTitleMetadata {
        metadata(for: chatID)
    }

    func conditions() -> [MSPChatTitleWriteCondition] {
        writeConditions
    }

    private func metadata(for chatID: String) -> MSPChatTitleMetadata {
        MSPChatTitleMetadata(
            record: records[chatID],
            revision: revisions[chatID].map { String($0) }
        )
    }
}

actor MSPChatNamingEventLog {
    private var events: [MSPChatNamingEvent] = []

    func append(_ event: MSPChatNamingEvent) {
        events.append(event)
    }

    func snapshot() -> [MSPChatNamingEvent] {
        events
    }
}

actor MSPChatTitleRequestRecorder: MSPChatTitleGenerating {
    private var requests: [MSPChatTitleGenerationRequest] = []
    private let suggestion: MSPChatTitleSuggestion

    init(suggestion: MSPChatTitleSuggestion) {
        self.suggestion = suggestion
    }

    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        requests.append(request)
        return suggestion
    }

    func snapshot() -> [MSPChatTitleGenerationRequest] {
        requests
    }
}

actor MSPBlockingChatTitleGenerator: MSPChatTitleGenerating {
    private var requests: [MSPChatTitleGenerationRequest] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private let suggestion: MSPChatTitleSuggestion

    init(suggestion: MSPChatTitleSuggestion) {
        self.suggestion = suggestion
    }

    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        requests.append(request)
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
        return suggestion
    }

    func waitUntilStarted() async {
        if !requests.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func requestCount() -> Int {
        requests.count
    }

    func recordedRequests() -> [MSPChatTitleGenerationRequest] {
        requests
    }
}

struct MSPThrowingChatTitleGenerator: MSPChatTitleGenerating {
    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        throw MSPChatNamingTestError.failed
    }
}

struct MSPSlowChatTitleGenerator: MSPChatTitleGenerating {
    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return MSPChatTitleSuggestion(title: "too late")
    }
}

actor MSPBlockingSearchDescriptionGenerator:
    MSPChatTitleGenerating,
    MSPChatSearchDescriptionGenerating
{
    private var descriptionStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var descriptionRelease: CheckedContinuation<Void, Never>?
    private var isDescriptionReleased = false
    private var descriptionRequestCount = 0
    private let description: String

    init(description: String) {
        self.description = description
    }

    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        MSPChatTitleSuggestion(title: "Generated title")
    }

    func generateSearchDescription(
        request: MSPChatSearchDescriptionGenerationRequest
    ) async throws -> String? {
        descriptionRequestCount += 1
        let waiters = descriptionStartedWaiters
        descriptionStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            if isDescriptionReleased {
                continuation.resume()
            } else {
                descriptionRelease = continuation
            }
        }
        return description
    }

    func waitUntilDescriptionStarted() async {
        if descriptionRequestCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            descriptionStartedWaiters.append(continuation)
        }
    }

    func releaseDescription() {
        isDescriptionReleased = true
        descriptionRelease?.resume()
        descriptionRelease = nil
    }
}

struct MSPImmediateCombinedNamingGenerator:
    MSPChatTitleGenerating,
    MSPChatSearchDescriptionGenerating
{
    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        MSPChatTitleSuggestion(
            title: "Generated title",
            searchDescription: "Generated description"
        )
    }

    func generateSearchDescription(
        request: MSPChatSearchDescriptionGenerationRequest
    ) async throws -> String? {
        "Refreshed searchable description"
    }
}

actor MSPChatNamingPreserveRaceStore: MSPChatTitlePersisting {
    private var metadata = MSPChatTitleMetadata(
        record: MSPChatTitleRecord(
            chatID: "chat",
            title: "Original title",
            searchDescription: "Original description",
            source: .model,
            updatedAt: Date(timeIntervalSince1970: 1)
        ),
        revision: "1"
    )
    private var didInjectConcurrentDescriptionWrite = false
    private var writeConditions: [MSPChatTitleWriteCondition] = []

    func titleMetadata(for chatID: String) async throws -> MSPChatTitleMetadata {
        metadata
    }

    func writeTitle(
        _ record: MSPChatTitleRecord,
        condition: MSPChatTitleWriteCondition
    ) async throws -> MSPChatTitleWriteResult {
        writeConditions.append(condition)
        if !didInjectConcurrentDescriptionWrite {
            didInjectConcurrentDescriptionWrite = true
            var concurrent = metadata.record!
            concurrent.searchDescription = "Newest concurrent description"
            metadata = MSPChatTitleMetadata(record: concurrent, revision: "2")
            return MSPChatTitleWriteResult(
                disposition: .notUpdated,
                metadata: metadata
            )
        }
        guard case .ifRevision(let expectedRevision) = condition,
              expectedRevision == metadata.revision else {
            return MSPChatTitleWriteResult(
                disposition: .notUpdated,
                metadata: metadata
            )
        }
        metadata = MSPChatTitleMetadata(record: record, revision: "3")
        return MSPChatTitleWriteResult(
            disposition: .updated,
            metadata: metadata
        )
    }

    func conditions() -> [MSPChatTitleWriteCondition] {
        writeConditions
    }
}
