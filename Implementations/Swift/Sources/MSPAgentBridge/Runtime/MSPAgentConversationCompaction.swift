import Foundation

extension MSPAgentConversation {
    enum PreTurnCompactionOutcome {
        case notRun
        case compacted
        case aborted(MSPAgentRunResult)
    }

    func runManualCompact(
        id turnID: UUID,
        onRequestBuilt: RequestBuiltHandler?,
        onEvent: @escaping EventHandler
    ) async throws -> MSPAgentRunResult {
        let decision = MSPCompactionDecision(
            trigger: .manual,
            reason: .userRequested,
            implementation: configuration.compactionPolicy.implementation(
                providerSupportsRemoteCompaction: providerSupportsRemoteCompaction
            ),
            phase: .standaloneTurn,
            strategy: .memento
        )

        switch decision.implementation {
        case .responses:
            return try await runManualLocalCompact(
                id: turnID,
                onRequestBuilt: onRequestBuilt,
                onEvent: onEvent
            )

        case .freshContextWindow:
            let body = requestBuilder.build(
                context: configuration.requestContext(prompt: "")
            )
            let envelope = try requestBuilder.envelope(from: body)
            let prefixItems = Array(envelope.input.prefix(max(0, envelope.input.count - 1)))
            return try await runFreshContextWindowCompaction(
                id: turnID,
                decision: decision,
                prefixItems: prefixItems,
                emitsCompactTurnStarted: true,
                onEvent: onEvent
            )

        case .responsesCompact, .responsesCompactionV2:
            let body = requestBuilder.build(
                context: configuration.requestContext(prompt: "")
            )
            let envelope = try requestBuilder.envelope(from: body)
            let prefixItems = Array(envelope.input.prefix(max(0, envelope.input.count - 1)))
            let promptTranscriptItems = promptTranscriptProjection().items
            return try await runRemoteCompaction(
                id: turnID,
                decision: decision,
                prefixItems: prefixItems,
                promptTranscriptItems: promptTranscriptItems,
                envelope: envelope,
                emitsCompactTurnStarted: true,
                onEvent: onEvent
            )
        }
    }

    func runManualLocalCompact(
        id turnID: UUID,
        onRequestBuilt: RequestBuiltHandler?,
        onEvent: @escaping EventHandler
    ) async throws -> MSPAgentRunResult {
        let decision = MSPCompactionDecision(
            trigger: .manual,
            reason: .userRequested,
            implementation: .responses,
            phase: .standaloneTurn,
            strategy: .memento
        )
        var requestContext = configuration.requestContext(
            prompt: MSPCompactionRequestBuilder.summarizationPrompt
        )
        requestContext.stream = true
        let body = requestBuilder.build(context: requestContext)
        await onRequestBuilt?(body)
        let envelope = try requestBuilder.envelope(from: body)
        let prefixItems = Array(envelope.input.prefix(max(0, envelope.input.count - 1)))
        let promptTranscriptItems = promptTranscriptProjection().items

        return try await runLocalCompaction(
            id: turnID,
            decision: decision,
            prefixItems: prefixItems,
            promptTranscriptItems: promptTranscriptItems,
            envelope: envelope,
            emitsCompactTurnStarted: true,
            onEvent: onEvent
        )
    }

