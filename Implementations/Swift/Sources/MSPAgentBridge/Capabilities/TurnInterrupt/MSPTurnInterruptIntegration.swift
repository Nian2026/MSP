import Foundation

extension MSPAgentConversation: MSPTurnInterruptProtocol {
    public func interruptTurn(
        _ request: MSPTurnInterruptRequest
    ) async throws -> MSPTurnInterruptResponse {
        let begin = try turnInterruptController.beginInterrupt(
            request: request,
            conversationThreadID: threadID
        )
        return try await terminalResponseTask(for: begin).value
    }

    public func interruptActiveTurn()
        async throws -> MSPTurnInterruptHandle? {
        guard let active = turnInterruptController.activeSnapshot() else {
            return nil
        }
        let requestedAt = Date()
        let begin = try turnInterruptController.beginInterrupt(
            request: MSPTurnInterruptRequest(
                threadID: active.threadID,
                turnID: active.turnID
            ),
            conversationThreadID: threadID
        )
        return MSPTurnInterruptHandle(
            target: active,
            requestedAt: requestedAt,
            terminalResponseTask: terminalResponseTask(for: begin)
        )
    }

    private func terminalResponseTask(
        for begin: MSPTurnInterruptBeginResult
    ) -> Task<MSPTurnInterruptResponse, Error> {
        switch begin {
        case .startupAck(let response):
            return Task {
                response
            }
        case .waitForPending(let turnID):
            return Task {
                try await self.waitForTurnInterruptCompletion(turnID: turnID)
            }
        case .perform(let commit):
            beginTurnSteerInterrupt(id: commit.turn.id)
            return Task {
                await completeTurnInterruptAfterAbortBoundary(
                    commit,
                    reason: .interrupted
                )
                return try await self.waitForTurnInterruptCompletion(
                    turnID: commit.turnID
                )
            }
        }
    }

    private func waitForTurnInterruptCompletion(
        turnID: String
    ) async throws -> MSPTurnInterruptResponse {
        try await turnInterruptController
            .waitForPendingInterrupt(turnID: turnID)
    }

    public func currentTurnInterruptTarget()
        async -> MSPTurnInterruptActiveTurn? {
        turnInterruptController.activeSnapshot()
    }

    public func turnInterruptCapabilityDeclaration()
        async -> MSPTurnInterruptCapabilityDeclaration {
        turnInterruptController.declaration
    }

    @discardableResult
    func startTrackedTurn(
        id turnID: UUID,
        kind: MSPTurnInterruptTurnKind,
        transcriptRecorder: MSPAgentTurnTranscriptRecorder?,
        fallbackTranscriptItems: [MSPAgentJSONValue],
        onEvent: @escaping EventHandler
    ) async -> MSPTurnInterruptTurnStartedEvent {
        let event = turnInterruptController.startTurn(
            id: turnID,
            threadID: threadID,
            kind: kind,
            transcriptRecorder: transcriptRecorder,
            fallbackTranscriptItems: fallbackTranscriptItems,
            eventHandler: onEvent
        )
        startTrackedSteerTurn(
            id: turnID,
            kind: MSPTurnSteerTurnKind(interruptKind: kind),
            startedAt: event.startedAt,
            onEvent: onEvent
        )
        startTrackedGoalTurn(
            id: turnID,
            kind: MSPGoalTurnKind(interruptKind: kind),
            startedAt: event.startedAt
        )
        await onEvent(.turnStarted(event))
        return event
    }

    func completeCancelledTurn(
        id turnID: UUID,
        result: MSPAgentRunResult,
        reason: MSPTurnInterruptAbortReason
    ) async -> MSPAgentRunResult {
        guard let commit = turnInterruptController.completeCancellation(
            id: turnID,
            reason: reason
        ) else {
            return result
        }
        beginTurnSteerInterrupt(id: turnID)
        let completion = await completeTurnInterruptAndReturnItems(
            commit,
            reason: reason
        )
        var cancelled = result
        cancelled.wasCancelled = true
        cancelled.transcriptAppendItems = completion.items
        return cancelled
    }

    func completeTurnInterrupt(
        _ commit: MSPTurnInterruptCommit,
        reason: MSPTurnInterruptAbortReason
    ) async {
        _ = await completeTurnInterruptAndReturnItems(
            commit,
            reason: reason
        )
    }

    func completeTurnInterruptAfterAbortBoundary(
        _ commit: MSPTurnInterruptCommit,
        reason: MSPTurnInterruptAbortReason
    ) async {
        let timeout = turnInterruptController.gracefulAbortTimeoutNanoseconds
        if timeout > 0 {
            try? await Task.sleep(nanoseconds: timeout)
        }
        await completeTurnInterrupt(commit, reason: reason)
    }

    private struct TurnInterruptCompletionResult {
        var response: MSPTurnInterruptResponse?
        var items: [MSPAgentJSONValue]
    }

    private func completeTurnInterruptAndReturnItems(
        _ commit: MSPTurnInterruptCommit,
        reason: MSPTurnInterruptAbortReason
    ) async -> TurnInterruptCompletionResult {
        guard turnInterruptController.beginInterruptCompletion(commit) else {
            return TurnInterruptCompletionResult(response: nil, items: [])
        }
        let items = await interruptedTranscriptItems(for: commit)
        if !items.isEmpty {
            appendTranscriptItems(items)
        }
        await finishGoalTurn(id: commit.turn.id, status: .interrupted)
        let response = turnInterruptController.completeInterrupt(
            commit,
            reason: reason
        )
        if let event = response.terminalEvent {
            await commit.turn.eventHandler(.turnAborted(event))
        }
        _ = await finishTurnSteer(id: commit.turn.id, status: .interrupted)
        return TurnInterruptCompletionResult(response: response, items: items)
    }

    func interruptedTranscriptItems(
        for commit: MSPTurnInterruptCommit
    ) async -> [MSPAgentJSONValue] {
        guard commit.recordsInterruptedTranscript else {
            return []
        }
        let pendingSteerItems = await interruptedTurnSteerTranscriptItems(
            id: commit.turn.id
        )
        if let recorder = commit.turn.transcriptRecorder {
            return await recorder.interruptedTranscriptAppendItems(
                additionalItemsBeforeMarker: pendingSteerItems
            )
        }
        return commit.turn.fallbackTranscriptItems + pendingSteerItems + [
            MSPTurnInterruptChatMapping.interruptedMarkerInputItem()
        ]
    }

    func shouldEmitActiveTurnRuntimeEvent(id turnID: UUID) -> Bool {
        turnInterruptController.shouldEmitRuntimeEvent(id: turnID)
    }
}

private extension MSPTurnSteerTurnKind {
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
