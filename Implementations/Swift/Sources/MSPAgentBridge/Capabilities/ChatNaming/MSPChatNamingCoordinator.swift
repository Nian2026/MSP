import Foundation

/// Runs Chat metadata work outside the agent turn and transcript lifecycle.
/// Hosts opt in by creating a coordinator, inject any title model they prefer,
/// persist through ``MSPChatTitlePersisting``, and project
/// ``MSPChatNamingEvent`` into their own UI.
public actor MSPChatNamingCoordinator {
    private struct TitleFlight {
        var id: UUID
        var task: Task<MSPChatNamingOutcome, Error>
    }

    private struct DescriptionFlight {
        var id: UUID
        var task: Task<MSPChatSearchDescriptionRefreshOutcome, Error>
    }

    private let titleGenerator: any MSPChatTitleGenerating
    private let searchDescriptionGenerator:
        (any MSPChatSearchDescriptionGenerating)?
    private let persistence: any MSPChatTitlePersisting
    private let configuration: MSPChatNamingConfiguration
    private let onEvent: MSPChatNamingEventHandler
    private let now: @Sendable () -> Date

    private var titleFlights: [String: TitleFlight] = [:]
    private var descriptionFlights: [String: DescriptionFlight] = [:]

    public init(
        titleGenerator: any MSPChatTitleGenerating,
        searchDescriptionGenerator:
            (any MSPChatSearchDescriptionGenerating)? = nil,
        persistence: any MSPChatTitlePersisting,
        configuration: MSPChatNamingConfiguration = .codexCompatible(),
        onEvent: @escaping MSPChatNamingEventHandler = { _ in }
    ) {
        self.titleGenerator = titleGenerator
        self.searchDescriptionGenerator = searchDescriptionGenerator
            ?? (titleGenerator as? any MSPChatSearchDescriptionGenerating)
        self.persistence = persistence
        self.configuration = configuration
        self.onEvent = onEvent
        self.now = { Date() }
    }

    init(
        titleGenerator: any MSPChatTitleGenerating,
        searchDescriptionGenerator:
            (any MSPChatSearchDescriptionGenerating)? = nil,
        persistence: any MSPChatTitlePersisting,
        configuration: MSPChatNamingConfiguration = .codexCompatible(),
        onEvent: @escaping MSPChatNamingEventHandler = { _ in },
        now: @escaping @Sendable () -> Date
    ) {
        self.titleGenerator = titleGenerator
        self.searchDescriptionGenerator = searchDescriptionGenerator
            ?? (titleGenerator as? any MSPChatSearchDescriptionGenerating)
        self.persistence = persistence
        self.configuration = configuration
        self.onEvent = onEvent
        self.now = now
    }

    /// Generates at most once concurrently per Chat within this coordinator.
    /// The first untitled check occurs before the model request; a second check
    /// and an atomic `.onlyIfUntitled` write occur after it.
    public func generateTitleIfNeeded(
        _ request: MSPChatNamingRequest
    ) async throws -> MSPChatNamingOutcome {
        if let existing = titleFlights[request.chatID] {
            return try await Self.unwrapped(existing.task)
        }

        let flightID = UUID()
        let titleGenerator = self.titleGenerator
        let persistence = self.persistence
        let configuration = self.configuration
        let onEvent = self.onEvent
        let now = self.now
        let task = Task {
            do {
                return try await Self.performTitleGeneration(
                    request: request,
                    titleGenerator: titleGenerator,
                    persistence: persistence,
                    configuration: configuration,
                    onEvent: onEvent,
                    now: now
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MSPChatNamingReportedFailure {
                throw error
            } catch {
                await onEvent(.titleGenerationFailed(
                    MSPChatTitleGenerationFailedEvent(
                        chatID: request.chatID,
                        source: request.source,
                        message: (error as NSError).localizedDescription,
                        willUseFallback: false,
                        failedAt: now()
                    )
                ))
                throw MSPChatNamingReportedFailure(underlying: error)
            }
        }
        titleFlights[request.chatID] = TitleFlight(id: flightID, task: task)
        defer {
            if titleFlights[request.chatID]?.id == flightID {
                titleFlights.removeValue(forKey: request.chatID)
            }
        }
        return try await Self.unwrapped(task)
    }

    public func backfillTitleIfNeeded(
        chatID: String,
        preview: MSPChatNamingInput
    ) async throws -> MSPChatNamingOutcome {
        try await generateTitleIfNeeded(MSPChatNamingRequest(
            chatID: chatID,
            input: preview,
            source: .historicalBackfill
        ))
    }

    /// Manual naming is an unconditional metadata write. Any delayed model
    /// work is canceled, and its later `.onlyIfUntitled` compare-and-set still
    /// cannot replace this title even when the model ignores cancellation.
    @discardableResult
    public func setManualTitle(
        chatID: String,
        title: String,
        searchDescription: MSPChatSearchDescriptionUpdate = .preserve
    ) async throws -> MSPChatTitleMetadata {
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw MSPChatNamingError.emptyManualTitle
        }
        cancelFlights(for: chatID)
        var record = MSPChatTitleRecord(
            chatID: chatID,
            title: normalizedTitle,
            searchDescription: nil,
            source: .manual,
            updatedAt: now()
        )
        let result: MSPChatTitleWriteResult
        switch searchDescription {
        case .preserve:
            var current = try await persistence.titleMetadata(for: chatID)
            var attemptCount = 0
            var committed: MSPChatTitleWriteResult?
            while attemptCount < 16 {
                attemptCount += 1
                record.searchDescription = current.searchDescription
                let attempt = try await persistence.writeTitle(
                    record,
                    condition: .ifRevision(current.revision)
                )
                if attempt.didUpdate {
                    committed = attempt
                    break
                }
                current = attempt.metadata
                try Task.checkCancellation()
                await Task.yield()
            }
            guard let committed else {
                throw MSPChatNamingError.manualTitleWriteConflict
            }
            result = committed
        case .replace(let value):
            record.searchDescription = Self.normalizedOptional(value)
            result = try await persistence.writeTitle(
                record,
                condition: .always
            )
        }
        if result.didUpdate {
            await onEvent(.titleUpdated(MSPChatTitleUpdatedEvent(
                eventID: UUID().uuidString,
                record: result.metadata.record ?? record,
                requestSource: nil
            )))
        }
        return result.metadata
    }

    /// One-call host integration for the common manual-rename flow. The title
    /// write succeeds independently; description refresh remains best-effort
    /// and reports any failure through `MSPChatNamingEvent`.
    @discardableResult
    public func setManualTitleAndRefreshSearchDescription(
        chatID: String,
        title: String,
        input: MSPChatNamingInput
    ) async throws -> MSPChatTitleMetadata {
        let titled = try await setManualTitle(
            chatID: chatID,
            title: title
        )
        do {
            return try await refreshSearchDescription(
                chatID: chatID,
                input: input,
                source: .manualTitleChange
            ).metadata
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return titled
        }
    }

    /// Refreshes retrieval metadata separately after a manual rename.
    /// Both the current title and its opaque revision are checked after the
    /// model returns, so a late description cannot overwrite a newer rename.
    public func refreshSearchDescription(
        chatID: String,
        input: MSPChatNamingInput,
        source: MSPChatSearchDescriptionRequestSource = .manualTitleChange
    ) async throws -> MSPChatSearchDescriptionRefreshOutcome {
        if let existing = descriptionFlights[chatID] {
            return try await Self.unwrapped(existing.task)
        }

        let flightID = UUID()
        let generator = searchDescriptionGenerator
        let persistence = self.persistence
        let configuration = self.configuration
        let onEvent = self.onEvent
        let now = self.now
        let task = Task {
            do {
                return try await Self.performSearchDescriptionRefresh(
                    chatID: chatID,
                    input: input,
                    source: source,
                    generator: generator,
                    persistence: persistence,
                    configuration: configuration,
                    onEvent: onEvent,
                    now: now
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MSPChatNamingReportedFailure {
                throw error
            } catch {
                let metadata = try? await persistence.titleMetadata(for: chatID)
                await onEvent(.searchDescriptionGenerationFailed(
                    MSPChatSearchDescriptionGenerationFailedEvent(
                        chatID: chatID,
                        title: metadata?.title ?? "",
                        source: source,
                        message: (error as NSError).localizedDescription,
                        failedAt: now()
                    )
                ))
                throw MSPChatNamingReportedFailure(underlying: error)
            }
        }
        descriptionFlights[chatID] = DescriptionFlight(
            id: flightID,
            task: task
        )
        defer {
            if descriptionFlights[chatID]?.id == flightID {
                descriptionFlights.removeValue(forKey: chatID)
            }
        }
        return try await Self.unwrapped(task)
    }

    /// Copies metadata for a derived Chat without moving or renaming its
    /// physical `.chat` package.
    public func inheritTitle(
        from parentChatID: String,
        to childChatID: String
    ) async throws -> MSPChatNamingOutcome {
        let parent = try await persistence.titleMetadata(for: parentChatID)
        return try await inheritTitle(from: parent, to: childChatID)
    }

    /// Cross-session overload for stores that bind one persistence adapter to
    /// one `.chat` package. The host reads the parent metadata from its parent
    /// session and passes it to the child's coordinator/store.
    public func inheritTitle(
        from parent: MSPChatTitleMetadata,
        to childChatID: String
    ) async throws -> MSPChatNamingOutcome {
        let child = try await persistence.titleMetadata(for: childChatID)
        guard configuration.policy.inheritForkTitles else {
            return await skippedTitleOutcome(
                chatID: childChatID,
                source: .forkInheritance,
                reason: .policyDisabled,
                metadata: child
            )
        }
        guard child.isUntitled else {
            return await skippedTitleOutcome(
                chatID: childChatID,
                source: .forkInheritance,
                reason: .alreadyTitled,
                metadata: child
            )
        }
        guard let parentRecord = parent.record, !parent.isUntitled else {
            return await skippedTitleOutcome(
                chatID: childChatID,
                source: .forkInheritance,
                reason: .parentUntitled,
                metadata: child
            )
        }
        cancelFlights(for: childChatID)

        let latestChild = try await persistence.titleMetadata(for: childChatID)
        guard latestChild.isUntitled else {
            return await skippedTitleOutcome(
                chatID: childChatID,
                source: .forkInheritance,
                reason: .titleChangedDuringGeneration,
                metadata: latestChild
            )
        }
        let inherited = MSPChatTitleRecord(
            chatID: childChatID,
            title: parentRecord.title,
            searchDescription: parentRecord.searchDescription,
            source: .inherited,
            updatedAt: now()
        )
        let result = try await persistence.writeTitle(
            inherited,
            condition: .onlyIfUntitled
        )
        guard result.didUpdate else {
            return await skippedTitleOutcome(
                chatID: childChatID,
                source: .forkInheritance,
                reason: .writeConditionNotMet,
                metadata: result.metadata
            )
        }
        await onEvent(.titleUpdated(MSPChatTitleUpdatedEvent(
            eventID: UUID().uuidString,
            record: result.metadata.record ?? inherited,
            requestSource: .forkInheritance
        )))
        return .updated(result.metadata)
    }

    public func inheritTitle(
        from parentRecord: MSPChatTitleRecord,
        to childChatID: String
    ) async throws -> MSPChatNamingOutcome {
        try await inheritTitle(
            from: MSPChatTitleMetadata(
                record: parentRecord,
                revision: nil
            ),
            to: childChatID
        )
    }

    public func cancelPendingNaming(for chatID: String) {
        cancelFlights(for: chatID)
    }

    private func cancelFlights(for chatID: String) {
        titleFlights.removeValue(forKey: chatID)?.task.cancel()
        descriptionFlights.removeValue(forKey: chatID)?.task.cancel()
    }

    private func skippedTitleOutcome(
        chatID: String,
        source: MSPChatNamingRequestSource,
        reason: MSPChatNamingSkipReason,
        metadata: MSPChatTitleMetadata
    ) async -> MSPChatNamingOutcome {
        await onEvent(.titleGenerationSkipped(
            MSPChatTitleGenerationSkippedEvent(
                chatID: chatID,
                source: source,
                reason: reason,
                skippedAt: now()
            )
        ))
        return .skipped(reason: reason, metadata: metadata)
    }

    private static func unwrapped<Success: Sendable>(
        _ task: Task<Success, Error>
    ) async throws -> Success {
        do {
            return try await task.value
        } catch let error as MSPChatNamingReportedFailure {
            throw error.underlying
        }
    }
}

private extension MSPChatNamingCoordinator {
    static func performTitleGeneration(
        request: MSPChatNamingRequest,
        titleGenerator: any MSPChatTitleGenerating,
        persistence: any MSPChatTitlePersisting,
        configuration: MSPChatNamingConfiguration,
        onEvent: @escaping MSPChatNamingEventHandler,
        now: @escaping @Sendable () -> Date
    ) async throws -> MSPChatNamingOutcome {
        let initial = try await persistence.titleMetadata(for: request.chatID)
        guard configuration.policy.permits(request.source) else {
            return await emitTitleSkip(
                request: request,
                reason: .policyDisabled,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }
        guard initial.isUntitled else {
            return await emitTitleSkip(
                request: request,
                reason: .alreadyTitled,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }

        let limits = configuration.limits
        let prompt = MSPChatNamingPrompt.preparedPrompt(
            from: request.input,
            maximumCharacters: limits.inputMaximumCharacters
        )
        guard !prompt.isEmpty else {
            return await emitTitleSkip(
                request: request,
                reason: .emptyInput,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }

        await onEvent(.titleGenerationStarted(
            MSPChatTitleGenerationStartedEvent(
                chatID: request.chatID,
                source: request.source,
                startedAt: now()
            )
        ))

        let generationRequest = MSPChatTitleGenerationRequest(
            chatID: request.chatID,
            prompt: prompt,
            instructions: MSPChatNamingPrompt.titleInstructions(
                titleMaximumCharacters: limits.titleMaximumCharacters,
                descriptionMaximumCharacters: limits.descriptionMaximumCharacters
            ),
            model: configuration.model,
            titleMaximumCharacters: limits.titleMaximumCharacters,
            descriptionMaximumCharacters: limits.descriptionMaximumCharacters,
            source: request.source
        )

        let selected: MSPChatTitleSuggestion
        let titleSource: MSPChatTitleSource
        do {
            let generated = try await withTimeout(
                nanoseconds: configuration.timeoutNanoseconds
            ) {
                try await titleGenerator.generateTitle(
                    request: generationRequest
                )
            }
            try Task.checkCancellation()
            guard let title = MSPChatNamingTextNormalizer.title(
                generated.title,
                maximumCharacters: limits.titleMaximumCharacters
            ) else {
                throw MSPChatNamingError.emptyGeneratedTitle
            }
            selected = MSPChatTitleSuggestion(
                title: title,
                searchDescription: MSPChatNamingTextNormalizer.description(
                    generated.searchDescription,
                    maximumCharacters: limits.descriptionMaximumCharacters
                )
            )
            titleSource = .model
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let willUseFallback = configuration.policy
                .useInputFallbackOnGenerationFailure
            await onEvent(.titleGenerationFailed(
                MSPChatTitleGenerationFailedEvent(
                    chatID: request.chatID,
                    source: request.source,
                    message: (error as NSError).localizedDescription,
                    willUseFallback: willUseFallback,
                    failedAt: now()
                )
            ))
            guard willUseFallback else {
                throw MSPChatNamingReportedFailure(underlying: error)
            }
            let fallback = MSPChatNamingPrompt.fallbackTitle(
                fromPreparedPrompt: prompt,
                maximumCharacters: limits.fallbackMaximumCharacters
            )
            guard !fallback.isEmpty else {
                throw MSPChatNamingReportedFailure(
                    underlying: MSPChatNamingError.emptyGeneratedTitle
                )
            }
            selected = MSPChatTitleSuggestion(
                title: fallback,
                searchDescription: nil
            )
            titleSource = .fallback
        }

        let latest = try await persistence.titleMetadata(for: request.chatID)
        guard latest.isUntitled else {
            return await emitTitleSkip(
                request: request,
                reason: .titleChangedDuringGeneration,
                metadata: latest,
                onEvent: onEvent,
                now: now
            )
        }

        let record = MSPChatTitleRecord(
            chatID: request.chatID,
            title: selected.title,
            searchDescription: selected.searchDescription,
            source: titleSource,
            updatedAt: now()
        )
        let result = try await persistence.writeTitle(
            record,
            condition: .onlyIfUntitled
        )
        guard result.didUpdate else {
            return await emitTitleSkip(
                request: request,
                reason: .writeConditionNotMet,
                metadata: result.metadata,
                onEvent: onEvent,
                now: now
            )
        }

        await onEvent(.titleUpdated(MSPChatTitleUpdatedEvent(
            eventID: UUID().uuidString,
            record: result.metadata.record ?? record,
            requestSource: request.source
        )))
        return .updated(result.metadata)
    }

    static func performSearchDescriptionRefresh(
        chatID: String,
        input: MSPChatNamingInput,
        source: MSPChatSearchDescriptionRequestSource,
        generator: (any MSPChatSearchDescriptionGenerating)?,
        persistence: any MSPChatTitlePersisting,
        configuration: MSPChatNamingConfiguration,
        onEvent: @escaping MSPChatNamingEventHandler,
        now: @escaping @Sendable () -> Date
    ) async throws -> MSPChatSearchDescriptionRefreshOutcome {
        let initial = try await persistence.titleMetadata(for: chatID)
        guard let generator else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .generatorUnavailable,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }
        guard let initialRecord = initial.record, !initial.isUntitled else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .chatUntitled,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }
        guard let initialRevision = initial.revision else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .revisionUnavailable,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }

        let limits = configuration.limits
        let preparedInput = MSPChatNamingPrompt.preparedPrompt(
            from: input,
            maximumCharacters: limits.inputMaximumCharacters
        )
        let prompt = preparedInput.isEmpty ? initialRecord.title : preparedInput
        await onEvent(.searchDescriptionGenerationStarted(
            MSPChatSearchDescriptionGenerationStartedEvent(
                chatID: chatID,
                title: initialRecord.title,
                source: source,
                startedAt: now()
            )
        ))

        let generationRequest = MSPChatSearchDescriptionGenerationRequest(
            chatID: chatID,
            title: initialRecord.title,
            prompt: prompt,
            instructions: MSPChatNamingPrompt.searchDescriptionInstructions(
                descriptionMaximumCharacters: limits.descriptionMaximumCharacters
            ),
            model: configuration.model,
            descriptionMaximumCharacters: limits.descriptionMaximumCharacters,
            source: source
        )

        let description: String?
        do {
            description = try await withTimeout(
                nanoseconds: configuration.timeoutNanoseconds
            ) {
                try await generator.generateSearchDescription(
                    request: generationRequest
                )
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await onEvent(.searchDescriptionGenerationFailed(
                MSPChatSearchDescriptionGenerationFailedEvent(
                    chatID: chatID,
                    title: initialRecord.title,
                    source: source,
                    message: (error as NSError).localizedDescription,
                    failedAt: now()
                )
            ))
            throw MSPChatNamingReportedFailure(underlying: error)
        }

        guard let normalized = MSPChatNamingTextNormalizer.description(
            description,
            maximumCharacters: limits.descriptionMaximumCharacters
        ) else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .emptyGeneratedDescription,
                metadata: initial,
                onEvent: onEvent,
                now: now
            )
        }

        let latest = try await persistence.titleMetadata(for: chatID)
        guard let latestRecord = latest.record,
              latestRecord.title == initialRecord.title else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .titleChangedDuringGeneration,
                metadata: latest,
                onEvent: onEvent,
                now: now
            )
        }
        guard latest.revision == initialRevision else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .writeConditionNotMet,
                metadata: latest,
                onEvent: onEvent,
                now: now
            )
        }

        var updatedRecord = latestRecord
        updatedRecord.searchDescription = normalized
        updatedRecord.updatedAt = now()
        let result = try await persistence.writeTitle(
            updatedRecord,
            condition: .ifRevision(initialRevision)
        )
        guard result.didUpdate else {
            return await emitDescriptionSkip(
                chatID: chatID,
                source: source,
                reason: .writeConditionNotMet,
                metadata: result.metadata,
                onEvent: onEvent,
                now: now
            )
        }

        await onEvent(.searchDescriptionUpdated(
            MSPChatSearchDescriptionUpdatedEvent(
                eventID: UUID().uuidString,
                record: result.metadata.record ?? updatedRecord,
                source: source
            )
        ))
        return .updated(result.metadata)
    }

    static func emitTitleSkip(
        request: MSPChatNamingRequest,
        reason: MSPChatNamingSkipReason,
        metadata: MSPChatTitleMetadata,
        onEvent: @escaping MSPChatNamingEventHandler,
        now: @escaping @Sendable () -> Date
    ) async -> MSPChatNamingOutcome {
        await onEvent(.titleGenerationSkipped(
            MSPChatTitleGenerationSkippedEvent(
                chatID: request.chatID,
                source: request.source,
                reason: reason,
                skippedAt: now()
            )
        ))
        return .skipped(reason: reason, metadata: metadata)
    }

    static func emitDescriptionSkip(
        chatID: String,
        source: MSPChatSearchDescriptionRequestSource,
        reason: MSPChatSearchDescriptionSkipReason,
        metadata: MSPChatTitleMetadata,
        onEvent: @escaping MSPChatNamingEventHandler,
        now: @escaping @Sendable () -> Date
    ) async -> MSPChatSearchDescriptionRefreshOutcome {
        await onEvent(.searchDescriptionGenerationSkipped(
            MSPChatSearchDescriptionGenerationSkippedEvent(
                chatID: chatID,
                source: source,
                reason: reason,
                skippedAt: now()
            )
        ))
        return .skipped(reason: reason, metadata: metadata)
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

}

private struct MSPChatNamingReportedFailure: Error, @unchecked Sendable {
    var underlying: Error
}

private actor MSPChatNamingTimeoutResolver<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard !isResolved else {
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

private func withTimeout<Value: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    guard nanoseconds > 0 else {
        throw MSPChatNamingError.generationTimedOut
    }

    let resolver = MSPChatNamingTimeoutResolver<Value>()
    let operationTask = Task {
        do {
            await resolver.resolve(.success(try await operation()))
        } catch {
            await resolver.resolve(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            await resolver.resolve(
                .failure(MSPChatNamingError.generationTimedOut)
            )
        } catch {
            // Cancellation means another branch already resolved the race.
        }
    }

    defer {
        operationTask.cancel()
        timeoutTask.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await resolver.install(continuation)
            }
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        Task {
            await resolver.resolve(.failure(CancellationError()))
        }
    }
}