    func runPreTurnAutoCompactIfNeeded(
        id turnID: UUID,
        prefixItems: [MSPAgentJSONValue],
        promptTranscriptItems: [MSPAgentJSONValue],
        projectedInputTokenCount: Int,
        envelope: MSPAgentRequestEnvelope,
        onEvent: @escaping EventHandler
    ) async throws -> PreTurnCompactionOutcome {
        guard !promptTranscriptItems.isEmpty || latestContextUsage != nil else {
            return .notRun
        }
        let tokenStatus = projectedPreTurnTokenStatus(
            currentUsage: latestContextUsage,
            projectedInputTokenCount: projectedInputTokenCount
        )
        guard let tokenStatus else {
            return .notRun
        }
        guard let decision = configuration.compactionPolicy.preTurnDecision(
            tokenStatus: tokenStatus,
            providerSupportsRemoteCompaction: providerSupportsRemoteCompaction
        ) else {
            return .notRun
        }
        if decision.implementation == .freshContextWindow {
            let result = try await runFreshContextWindowCompaction(
                id: turnID,
                decision: decision,
                prefixItems: prefixItems,
                emitsCompactTurnStarted: false,
                onEvent: onEvent
            )
            self.latestContextUsage = result.contextUsage
            return result.wasCancelled ? .aborted(result) : .compacted
        }
        if decision.implementation == .responsesCompact
            || decision.implementation == .responsesCompactionV2 {
            let result = try await runRemoteCompaction(
                id: turnID,
                decision: decision,
                prefixItems: prefixItems,
                promptTranscriptItems: promptTranscriptItems,
                envelope: envelope,
                emitsCompactTurnStarted: false,
                onEvent: onEvent
            )
            self.latestContextUsage = result.contextUsage
            return result.wasCancelled ? .aborted(result) : .compacted
        }

        guard decision.implementation == .responses else {
            throw MSPAgentModelClientError.apiError(
                "MSP pre-turn compaction implementation \(decision.implementation.rawValue) is not supported."
            )
        }

        let result = try await runLocalCompaction(
            id: turnID,
            decision: decision,
            prefixItems: prefixItems,
            promptTranscriptItems: promptTranscriptItems,
            envelope: envelope,
            emitsCompactTurnStarted: false,
            onEvent: onEvent
        )
        self.latestContextUsage = result.contextUsage
        return result.wasCancelled ? .aborted(result) : .compacted
    }

    func runMidTurnAutoCompactIfNeeded(
        id turnID: UUID,
        prefixItemCount: Int,
        envelope: MSPAgentRequestEnvelope,
        context: MSPAgentToolLoop.MidTurnCompactionContext,
        onEvent: @escaping EventHandler
    ) async throws -> MSPAgentToolLoop.MidTurnCompactionUpdate? {
        guard let currentContextUsage = context.latestContextUsage else {
            return nil
        }
        let tokenStatus = MSPCompactionTokenStatus(
            activeTokens: currentContextUsage.currentTokens,
            contextWindowTokens: currentContextUsage.contextWindowTokens,
            autoCompactTokenLimit: currentContextUsage.autoCompactTokenLimit,
            currentWindowPrefillTokens: currentWindowPrefillTokensForLimitEvaluation(
                observing: currentContextUsage,
                protectsImmediateFollowUp: context.modelNeedsFollowUp || context.hasPendingInput
            )
        )
        let evaluation = configuration.compactionPolicy.evaluateMidTurn(
            tokenStatus: tokenStatus,
            providerSupportsRemoteCompaction: providerSupportsRemoteCompaction,
            modelNeedsFollowUp: context.modelNeedsFollowUp,
            hasPendingInput: context.hasPendingInput
        )
        guard let decision = evaluation.decision else {
            return nil
        }
        let prefixCount = min(max(0, prefixItemCount), context.liveInput.count)
        let prefixItems = Array(context.liveInput.prefix(prefixCount))
        let splitBody = splitMidTurnCompactionBody(
            liveInput: context.liveInput,
            prefixCount: prefixCount,
            transcriptAppendItems: context.transcriptAppendItems,
            preserveTranscriptAppendItems: context.preserveTranscriptAppendItems
        )
        if decision.implementation == .freshContextWindow {
            let result = try await runFreshContextWindowCompaction(
                id: turnID,
                decision: decision,
                prefixItems: prefixItems,
                emitsCompactTurnStarted: false,
                onEvent: onEvent
            )
            latestContextUsage = result.contextUsage
            if result.wasCancelled {
                throw CancellationError()
            }
            await replaceActiveTurnTranscriptAppendItems(splitBody.preservedSuffixItems, id: turnID)
            return MSPAgentToolLoop.MidTurnCompactionUpdate(
                liveInput: prefixItems + splitBody.preservedSuffixItems,
                transcriptAppendItems: splitBody.preservedSuffixItems,
                contextUsage: result.contextUsage,
                canDrainPendingInput: evaluation.canDrainPendingInputAfterCompaction
            )
        }
        if decision.implementation == .responsesCompact
            || decision.implementation == .responsesCompactionV2 {
            let result = try await runRemoteCompaction(
                id: turnID,
                decision: decision,
                prefixItems: prefixItems,
                promptTranscriptItems: splitBody.promptTranscriptItems,
                envelope: envelope,
                emitsCompactTurnStarted: false,
                onEvent: onEvent
            )
            latestContextUsage = result.contextUsage
            if result.wasCancelled {
                throw CancellationError()
            }
            await replaceActiveTurnTranscriptAppendItems(splitBody.preservedSuffixItems, id: turnID)
            return MSPAgentToolLoop.MidTurnCompactionUpdate(
                liveInput: prefixItems + transcriptItems + splitBody.preservedSuffixItems,
                transcriptAppendItems: splitBody.preservedSuffixItems,
                contextUsage: result.contextUsage,
                canDrainPendingInput: evaluation.canDrainPendingInputAfterCompaction
            )
        }

        guard decision.implementation == .responses else {
            throw MSPAgentModelClientError.apiError(
                "MSP mid-turn compaction implementation \(decision.implementation.rawValue) is not supported."
            )
        }

        let result = try await runLocalCompaction(
            id: turnID,
            decision: decision,
            prefixItems: prefixItems,
            promptTranscriptItems: splitBody.promptTranscriptItems,
            envelope: envelope,
            emitsCompactTurnStarted: false,
            onEvent: onEvent
        )
        latestContextUsage = result.contextUsage
        if result.wasCancelled {
            throw CancellationError()
        }
        await replaceActiveTurnTranscriptAppendItems(splitBody.preservedSuffixItems, id: turnID)
        return MSPAgentToolLoop.MidTurnCompactionUpdate(
            liveInput: prefixItems + transcriptItems + splitBody.preservedSuffixItems,
            transcriptAppendItems: splitBody.preservedSuffixItems,
            contextUsage: result.contextUsage,
            canDrainPendingInput: evaluation.canDrainPendingInputAfterCompaction
        )
    }

