import Foundation

extension MSPAgentConversation {
    func currentUserTranscriptItems(
        userMessage: String
    ) throws -> [MSPAgentJSONValue] {
        let body = requestBuilder.build(
            context: configuration.requestContext(prompt: userMessage)
        )
        let envelope = try requestBuilder.envelope(from: body)
        let prefixCount = max(0, envelope.input.count - 1)
        return Array(envelope.input.dropFirst(prefixCount))
    }

    func runActiveTurn(
        id turnID: UUID,
        userMessage: String,
        additionalDeveloperContextBlocks: [String],
        dynamicDeveloperContextBlocks: [MSPAgentDynamicDeveloperContextBlock],
        additionalEnvironmentNotes: [String],
        onRequestBuilt: RequestBuiltHandler?,
        onTranscriptSnapshotUpdated: (@Sendable ([MSPAgentJSONValue]) async -> Void)? = nil,
        onEvent: @escaping EventHandler,
        currentUserItemsForCancellation: inout [MSPAgentJSONValue],
        currentUserItemsOverride: [MSPAgentJSONValue]? = nil,
        goalInitialItemsOverride: [MSPAgentJSONValue]? = nil,
        planModeRuntime: MSPPlanModeRuntimeSession? = nil
    ) async throws -> MSPAgentRunResult {
        await onEvent(.modelRequestPreparing(statusText: "preparing_request"))
        var requestContext = configuration.requestContext(
            prompt: userMessage,
            planProgressToolsVisible: planModeRuntime == nil
        )
        requestContext.developerContextBlocks.append(contentsOf: additionalDeveloperContextBlocks)
        let dynamicDeveloperContextStartIndex = requestContext.developerContextBlocks.count
        let dynamicDeveloperContextTexts = await MSPAgentDynamicDeveloperContextBlock.resolveAll(
            dynamicDeveloperContextBlocks
        )
        requestContext.developerContextBlocks.append(contentsOf: dynamicDeveloperContextTexts)
        requestContext.environmentNotes.append(contentsOf: additionalEnvironmentNotes)
        let body = requestBuilder.build(context: requestContext)
        await onRequestBuilt?(body)
        let envelope = try requestBuilder.envelope(from: body)
        let prefixItems = Array(envelope.input.prefix(max(0, envelope.input.count - 1)))
        let builtCurrentUserItems = currentUserItemsOverride == nil
            ? Array(envelope.input.dropFirst(prefixItems.count))
            : []
        let currentUserItems = currentUserItemsOverride ?? builtCurrentUserItems
        currentUserItemsForCancellation = currentUserItems
        var promptProjection = promptTranscriptProjection()
        var promptTranscriptItems = promptProjection.items
        let goalInitialItems = goalInitialItemsOverride ?? activeGoalInitialInput(id: turnID)
        let projectedPreTurnTokenCount = Self.approximateTokenCount(in: prefixItems)
            + promptProjection.estimatedTokenCount
            + Self.approximateTokenCount(in: goalInitialItems)
            + Self.approximateTokenCount(in: currentUserItems)
        let preTurnOutcome = try await runPreTurnAutoCompactIfNeeded(
            id: turnID,
            prefixItems: prefixItems,
            promptTranscriptItems: promptTranscriptItems,
            projectedInputTokenCount: projectedPreTurnTokenCount,
            envelope: envelope,
            onEvent: onEvent
        )
        switch preTurnOutcome {
        case .notRun:
            break
        case .compacted:
            promptProjection = promptTranscriptProjection()
            promptTranscriptItems = promptProjection.items
        case .aborted(let result):
            return result
        }
        let recorder = MSPAgentTurnTranscriptRecorder(
            initialItems: currentUserItems,
            onSnapshotUpdated: onTranscriptSnapshotUpdated
        )
        let shouldCancelBeforeStart = installActiveTurnRecorder(recorder, id: turnID)
        await recorder.emitSnapshotUpdated()
        let fullInput = prefixItems + promptTranscriptItems + goalInitialItems + currentUserItems
        if case .compacted = preTurnOutcome {
            try assertProjectedInputFitsContextWindow(fullInput)
        }
        let fullEnvelope = envelope.replacingInput(fullInput)
        let loop = MSPAgentToolLoop(
            modelClient: modelClient,
            toolCallLimit: toolCallLimit,
            modelID: configuration.model,
            modelDisplayName: configuration.model
        )
        let scopedOnEvent: EventHandler = { event in
            guard await self.shouldEmitActiveTurnRuntimeEvent(id: turnID) else {
                return
            }
            if case let .contextUsageUpdated(usage) = event {
                await self.recordGoalTokenUsage(usage, id: turnID)
            }
            await onEvent(event)
        }
        let midTurnCompactionHandler: MSPAgentToolLoop.MidTurnCompactionHandler?
        if configuration.compactionPolicy.enabled {
            midTurnCompactionHandler = { context in
                try await self.runMidTurnAutoCompactIfNeeded(
                    id: turnID,
                    prefixItemCount: prefixItems.count,
                    envelope: envelope,
                    context: context,
                    onEvent: onEvent
                )
            }
        } else {
            midTurnCompactionHandler = nil
        }
        let planProgressCapability = configuration.planProgressCapability
        let task = Task {
            try await loop.run(
                request: fullEnvelope,
                dynamicDeveloperContext: MSPAgentToolLoop.DynamicDeveloperContext(
                    blocks: dynamicDeveloperContextBlocks,
                    contentStartIndex: dynamicDeveloperContextStartIndex
                ),
                initialTranscriptAppendItems: currentUserItems,
                onTranscriptAppend: { items in
                    await recorder.append(items)
                },
                onStreamedTranscriptUpdate: { text, phase in
                    guard await self.shouldEmitActiveTurnRuntimeEvent(id: turnID) else {
                        return
                    }
                    await recorder.updateStreamedMessage(text: text, phase: phase)
                },
                pendingInputProvider: { request in
                    let steerItems = await self.activeTurnSteerPendingInput(
                        request,
                        id: turnID
                    )
                    let goalItems = await self.activeGoalPendingInput(
                        request,
                        id: turnID
                    )
                    return steerItems + goalItems
                },
                midTurnCompaction: midTurnCompactionHandler,
                planModeRuntime: planModeRuntime,
                onEvent: scopedOnEvent,
                executeTool: { [execCommandBridge, applyPatchExecutor] call in
                    if let goalResult = await self.executeGoalToolIfNeeded(
                        call,
                        id: turnID
                    ) {
                        return goalResult
                    }
                    if let planProgressOutcome = MSPPlanProgressRuntime.executeTool(
                        call,
                        capability: planProgressCapability,
                        threadID: self.threadID,
                        turnID: turnID,
                        planModeActive: planModeRuntime != nil
                    ) {
                        if let event = planProgressOutcome.event {
                            await scopedOnEvent(.planProgressUpdated(event))
                        }
                        return planProgressOutcome.result
                    }
                    let result = await MSPAgentRuntimeToolExecutor.execute(
                        call,
                        bridge: execCommandBridge,
                        applyPatchExecutor: applyPatchExecutor,
                        onOutput: { event in
                            guard await self.shouldEmitActiveTurnRuntimeEvent(id: turnID) else {
                                return
                            }
                            await scopedOnEvent(.probe(MSPAgentProbeEvent(
                                name: "probe_agent_runtime_tool_output_event_before",
                                fields: [
                                    "call_id": call.id,
                                    "name": call.name.rawValue,
                                    "stream": event.stream.rawValue,
                                    "text_length": "\(event.text.count)"
                                ]
                            )))
                            await scopedOnEvent(.toolOutputDelta(
                                callID: call.id,
                                name: call.name,
                                stream: event.stream,
                                text: event.text
                            ))
                            await scopedOnEvent(.probe(MSPAgentProbeEvent(
                                name: "probe_agent_runtime_tool_output_event_after",
                                fields: [
                                    "call_id": call.id,
                                    "name": call.name.rawValue,
                                    "stream": event.stream.rawValue,
                                    "text_length": "\(event.text.count)"
                                ]
                            )))
                        },
                        probe: { event in
                            await scopedOnEvent(.probe(event))
                        }
                    )
                    await self.recordGoalToolFinish(
                        call: call,
                        result: result,
                        id: turnID
                    )
                    return result
                }
            )
        }
        if shouldCancelBeforeStart || installActiveTurnTask(task, id: turnID) {
            task.cancel()
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                await recorder.flushPendingStreamedSnapshot()
                return result
            } catch {
                await recorder.flushPendingStreamedSnapshot()
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }
}
