import Foundation

public struct MSPAgentToolLoop: Sendable {
    public var modelClient: any MSPAgentModelTurnClient
    public var toolCallLimit: MSPAgentToolCallLimit
    public var maximumToolCalls: Int {
        get {
            toolCallLimit.remainingToolCalls ?? Int.max
        }
        set {
            toolCallLimit = .maximum(newValue)
        }
    }
    public var maximumTransientModelStreamRetries: Int
    public var modelID: String
    public var modelDisplayName: String
    public var modelProfile: MSPResolvedModelProfile?

    public init(
        modelClient: any MSPAgentModelTurnClient,
        toolCallLimit: MSPAgentToolCallLimit = .unlimited,
        maximumTransientModelStreamRetries: Int = 1,
        modelID: String = "",
        modelDisplayName: String = "",
        modelProfile: MSPResolvedModelProfile? = nil
    ) {
        self.modelClient = modelClient
        self.toolCallLimit = toolCallLimit
        self.maximumTransientModelStreamRetries = max(0, maximumTransientModelStreamRetries)
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.modelProfile = modelProfile
    }

    public init(
        modelClient: any MSPAgentModelTurnClient,
        maximumToolCalls: Int,
        maximumTransientModelStreamRetries: Int = 1,
        modelID: String = "",
        modelDisplayName: String = "",
        modelProfile: MSPResolvedModelProfile? = nil
    ) {
        self.init(
            modelClient: modelClient,
            toolCallLimit: .maximum(maximumToolCalls),
            maximumTransientModelStreamRetries: maximumTransientModelStreamRetries,
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            modelProfile: modelProfile
        )
    }

