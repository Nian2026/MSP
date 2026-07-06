import Foundation

extension MSPAgentConversation {
    var providerSupportsRemoteCompaction: Bool {
        remoteCompactionClient?.supportsRemoteCompaction == true
    }

    private var remoteCompactionClient: (any MSPAgentRemoteCompactionClient)? {
        modelClient as? any MSPAgentRemoteCompactionClient
    }

    func runRemoteCompaction(
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

        let compactionItem = MSPContextCompactionItem()
        await onEvent(.contextCompactionStarted(compactionItem.id))
        stateMachine.markStartedItemEmitted()

        let compactInput = rewrittenRemoteCompactInput(
            prefixItems: prefixItems,
            promptTranscriptItems: promptTranscriptItems
        )

        let replacementHistory: [MSPAgentJSONValue]
        let responseID: String?
        do {
            switch decision.implementation {
            case .responsesCompact:
                replacementHistory = try await runRemoteCompactV1(
                    input: compactInput,
                    decision: decision,
                    envelope: envelope,
                    turnID: turnID
                )
                responseID = nil

            case .responsesCompactionV2:
                let output = try await runRemoteCompactV2(
                    input: compactInput,
                    decision: decision,
                    envelope: envelope,
                    turnID: turnID
                )
                replacementHistory = output.replacementHistory
                responseID = output.responseID

            case .responses, .freshContextWindow:
                throw MSPAgentModelClientError.apiError(
                    "MSP remote compaction received unsupported implementation \(decision.implementation.rawValue)."
                )
            }
        } catch {
            if Self.isCancellationLikeError(error) {
                stateMachine.abort()
                throw error
            }
            stateMachine.fail()
            await onEvent(.contextCompactionFailed(
                compactionItem.id,
                message: Self.remoteCompactionFailureMessage(for: error)
            ))
            throw error
        }

        let nextLineage = nextContextWindowLineage()
        try await installCompactionCheckpoint(
            checkpointID: compactionItem.id,
            sourceItems: promptTranscriptItems,
            replacementHistory: replacementHistory,
            summaryRef: nil,
            lineage: nextLineage.lineage
        )
        transcriptItems = replacementHistory
        applyContextWindowLineageState(nextLineage.state)

        let recomputedContextUsage = estimatedContextUsageRecord(
            for: prefixItems + replacementHistory
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

        let result = MSPAgentRunResult(
            finalAnswer: "",
            toolResults: [],
            responseID: responseID,
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

    private func rewrittenRemoteCompactInput(
        prefixItems: [MSPAgentJSONValue],
        promptTranscriptItems: [MSPAgentJSONValue]
    ) -> [MSPAgentJSONValue] {
        let fullInput = prefixItems + promptTranscriptItems
        let rewrite = compactionRequestBuilder.remoteCompactInputByRewritingOutputsToFitContextWindow(
            fullInput,
            contextWindow: latestContextUsage?.contextWindowTokens
        ) { items in
            Self.approximateTokenCount(in: items)
        }
        return rewrite.input
    }

    private func runRemoteCompactV1(
        input: [MSPAgentJSONValue],
        decision: MSPCompactionDecision,
        envelope: MSPAgentRequestEnvelope,
        turnID: UUID
    ) async throws -> [MSPAgentJSONValue] {
        guard let remoteCompactionClient else {
            throw MSPAgentModelClientError.apiError(
                "MSP remote compaction requires a model client that supports /responses/compact."
            )
        }
        let compactEnvelope = try compactionRequestBuilder.applyingCompactionMetadata(
            to: envelope.replacingInput(input),
            decision: decision,
            windowID: currentContextWindowID,
            turnID: turnID.uuidString
        )
        let payload = try compactionRequestBuilder.remoteCompactPayload(
            from: compactEnvelope,
            includeMetadata: remoteCompactionClient.supportsRequestMetadata
        )
        let serverOutput = try await remoteCompactionClient.compactConversation(payload: payload)
        return MSPCompactionHistoryRewriter.remoteCompactedHistory(serverOutput: serverOutput)
    }

    private func runRemoteCompactV2(
        input: [MSPAgentJSONValue],
        decision: MSPCompactionDecision,
        envelope: MSPAgentRequestEnvelope,
        turnID: UUID
    ) async throws -> (replacementHistory: [MSPAgentJSONValue], responseID: String?) {
        let remoteV2Input = compactionRequestBuilder.remoteV2Input(promptInput: input)
        let compactEnvelope = try compactionRequestBuilder.applyingCompactionMetadata(
            to: envelope.replacingInput(remoteV2Input),
            decision: decision,
            windowID: currentContextWindowID,
            turnID: turnID.uuidString
        )
        let output = try await modelClient.nextTurn(
            request: compactEnvelope,
            onDelta: { _ in },
            onAssistantMessage: { _ in },
            onToolCallPreparing: { _ in }
        )
        let collected = try MSPCompactionRequestBuilder.collectRemoteV2Output(
            outputItems: output.nativeOutputItems,
            sawCompleted: output.sawCompleted,
            tokenUsage: output.tokenUsage
        )
        let rewrite = MSPCompactionHistoryRewriter.remoteV2CompactedHistory(
            promptInput: input,
            compactionOutput: collected.compactionOutput
        )
        return (rewrite.replacementHistory, output.responseID)
    }

    static func remoteCompactionFailureMessage(for error: Error) -> String {
        "Error running remote compact task: \(compactionFailureMessage(for: error))"
    }
}