    func splitMidTurnCompactionBody(
        liveInput: [MSPAgentJSONValue],
        prefixCount: Int,
        transcriptAppendItems: [MSPAgentJSONValue],
        preserveTranscriptAppendItems: Bool
    ) -> (
        promptTranscriptItems: [MSPAgentJSONValue],
        preservedSuffixItems: [MSPAgentJSONValue]
    ) {
        let bodyItems = Array(liveInput.dropFirst(prefixCount))
        guard preserveTranscriptAppendItems,
              !transcriptAppendItems.isEmpty,
              bodyItems.count >= transcriptAppendItems.count
        else {
            return (bodyItems, [])
        }

        let suffixItems = Array(bodyItems.suffix(transcriptAppendItems.count))
        guard suffixItems == transcriptAppendItems else {
            return (bodyItems, [])
        }

        return (
            Array(bodyItems.dropLast(transcriptAppendItems.count)),
            suffixItems
        )
    }

    func runFreshContextWindowCompaction(
        id turnID: UUID,
        decision: MSPCompactionDecision,
        prefixItems: [MSPAgentJSONValue],
        emitsCompactTurnStarted: Bool,
        onEvent: @escaping EventHandler
    ) async throws -> MSPAgentRunResult {
        let operation = MSPCompactionOperation(
            id: turnID.uuidString,
            decision: decision
        )
        var stateMachine = MSPCompactionStateMachine()
        stateMachine.begin(operation)

        if emitsCompactTurnStarted {
            await onEvent(.compactTurnStarted(turnID))
        }

        let preCompactOutcome = await compactionHooks.preCompact(operation: operation)
        if preCompactOutcome.shouldStop {
            stateMachine.abort()
            return Self.abortedCompactionResult()
        }
        stateMachine.markPreCompactHookCompleted()

        let compactionItem = MSPContextCompactionItem()
        await onEvent(.contextCompactionStarted(compactionItem.id))
        stateMachine.markStartedItemEmitted()

        let sourceItems = transcriptItems
        let nextLineage = nextContextWindowLineage()
        try await installCompactionCheckpoint(
            checkpointID: compactionItem.id,
            sourceItems: sourceItems,
            replacementHistory: prefixItems,
            summaryRef: nil,
            lineage: nextLineage.lineage
        )
        transcriptItems = []
        applyContextWindowLineageState(nextLineage.state)

        let recomputedContextUsage = estimatedContextUsageRecord(for: prefixItems)
        if let recomputedContextUsage {
            installEstimatedWindowPrefill(from: recomputedContextUsage)
            await onEvent(.contextUsageUpdated(recomputedContextUsage))
        } else {
            currentWindowPrefillTokens = nil
        }
        stateMachine.markReplacementInstalled()
        stateMachine.markUsageRecomputed()

        await onEvent(.contextCompactionCompleted(compactionItem.id))

        var result = MSPAgentRunResult(
            finalAnswer: "",
            toolResults: [],
            transcriptAppendItems: [],
            contextUsage: recomputedContextUsage
        )
        let postCompactOutcome = await compactionHooks.postCompact(operation: operation)
        if postCompactOutcome.shouldStop {
            stateMachine.abort()
            result.wasCancelled = true
            return result
        }
        stateMachine.complete()
        return result
    }

