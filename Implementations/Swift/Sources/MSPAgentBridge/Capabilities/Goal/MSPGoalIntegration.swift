import Foundation

extension MSPAgentConversation: MSPGoalProtocol {
    public func currentGoal(threadID: String) async throws -> MSPGoalSnapshot? {
        try goalController.currentGoal(
            threadID: threadID,
            conversationThreadID: self.threadID
        )
    }

    public func createGoal(
        _ request: MSPGoalCreateRequest
    ) async throws -> MSPGoalMutationResponse {
        let outcome = try goalController.createGoal(
            request,
            conversationThreadID: threadID
        )
        await emitGoalEvents(outcome.events)
        return outcome.response
    }

    public func setGoal(
        _ request: MSPGoalSetRequest
    ) async throws -> MSPGoalMutationResponse {
        let outcome = try goalController.setGoal(
            request,
            conversationThreadID: threadID
        )
        await emitGoalEvents(outcome.events)
        return outcome.response
    }

    public func updateGoal(
        _ request: MSPGoalUpdateRequest
    ) async throws -> MSPGoalMutationResponse {
        let outcome = try goalController.updateGoal(
            request,
            conversationThreadID: threadID
        )
        await emitGoalEvents(outcome.events)
        return outcome.response
    }

    public func clearGoal(threadID: String) async throws -> MSPGoalClearResponse {
        let (response, events) = try goalController.clearGoal(
            threadID: threadID,
            conversationThreadID: self.threadID
        )
        await emitGoalEvents(events)
        return response
    }

    public func continueActiveGoalIfIdle(
        onRequestBuilt: RequestBuiltHandler? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> MSPAgentRunResult? {
        try Task.checkCancellation()
        await waitForTurnSlot()
        try Task.checkCancellation()
        let continuationItems = try goalController.idleContinuationInput(
            threadID: threadID,
            conversationThreadID: threadID
        )
        guard !continuationItems.isEmpty else {
            return nil
        }

        let turnID = UUID()
        await startTrackedTurn(
            id: turnID,
            kind: .user,
            transcriptRecorder: MSPAgentTurnTranscriptRecorder(initialItems: []),
            fallbackTranscriptItems: [],
            onEvent: onEvent
        )

        do {
            let result = try await runActiveTurn(
                id: turnID,
                userMessage: "",
                additionalDeveloperContextBlocks: [],
                dynamicDeveloperContextBlocks: [],
                additionalEnvironmentNotes: [],
                onRequestBuilt: onRequestBuilt,
                onEvent: onEvent,
                currentUserItemsOverride: [],
                goalInitialItemsOverride: continuationItems
            )
            if result.wasCancelled {
                let cancelledResult = await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
                resolveActiveUserTurnResultWaiters(returning: cancelledResult)
                return cancelledResult
            }
            let shouldAcceptTurnResult = shouldAppendResultTranscript(for: turnID)
            if shouldAcceptTurnResult,
               !result.transcriptAppendItems.isEmpty {
                appendTranscriptItems(result.transcriptAppendItems)
            }
            if shouldAcceptTurnResult {
                recordLatestNormalTurnContextUsage(result.contextUsage)
            }
            await finishActiveTurn(id: turnID, status: .completed)
            resolveActiveUserTurnResultWaiters(returning: result)
            return result
        } catch {
            if Self.isCancellationLikeError(error) {
                let result = MSPAgentRunResult(
                    finalAnswer: "",
                    toolResults: [],
                    transcriptAppendItems: [],
                    wasCancelled: true
                )
                let cancelledResult = await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
                resolveActiveUserTurnResultWaiters(returning: cancelledResult)
                return cancelledResult
            }
            await finishActiveTurn(id: turnID, status: .failed)
            resolveActiveUserTurnResultWaiters(throwing: error)
            throw error
        }
    }

    public func goalCapabilityDeclaration()
        async -> MSPGoalCapabilityDeclaration {
        goalController.declaration
    }

    func startTrackedGoalTurn(
        id turnID: UUID,
        kind: MSPGoalTurnKind,
        startedAt: Date
    ) {
        goalController.startTurn(
            id: turnID,
            threadID: threadID,
            kind: kind,
            startedAt: startedAt
        )
    }

    func activeGoalPendingInput(
        _ request: MSPAgentToolLoop.PendingInputRequest,
        id turnID: UUID
    ) -> [MSPAgentJSONValue] {
        goalController.pendingInput(request, turnID: turnID)
    }

    func activeGoalInitialInput(id turnID: UUID) -> [MSPAgentJSONValue] {
        goalController.initialInput(turnID: turnID)
    }

    func recordGoalTokenUsage(
        _ usage: MSPAgentContextUsageRecord,
        id turnID: UUID
    ) {
        goalController.recordTokenUsage(usage, turnID: turnID)
    }

    func executeGoalToolIfNeeded(
        _ call: MSPAgentToolCall,
        id turnID: UUID
    ) async -> MSPAgentToolResult? {
        guard let outcome = goalController.executeGoalTool(call, turnID: turnID) else {
            return nil
        }
        await emitGoalEvents(outcome.events)
        return outcome.result
    }

    func recordGoalToolFinish(
        call: MSPAgentToolCall,
        result: MSPAgentToolResult,
        id turnID: UUID
    ) async {
        let outcome = goalController.toolFinished(
            call,
            result: result,
            turnID: turnID
        )
        await emitGoalEvents(outcome.events)
    }

    func finishGoalTurn(
        id turnID: UUID,
        status: MSPGoalTurnStatus
    ) async {
        let outcome = goalController.finishTurn(id: turnID, status: status)
        await emitGoalEvents(outcome.events)
    }

    func restoreGoalAfterResume() async {
        let outcome = goalController.restoreAfterResume()
        await emitGoalEvents(outcome.events)
    }

    private func emitGoalEvents(_ events: [MSPAgentEvent]) async {
        guard let active = currentTurnInterruptTargetSync() else {
            return
        }
        for event in events {
            await active.eventHandler(event)
        }
    }
}

private struct MSPGoalEventTarget {
    var eventHandler: MSPAgentConversation.EventHandler
}

extension MSPGoalTurnKind {
    init(interruptKind: MSPTurnInterruptTurnKind) {
        switch interruptKind {
        case .user:
            self = .user
        case .planning:
            self = .planning
        case .maintenance:
            self = .maintenance
        }
    }
}

private extension MSPAgentConversation {
    func currentTurnInterruptTargetSync() -> MSPGoalEventTarget? {
        guard let active = turnInterruptController.runtimeEventTarget() else {
            return nil
        }
        return MSPGoalEventTarget(eventHandler: active)
    }
}