    public func run(
        request: MSPAgentRequestEnvelope,
        dynamicDeveloperContext: DynamicDeveloperContext = DynamicDeveloperContext(),
        initialTranscriptAppendItems: [MSPAgentJSONValue],
        onTranscriptAppend: (@Sendable ([MSPAgentJSONValue]) async -> Void)? = nil,
        onStreamedTranscriptUpdate: (@Sendable (String, String) async -> Void)? = nil,
        pendingInputProvider: PendingInputProvider? = nil,
        midTurnCompaction: MidTurnCompactionHandler? = nil,
        planModeRuntime: MSPPlanModeRuntimeSession? = nil,
        onEvent: @escaping EventHandler,
        executeTool: @escaping ToolExecutor
    ) async throws -> MSPAgentRunResult {
        var liveInput = request.input
        var transcriptAppendItems = initialTranscriptAppendItems
        var pendingToolResults: [MSPAgentToolResult] = []
        var allToolResults: [MSPAgentToolResult] = []
        var latestResponseID: String?
        var modelRequestSequence = 0
        let modelRequestRunID = UUID().uuidString
        var latestContextUsage: MSPAgentContextUsageRecord?
        var remainingToolCalls = toolCallLimit.remainingToolCalls
        var protocolRetryCount = 0
        var contextWindowExceededCompactionRetryCount = 0
        var contextWindowExceededProjectionRetryCount = 0
        var promptToolOutputTokenLimit = MSPAgentPromptTranscriptNormalizer.defaultMaxPromptToolOutputTokens
        var consecutiveAssistantMessageCheckpointCount = 0
        var forcedCheckpointContinuationCount = 0
        var lastAssistantMessage = ""
        var isForcingFinalAnswer = false
        var canDrainPendingInput = false
        let assistantProgressEmissionState = MSPAgentAssistantProgressEmissionState()
        let planModeStreamState = MSPAgentPlanModeStreamState()

        func fullWindowUsageRecord() -> MSPAgentContextUsageRecord? {
            if let modelProfile {
                return MSPAgentContextUsageAdapter.fullWindowRecord(
                    profile: modelProfile,
                    modelID: modelID,
                    modelDisplayName: modelDisplayName
                )
            }
            return MSPAgentContextUsageAdapter.fullWindowRecord(
                modelID: modelID,
                modelDisplayName: modelDisplayName
            )
        }

        func contextUsageRecord(
            usage: MSPAgentTokenUsage?
        ) -> MSPAgentContextUsageRecord? {
            if let modelProfile {
                return MSPAgentContextUsageAdapter.record(
                    usage: usage,
                    profile: modelProfile,
                    modelID: modelID,
                    modelDisplayName: modelDisplayName
                )
            }
            return MSPAgentContextUsageAdapter.record(
                usage: usage,
                modelID: modelID,
                modelDisplayName: modelDisplayName
            )
        }

        func finish(
            _ answer: String,
            provenance output: MSPAgentModelTurnOutput? = nil,
            requestEvidence: MSPAgentModelRequestEvidence? = nil
        ) async -> MSPAgentRunResult {
            if let output {
                await onEvent(.probe(Self.finalAnswerProvenanceProbeEvent(
                    answer: answer,
                    output: output,
                    latestResponseID: latestResponseID,
                    requestEvidence: requestEvidence
                )))
            }
            await onEvent(.finalAnswer(answer))
            return MSPAgentRunResult(
                finalAnswer: answer,
                toolResults: allToolResults,
                responseID: latestResponseID,
                transcriptAppendItems: transcriptAppendItems,
                contextUsage: latestContextUsage,
                planModeProposalContent: await planModeStreamState.proposalContent()
            )
        }

        func finishPlanModeTurn(visibleText: String = "") async -> MSPAgentRunResult {
            let answer = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            return MSPAgentRunResult(
                finalAnswer: answer,
                toolResults: allToolResults,
                responseID: latestResponseID,
                transcriptAppendItems: transcriptAppendItems,
                contextUsage: latestContextUsage,
                planModeProposalContent: await planModeStreamState.proposalContent()
            )
        }

        func appendPendingToolResultItemsIfNeeded() async throws {
            guard !pendingToolResults.isEmpty else {
                return
            }
            let pendingToolResultItems = try MSPResponsesStreamingModelClient
                .toolOutputInputItems(from: pendingToolResults)
            liveInput.append(contentsOf: pendingToolResultItems)
            transcriptAppendItems.append(contentsOf: pendingToolResultItems)
            await onTranscriptAppend?(pendingToolResultItems)
            pendingToolResults.removeAll(keepingCapacity: true)
        }

        func pendingInput(_ request: PendingInputRequest) async -> [MSPAgentJSONValue] {
            guard let pendingInputProvider else {
                return []
            }
            return await pendingInputProvider(request)
        }

        func hasPendingInput() async -> Bool {
            !(await pendingInput(.peek)).isEmpty
        }

        func appendPendingInputIfAllowed() async {
            guard canDrainPendingInput else {
                return
            }
            let pendingInputItems = await pendingInput(.drain)
            guard !pendingInputItems.isEmpty else {
                return
            }
            liveInput.append(contentsOf: pendingInputItems)
            transcriptAppendItems.append(contentsOf: pendingInputItems)
            await onTranscriptAppend?(pendingInputItems)
        }

        func applyMidTurnCompactionUpdate(_ update: MidTurnCompactionUpdate) {
            liveInput = update.liveInput
            transcriptAppendItems = update.transcriptAppendItems
            if let contextUsage = update.contextUsage {
                latestContextUsage = contextUsage
            }
            canDrainPendingInput = update.canDrainPendingInput
        }

        func runMidTurnCompactionIfNeeded(
            modelNeedsFollowUp: Bool,
            hasPendingInput: Bool,
            latestContextUsageOverride: MSPAgentContextUsageRecord? = nil,
            preserveTranscriptAppendItems: Bool = false
        ) async throws -> Bool {
            guard let midTurnCompaction else {
                return false
            }
            let context = MidTurnCompactionContext(
                liveInput: liveInput,
                transcriptAppendItems: transcriptAppendItems,
                latestContextUsage: latestContextUsageOverride ?? latestContextUsage,
                modelNeedsFollowUp: modelNeedsFollowUp,
                hasPendingInput: hasPendingInput,
                preserveTranscriptAppendItems: preserveTranscriptAppendItems
            )
            guard let update = try await midTurnCompaction(context) else {
                return false
            }
            applyMidTurnCompactionUpdate(update)
            return true
        }

        func runContextWindowExceededCompactionRetryIfNeeded() async throws -> Bool {
            guard contextWindowExceededCompactionRetryCount < 1,
                  midTurnCompaction != nil,
                  let fullWindowUsage = fullWindowUsageRecord()
            else {
                return false
            }

            contextWindowExceededCompactionRetryCount += 1
            latestContextUsage = fullWindowUsage
            await onEvent(.contextUsageUpdated(fullWindowUsage))
            return try await runMidTurnCompactionIfNeeded(
                modelNeedsFollowUp: true,
                hasPendingInput: await hasPendingInput(),
                latestContextUsageOverride: fullWindowUsage,
                preserveTranscriptAppendItems: true
            )
        }

        func cancelledResult() async throws -> MSPAgentRunResult {
            try await appendPendingToolResultItemsIfNeeded()
            transcriptAppendItems.append(
                MSPTurnInterruptChatMapping.interruptedMarkerInputItem()
            )
            return MSPAgentRunResult(
                finalAnswer: "",
                toolResults: allToolResults,
                responseID: latestResponseID,
                transcriptAppendItems: transcriptAppendItems,
                wasCancelled: true,
                contextUsage: latestContextUsage,
                planModeProposalContent: await planModeStreamState.proposalContent()
            )
        }

        func emitAssistantProgress(_ text: String, segmentID: UUID) async {
            guard await assistantProgressEmissionState.markEmittedIfNeeded(text) else {
                return
            }
            await onEvent(.assistantProgressSegmentStarted(segmentID))
            await onEvent(.assistantProgress(text))
        }

        @Sendable func planModeVisibleDeltas(from text: String) async -> [String] {
            guard let planModeRuntime else {
                return [text]
            }
            let chunk = await planModeRuntime.consumeDelta(text)
            for delta in chunk.proposedPlanDeltas where !delta.isEmpty {
                await onEvent(await planModeRuntime.deltaEvent(delta))
            }
            if let proposedPlanContent = chunk.proposedPlanContent {
                await planModeStreamState.setProposalContent(proposedPlanContent)
            }
            guard !chunk.visibleText.isEmpty else {
                return []
            }
            return [chunk.visibleText]
        }

        func planModeCompletedOutput(
            _ output: MSPAgentModelTurnOutput
        ) async -> (
            assistantMessage: String?,
            finalAnswer: String?,
            nativeOutputItems: [MSPAgentJSONValue]
        ) {
            guard planModeRuntime != nil else {
                return (
                    output.assistantMessage,
                    output.finalAnswer,
                    output.nativeOutputItems
                )
            }
            if let streamProposal = await planModeRuntime?.proposedPlanContent(),
               !streamProposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await planModeStreamState.setProposalContent(streamProposal)
            }
            if let completedProposal = MSPPlanModeRuntime.firstProposedPlan(in: output),
               !completedProposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await planModeStreamState.setProposalContent(completedProposal)
            }
            return (
                output.assistantMessage.map {
                    MSPPlanModeRuntime.parseCompletedText($0).visibleText
                },
                output.finalAnswer.map {
                    MSPPlanModeRuntime.parseCompletedText($0).visibleText
                },
                MSPPlanModeRuntime.sanitizedNativeOutputItems(output.nativeOutputItems)
            )
        }

        while !Task.isCancelled {
            var completedModelOutput: MSPAgentModelTurnOutput?
            var completedModelRequestEvidence: MSPAgentModelRequestEvidence?
            var completedStreamedAssistantMessageText = ""
            var completedStreamedFinalAnswerText = ""
            var modelStreamRetryCount = 0
            let assistantProgressSegmentID = UUID()

            while completedModelOutput == nil {
                try await appendPendingToolResultItemsIfNeeded()
                await appendPendingInputIfAllowed()
                if !dynamicDeveloperContext.isEmpty {
                    let refreshedContextTexts = await MSPAgentDynamicDeveloperContextBlock.resolveAll(
                        dynamicDeveloperContext.blocks
                    )
                    liveInput = Self.replacingDynamicDeveloperContext(
                        in: liveInput,
                        contentStartIndex: dynamicDeveloperContext.contentStartIndex,
                        texts: refreshedContextTexts
                    )
                }
                let providerInput = MSPAgentPromptTranscriptNormalizer
                    .normalizedItemsForPrompt(
                        liveInput,
                        maxToolOutputTokens: promptToolOutputTokenLimit
                    )
                let modelRequest = request.replacingInput(providerInput)
                let streamedAssistantMessageBuffer = MSPAgentStreamedTextBuffer()
                let streamedFinalAnswerBuffer = MSPAgentStreamedTextBuffer()
                let assistantMessageStreamGate = MSPAgentStructuredActivationSuppressionGate()
                let finalAnswerStreamGate = MSPAgentStructuredActivationSuppressionGate()
                let assistantProgressStreamStartState = MSPAgentStreamStartState()
                let finalAnswerStreamStartState = MSPAgentStreamStartState()
                modelRequestSequence += 1
                let modelRequestEvidence = MSPAgentModelRequestEvidence(
                    runID: modelRequestRunID,
                    sequence: modelRequestSequence,
                    request: modelRequest
                )
                await onEvent(.probe(MSPAgentProbeEvent(
                    name: "model_request_built",
                    fields: modelRequestEvidence.requestFields
                )))
                do {
                    completedModelOutput = try await modelClient.nextTurn(
                        request: modelRequest,
                        onDelta: { delta in
                            switch delta.phase {
                            case .assistantMessage:
                                await planModeStreamState.setLastStreamPhase(.assistantMessage)
                                let visibleDeltas = await assistantMessageStreamGate.visibleDeltas(after: delta.text)
                                for gatedDelta in visibleDeltas {
                                    let visiblePlanDeltas = await planModeVisibleDeltas(from: gatedDelta)
                                    for visibleDelta in visiblePlanDeltas {
                                    await streamedAssistantMessageBuffer.append(visibleDelta)
                                    await onStreamedTranscriptUpdate?(
                                        await streamedAssistantMessageBuffer.value(),
                                        "assistant_message"
                                    )
                                    if await assistantProgressStreamStartState.markStartedIfNeeded() {
                                        await onEvent(.assistantProgressSegmentStarted(assistantProgressSegmentID))
                                    }
                                    await onEvent(.assistantProgressDelta(visibleDelta))
                                    }
                                }

                            case .finalAnswer:
                                await planModeStreamState.setLastStreamPhase(.finalAnswer)
                                let visibleDeltas = await finalAnswerStreamGate.visibleDeltas(after: delta.text)
                                for gatedDelta in visibleDeltas {
                                    let visiblePlanDeltas = await planModeVisibleDeltas(from: gatedDelta)
                                    for visibleDelta in visiblePlanDeltas {
                                    await streamedFinalAnswerBuffer.append(visibleDelta)
                                    await onStreamedTranscriptUpdate?(
                                        await streamedFinalAnswerBuffer.value(),
                                        "final_answer"
                                    )
                                    if await finalAnswerStreamStartState.markStartedIfNeeded() {
                                        await onEvent(.finalAnswerStarted)
                                    }
                                    await onEvent(.finalAnswerDelta(visibleDelta))
                                    }
                                }

                            case .unknown:
                                break
                            }
                        },
                        onAssistantMessage: { _ in },
                        onToolCallPreparing: { toolName in
                            await onEvent(.toolPreparing(toolName, statusText: Self.preparationStatusText(for: toolName)))
                        }
                    )
                    if let planModeRuntime {
                        let tail = await planModeRuntime.finish()
                        for delta in tail.proposedPlanDeltas where !delta.isEmpty {
                            await onEvent(await planModeRuntime.deltaEvent(delta))
                        }
                        if let proposedPlanContent = tail.proposedPlanContent {
                            await planModeStreamState.setProposalContent(proposedPlanContent)
                        }
                        if !tail.visibleText.isEmpty {
                            switch await planModeStreamState.lastStreamPhase() {
                            case .assistantMessage:
                                await streamedAssistantMessageBuffer.append(tail.visibleText)
                                await onStreamedTranscriptUpdate?(
                                    await streamedAssistantMessageBuffer.value(),
                                    "assistant_message"
                                )
                                if await assistantProgressStreamStartState.markStartedIfNeeded() {
                                    await onEvent(.assistantProgressSegmentStarted(assistantProgressSegmentID))
                                }
                                await onEvent(.assistantProgressDelta(tail.visibleText))
                            case .finalAnswer:
                                await streamedFinalAnswerBuffer.append(tail.visibleText)
                                await onStreamedTranscriptUpdate?(
                                    await streamedFinalAnswerBuffer.value(),
                                    "final_answer"
                                )
                                if await finalAnswerStreamStartState.markStartedIfNeeded() {
                                    await onEvent(.finalAnswerStarted)
                                }
                                await onEvent(.finalAnswerDelta(tail.visibleText))
                            case .unknown:
                                break
                            }
                        }
                    }
                    completedStreamedAssistantMessageText = await streamedAssistantMessageBuffer.value()
                    completedStreamedFinalAnswerText = await streamedFinalAnswerBuffer.value()
                    completedModelRequestEvidence = modelRequestEvidence
                } catch {
                    if Task.isCancelled || Self.isCancellationLikeError(error) {
                        try await appendPendingToolResultItemsIfNeeded()
                        transcriptAppendItems.append(contentsOf: Self.streamedAssistantTranscriptItems(
                            assistantMessage: await streamedAssistantMessageBuffer.value(),
                            finalAnswer: await streamedFinalAnswerBuffer.value()
                        ))
                        return try await cancelledResult()
                    }

                    let streamedFinalAnswerText = await streamedFinalAnswerBuffer.value()
                    if !streamedFinalAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return await finish(streamedFinalAnswerText)
                    }

                    if modelStreamRetryCount < maximumTransientModelStreamRetries,
                       Self.isTransientModelStreamError(error) {
                        modelStreamRetryCount += 1
                        await onEvent(.modelStreamRetrying(statusText: Self.modelStreamRetryStatusText))
                        try await Task.sleep(nanoseconds: 350_000_000)
                        continue
                    }

                    if Self.isLikelyContextWindowExceededError(error) {
                        if try await runContextWindowExceededCompactionRetryIfNeeded() {
                            promptToolOutputTokenLimit = MSPAgentPromptTranscriptNormalizer.strictMaxPromptToolOutputTokens
                            continue
                        }
                        if contextWindowExceededProjectionRetryCount < 1 {
                            contextWindowExceededProjectionRetryCount += 1
                            promptToolOutputTokenLimit = MSPAgentPromptTranscriptNormalizer.strictMaxPromptToolOutputTokens
                            if let fullWindowUsage = fullWindowUsageRecord() {
                                latestContextUsage = fullWindowUsage
                                await onEvent(.contextUsageUpdated(fullWindowUsage))
                            }
                            continue
                        }
                    }

                    throw error
                }
            }

            guard let modelOutput = completedModelOutput else {
                return try await cancelledResult()
            }

            let planModeOutput = await planModeCompletedOutput(modelOutput)

            if !planModeOutput.nativeOutputItems.isEmpty {
                liveInput.append(contentsOf: MSPAgentPromptTranscriptNormalizer
                    .providerSafeItemsForPrompt(planModeOutput.nativeOutputItems))
                transcriptAppendItems.append(contentsOf: planModeOutput.nativeOutputItems)
                await onTranscriptAppend?(planModeOutput.nativeOutputItems)
            }
            if let responseID = modelOutput.responseID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !responseID.isEmpty {
                latestResponseID = responseID
            }
            await onEvent(.probe(Self.modelResponseCompletedProbeEvent(
                output: modelOutput,
                latestResponseID: latestResponseID,
                requestEvidence: completedModelRequestEvidence
            )))
            if let contextUsage = contextUsageRecord(usage: modelOutput.tokenUsage) {
                latestContextUsage = contextUsage
                await onEvent(.contextUsageUpdated(contextUsage))
            }

            let streamedAssistantMessageText = completedStreamedAssistantMessageText
            let streamedFinalAnswerText = completedStreamedFinalAnswerText
            let hasStreamedAssistantMessage = !streamedAssistantMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasStreamedFinalAnswer = !streamedFinalAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let visibleAssistantMessage = planModeOutput.assistantMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCalls = modelOutput.toolCalls
            let hasPendingInputForDecision = await hasPendingInput()
            let streamedAssistantOwnsCompleted: (String) -> Bool = { completedText in
                hasStreamedAssistantMessage
                    && MSPAgentVisibleStreamOwnership.streamedText(
                        streamedAssistantMessageText,
                        ownsCompletedText: completedText
                    )
            }

            if let proposedPlan = await planModeStreamState.proposalContent(),
               !proposedPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               toolCalls.isEmpty {
                let visibleText = [
                    planModeOutput.assistantMessage,
                    planModeOutput.finalAnswer
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return await finishPlanModeTurn(visibleText: visibleText)
            }

            if let finalAnswer = planModeOutput.finalAnswer,
               !finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if hasPendingInputForDecision {
                    if try await runMidTurnCompactionIfNeeded(
                        modelNeedsFollowUp: false,
                        hasPendingInput: true
                    ) {
                        continue
                    }
                    canDrainPendingInput = true
                    continue
                }
                if let assistantMessage = planModeOutput.assistantMessage,
                   let visibleAssistantMessage,
                   !visibleAssistantMessage.isEmpty {
                    lastAssistantMessage = assistantMessage
                    if !streamedAssistantOwnsCompleted(visibleAssistantMessage) {
                        await emitAssistantProgress(assistantMessage, segmentID: assistantProgressSegmentID)
                    }
                }
                consecutiveAssistantMessageCheckpointCount = 0
                forcedCheckpointContinuationCount = 0
                if hasStreamedFinalAnswer {
                    await onEvent(.probe(Self.finalAnswerProvenanceProbeEvent(
                        answer: streamedFinalAnswerText,
                        output: modelOutput,
                        latestResponseID: latestResponseID,
                        requestEvidence: completedModelRequestEvidence
                    )))
                    await onEvent(.finalAnswer(streamedFinalAnswerText))
                    return MSPAgentRunResult(
                        finalAnswer: streamedFinalAnswerText,
                        toolResults: allToolResults,
                        responseID: latestResponseID,
                        transcriptAppendItems: transcriptAppendItems,
                        contextUsage: latestContextUsage,
                        planModeProposalContent: await planModeStreamState.proposalContent()
                    )
                }
                return await finish(
                    finalAnswer,
                    provenance: modelOutput,
                    requestEvidence: completedModelRequestEvidence
                )
            }

            if let assistantMessage = planModeOutput.assistantMessage,
               let visibleAssistantMessage,
               !visibleAssistantMessage.isEmpty {
                lastAssistantMessage = assistantMessage
                if !streamedAssistantOwnsCompleted(visibleAssistantMessage) {
                    await emitAssistantProgress(assistantMessage, segmentID: assistantProgressSegmentID)
                }
            } else if hasStreamedAssistantMessage {
                lastAssistantMessage = streamedAssistantMessageText
            }

            guard !toolCalls.isEmpty else {
                if hasPendingInputForDecision {
                    if try await runMidTurnCompactionIfNeeded(
                        modelNeedsFollowUp: false,
                        hasPendingInput: true
                    ) {
                        continue
                    }
                    canDrainPendingInput = true
                    continue
                }
                if let checkpointText = visibleAssistantMessage,
                   !checkpointText.isEmpty {
                    consecutiveAssistantMessageCheckpointCount += 1
                    if consecutiveAssistantMessageCheckpointCount <= Self.maxConsecutiveAssistantMessageCheckpoints {
                        continue
                    }

                    if forcedCheckpointContinuationCount < 1 {
                        forcedCheckpointContinuationCount += 1
                        continue
                    }

                    return await finish("I produced an intermediate response but did not receive another tool call or final answer.")
                }

                if protocolRetryCount < 2 {
                    protocolRetryCount += 1
                    continue
                }

                if allToolResults.isEmpty,
                   !lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await onEvent(.finalAnswer(lastAssistantMessage))
                    return MSPAgentRunResult(
                        finalAnswer: lastAssistantMessage,
                        toolResults: allToolResults,
                        responseID: latestResponseID,
                        transcriptAppendItems: transcriptAppendItems,
                        contextUsage: latestContextUsage,
                        planModeProposalContent: await planModeStreamState.proposalContent()
                    )
                }
                return await finish("I did not receive a tool call or final answer to continue this turn.")
            }

            if isForcingFinalAnswer {
                return await finish("Tool calling has stopped for this turn. I will answer with the context already available.")
            }

            protocolRetryCount = 0
            consecutiveAssistantMessageCheckpointCount = 0
            forcedCheckpointContinuationCount = 0
            let toolBatchID = UUID()

            for call in toolCalls {
                if let remainingToolCalls, remainingToolCalls <= 0 {
                    isForcingFinalAnswer = true
                    let result = MSPAgentToolResult(
                        callID: call.id,
                        name: call.name,
                        outputKind: call.outputKind,
                        ok: false,
                        content: .string(Self.toolBudgetExhaustedMessage),
                        errorMessage: Self.toolBudgetExhaustedMessage
                    )
                    await onEvent(.toolStarted(call, statusText: "Tool-call budget exhausted; wrapping up.", batchID: toolBatchID))
                    allToolResults.append(result)
                    pendingToolResults.append(result)
                    await onEvent(.toolCompleted(result, batchID: toolBatchID))
                    continue
                }

                await onEvent(.toolStarted(call, statusText: Self.statusText(for: call), batchID: toolBatchID))
                await onEvent(.probe(MSPAgentProbeEvent(
                    name: "probe_agent_tool_loop_execute_tool_before",
                    fields: [
                        "call_id": call.id,
                        "name": call.name.rawValue,
                        "batch_id": toolBatchID.uuidString
                    ]
                )))
                let result = await executeTool(call)
                await onEvent(.probe(MSPAgentProbeEvent(
                    name: "probe_agent_tool_loop_execute_tool_after",
                    fields: [
                        "call_id": call.id,
                        "name": call.name.rawValue,
                        "batch_id": toolBatchID.uuidString,
                        "ok": "\(result.ok)"
                    ]
                )))
                allToolResults.append(result)
                pendingToolResults.append(result)
                if let remaining = remainingToolCalls {
                    remainingToolCalls = max(0, remaining - 1)
                }
                await onEvent(.probe(MSPAgentProbeEvent(
                    name: "probe_agent_tool_loop_tool_completed_event_before",
                    fields: [
                        "call_id": call.id,
                        "name": call.name.rawValue,
                        "batch_id": toolBatchID.uuidString,
                        "ok": "\(result.ok)"
                    ]
                )))
                await onEvent(.toolCompleted(result, batchID: toolBatchID))
                await onEvent(.probe(MSPAgentProbeEvent(
                    name: "probe_agent_tool_loop_tool_completed_event_after",
                    fields: [
                        "call_id": call.id,
                        "name": call.name.rawValue,
                        "batch_id": toolBatchID.uuidString,
                        "ok": "\(result.ok)"
                    ]
                )))
            }

            if midTurnCompaction != nil {
                try await appendPendingToolResultItemsIfNeeded()
                if try await runMidTurnCompactionIfNeeded(
                    modelNeedsFollowUp: true,
                    hasPendingInput: await hasPendingInput()
                ) {
                    continue
                }
            }
            canDrainPendingInput = true
        }

        return try await cancelledResult()
    }

}