    func runLocalCompaction(
        id turnID: UUID,
        decision: MSPCompactionDecision,
        prefixItems: [MSPAgentJSONValue],
        promptTranscriptItems: [MSPAgentJSONValue],
        envelope: MSPAgentRequestEnvelope,
        emitsCompactTurnStarted: Bool,
        onEvent: @escaping EventHandler
    ) async throws -> MSPAgentRunResult {
        let operation = MSPCompactionOperation(
            id: turnID.uuidString,
            decision: decision
        )
        var stateMachine = MSPCompactionStateMachine()
        stateMachine.begin(operation)

        if emitsCompactTurnStarted {
            await onEvent(.compactTurnStarted(turnID))
        }

        let preCompactOutcome = await compactionHooks.preCompact(operation: operation)
        if preCompactOutcome.shouldStop {
            stateMachine.abort()
            return Self.abortedCompactionResult()
        }
        stateMachine.markPreCompactHookCompleted()

        let compactPromptItems = [
            compactionRequestBuilder.localPromptItem(prompt: MSPCompactionRequestBuilder.summarizationPrompt)
        ]
        let historyRewrite = compactionRequestBuilder.localCompactHistoryByRewritingOutputsToFitContextWindow(
            prefixItems: prefixItems,
            historyItems: promptTranscriptItems,
            suffixItems: compactPromptItems,
            contextWindow: localCompactionRewriteContextWindow(),
            estimatedTokenCount: { items in
                Self.approximateTokenCount(in: items)
            }
        )
        var compactAttemptHistoryItems = historyRewrite.historyItems

        let compactionItem = MSPContextCompactionItem()
        await onEvent(.contextCompactionStarted(compactionItem.id))
        stateMachine.markStartedItemEmitted()

        var compactOutput: MSPAgentModelTurnOutput?
        while compactOutput == nil {
            let fullInput = prefixItems + compactAttemptHistoryItems + compactPromptItems
            let compactEnvelope = try compactionRequestBuilder.applyingCompactionMetadata(
                to: envelope.replacingInput(fullInput),
                decision: decision,
                windowID: currentContextWindowID,
                turnID: turnID.uuidString
            )
            do {
                compactOutput = try await modelClient.nextTurn(
                    request: compactEnvelope,
                    onDelta: { _ in },
                    onAssistantMessage: { _ in },
                    onToolCallPreparing: { _ in }
                )
            } catch {
                if Self.isCancellationLikeError(error) {
                    stateMachine.abort()
                    throw error
                }
                if Self.isContextWindowExceededError(error),
                   !compactAttemptHistoryItems.isEmpty {
                    compactAttemptHistoryItems.removeFirst()
                    continue
                }
                if Self.isContextWindowExceededError(error),
                   let contextUsage = MSPAgentContextUsageAdapter.fullWindowRecord(
                    modelID: configuration.model,
                    modelDisplayName: configuration.model
                   ) {
                    await onEvent(.contextUsageUpdated(contextUsage))
                }
                stateMachine.fail()
                await onEvent(.contextCompactionFailed(
                    compactionItem.id,
                    message: Self.compactionFailureMessage(for: error)
                ))
                throw error
            }
        }
        guard let output = compactOutput else {
            throw CancellationError()
        }

        let summary = Self.lastAssistantSummary(from: output)
        let rewrite = MSPCompactionHistoryRewriter.localReplacementHistory(
            from: promptTranscriptItems,
            assistantSummary: summary
        )
        let nextLineage = nextContextWindowLineage()
        try await installCompactionCheckpoint(
            checkpointID: compactionItem.id,
            sourceItems: promptTranscriptItems,
            replacementHistory: rewrite.replacementHistory,
            summaryRef: rewrite.summaryText,
            lineage: nextLineage.lineage
        )
        transcriptItems = rewrite.replacementHistory
        applyContextWindowLineageState(nextLineage.state)
        let recomputedContextUsage = estimatedContextUsageRecord(
            for: prefixItems + rewrite.replacementHistory
        )
        if let recomputedContextUsage {
            installEstimatedWindowPrefill(from: recomputedContextUsage)
            await onEvent(.contextUsageUpdated(recomputedContextUsage))
        } else {
            currentWindowPrefillTokens = nil
        }
        stateMachine.markReplacementInstalled()
        stateMachine.markUsageRecomputed()

        await onEvent(.contextCompactionCompleted(compactionItem.id))
        let warning = "Heads up: Long threads and multiple compactions can cause the model to be less accurate. Start a new thread when possible to keep threads small and targeted."
        await onEvent(.compactionWarning(warning))

        let result = MSPAgentRunResult(
            finalAnswer: "",
            toolResults: [],
            responseID: output.responseID,
            transcriptAppendItems: [],
            contextUsage: recomputedContextUsage
        )
        let postCompactOutcome = await compactionHooks.postCompact(operation: operation)
        if postCompactOutcome.shouldStop {
            stateMachine.abort()
            var aborted = result
            aborted.wasCancelled = true
            return aborted
        }
        stateMachine.complete()
        return result
    }

