import Foundation

extension MSPAgentConversation: MSPPlanModeProtocol {
    public func enterPlanMode(
        _ request: MSPPlanModeEnterRequest
    ) async throws -> MSPPlanModeStateResponse {
        try planModeController.enterPlanMode(
            request,
            conversationThreadID: threadID
        )
    }

    public func submitPlanningTurn(
        _ request: MSPPlanModePlanningTurnRequest,
        onRequestBuilt: RequestBuiltHandler? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> MSPPlanModePlanningTurnResponse {
        try Task.checkCancellation()
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw MSPPlanModeError.emptyPrompt
        }
        _ = try planModeController.enterPlanMode(
            MSPPlanModeEnterRequest(threadID: request.threadID, source: request.source),
            conversationThreadID: threadID
        )

        await waitForTurnSlot()
        try Task.checkCancellation()

        let turnID = UUID()
        var currentUserItemsForCancellation = try currentUserTranscriptItems(
            userMessage: request.prompt
        )
        let earlyRecorder = MSPAgentTurnTranscriptRecorder(
            initialItems: currentUserItemsForCancellation
        )
        let started = await startTrackedTurn(
            id: turnID,
            kind: .planning,
            transcriptRecorder: earlyRecorder,
            fallbackTranscriptItems: currentUserItemsForCancellation,
            onEvent: onEvent
        )
        try planModeController.startPlanningTurn(
            id: turnID,
            threadID: threadID,
            startedAt: started.startedAt,
            eventHandler: onEvent
        )

        let planRuntime = MSPPlanModeRuntimeSession(
            threadID: threadID,
            planningTurnID: turnID.uuidString
        )

        do {
            var result = try await runActiveTurn(
                id: turnID,
                userMessage: request.prompt,
                additionalDeveloperContextBlocks: [
                    MSPPlanModeChatMapping.developerInstructions
                ],
                dynamicDeveloperContextBlocks: [],
                additionalEnvironmentNotes: [],
                onRequestBuilt: onRequestBuilt,
                onEvent: onEvent,
                currentUserItemsForCancellation: &currentUserItemsForCancellation,
                goalInitialItemsOverride: [],
                planModeRuntime: planRuntime
            )
            if result.wasCancelled {
                planModeController.completePlanningTurn(id: turnID)
                let cancelledResult = await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
                return MSPPlanModePlanningTurnResponse(
                    threadID: threadID,
                    planningTurnID: turnID.uuidString,
                    snapshot: try planModeController.currentState(
                        threadID: request.threadID,
                        conversationThreadID: threadID
                    ),
                    proposedPlan: nil,
                    runResult: cancelledResult,
                    runtimeEvents: []
                )
            }

            var runtimeEvents: [MSPAgentEvent] = []
            var proposal: MSPPlanModeProposalSnapshot?
            if let proposedContent = result.planModeProposalContent,
               !proposedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let outcome = try planModeController.recordProposedPlan(
                    content: proposedContent,
                    planningTurnID: turnID,
                    source: .model
                )
                proposal = outcome.proposal
                runtimeEvents = outcome.runtimeEvents
                result.transcriptAppendItems.append(
                    MSPPlanModeChatMapping.proposedPlanTranscriptItem(
                        for: outcome.proposal
                    )
                )
                for event in runtimeEvents {
                    await onEvent(event)
                }
            }

            planModeController.completePlanningTurn(id: turnID)
            let shouldAcceptTurnResult = shouldAppendResultTranscript(for: turnID)
            if shouldAcceptTurnResult,
               !result.transcriptAppendItems.isEmpty {
                appendTranscriptItems(result.transcriptAppendItems)
            }
            if shouldAcceptTurnResult {
                latestContextUsage = result.contextUsage
            }
            await finishActiveTurn(id: turnID, status: .completed)
            return MSPPlanModePlanningTurnResponse(
                threadID: threadID,
                planningTurnID: turnID.uuidString,
                snapshot: try planModeController.currentState(
                    threadID: request.threadID,
                    conversationThreadID: threadID
                ),
                proposedPlan: proposal,
                runResult: result,
                runtimeEvents: runtimeEvents
            )
        } catch {
            planModeController.completePlanningTurn(id: turnID)
            if Self.isCancellationLikeError(error) {
                let result = MSPAgentRunResult(
                    finalAnswer: "",
                    toolResults: [],
                    transcriptAppendItems: currentUserItemsForCancellation,
                    wasCancelled: true
                )
                let cancelledResult = await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
                return MSPPlanModePlanningTurnResponse(
                    threadID: threadID,
                    planningTurnID: turnID.uuidString,
                    snapshot: try planModeController.currentState(
                        threadID: request.threadID,
                        conversationThreadID: threadID
                    ),
                    proposedPlan: nil,
                    runResult: cancelledResult,
                    runtimeEvents: []
                )
            }
            await finishActiveTurn(id: turnID, status: .failed)
            throw error
        }
    }

    public func currentPlanModeState(
        threadID: String
    ) async throws -> MSPPlanModeSnapshot {
        try planModeController.currentState(
            threadID: threadID,
            conversationThreadID: self.threadID
        )
    }

    public func approveProposedPlan(
        _ request: MSPPlanModeDecisionRequest
    ) async throws -> MSPPlanModeDecisionResponse {
        try planModeController.approve(
            request,
            conversationThreadID: threadID
        )
    }

    public func rejectProposedPlan(
        _ request: MSPPlanModeDecisionRequest
    ) async throws -> MSPPlanModeDecisionResponse {
        try planModeController.reject(
            request,
            conversationThreadID: threadID
        )
    }

    public func modifyProposedPlan(
        _ request: MSPPlanModeModifyRequest
    ) async throws -> MSPPlanModeModifyResponse {
        let response = try planModeController.modify(
            request,
            conversationThreadID: threadID
        )
        appendTranscriptItems([
            MSPPlanModeChatMapping.proposedPlanTranscriptItem(
                for: response.proposal
            )
        ])
        return response
    }

    public func planModeCapabilityDeclaration()
        async -> MSPPlanModeCapabilityDeclaration {
        planModeController.declaration
    }
}