    func nextContextWindowLineage() -> (
        state: MSPContextWindowLineageState,
        lineage: MSPCompactionWindowLineage
    ) {
        var nextState = contextWindowLineage
        let lineage = nextState.advance()
        return (nextState, lineage)
    }

    func applyContextWindowLineageState(_ state: MSPContextWindowLineageState) {
        contextWindowLineage = state
        currentContextWindowID = contextWindowLineage.currentWindowID
        previousContextWindowID = contextWindowLineage.previousWindowID
        contextWindowNumber = contextWindowLineage.windowNumber
    }

    func installCompactionCheckpoint(
        checkpointID: String,
        sourceItems: [MSPAgentJSONValue],
        replacementHistory: [MSPAgentJSONValue],
        summaryRef: String?,
        lineage: MSPCompactionWindowLineage
    ) async throws {
        let checkpoint = try MSPCompactionCheckpointBuilder.checkpoint(
            checkpointID: checkpointID,
            sourceItems: sourceItems,
            replacementHistory: replacementHistory,
            summaryRef: summaryRef,
            lineage: lineage
        )
        try await compactionPersistenceAdapter.install(checkpoint: checkpoint)
    }

    static func lastAssistantSummary(
        from output: MSPAgentModelTurnOutput
    ) -> String {
        if let assistantMessage = output.assistantMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !assistantMessage.isEmpty {
            return assistantMessage
        }
        if let finalAnswer = output.finalAnswer?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !finalAnswer.isEmpty {
            return finalAnswer
        }

        for item in output.nativeOutputItems.reversed() {
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "message",
                  object["role"]?.stringValue == "assistant",
                  let content = object["content"]?.arrayValue else {
                continue
            }
            let text = content
                .compactMap { value -> String? in
                    guard let object = value.objectValue else {
                        return nil
                    }
                    return object["text"]?.stringValue
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return ""
    }

    static func abortedCompactionResult() -> MSPAgentRunResult {
        MSPAgentRunResult(
            finalAnswer: "",
            toolResults: [],
            transcriptAppendItems: [],
            wasCancelled: true
        )
    }

    static func compactionFailureMessage(for error: Error) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return String(describing: error)
        }
        return description
    }

    static func isContextWindowExceededError(_ error: Error) -> Bool {
        MSPAgentModelClientError.isLikelyContextWindowExceeded(error)
    }

    private func localCompactionRewriteContextWindow() -> Int? {
        if let effectiveWindow = latestContextUsage?.effectiveContextWindowTokens,
           effectiveWindow > 0 {
            return effectiveWindow
        }
        if let contextWindow = latestContextUsage?.contextWindowTokens,
           contextWindow > 0 {
            return contextWindow
        }
        return MSPAgentContextWindowProfile.profile(for: configuration.model)?
            .effectiveContextWindowTokens
    }
}
