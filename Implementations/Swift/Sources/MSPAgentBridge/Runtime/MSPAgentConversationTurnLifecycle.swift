import Foundation

extension MSPAgentConversation {
    func waitForTurnSlot() async {
        await turnInterruptController.waitForTurnSlot()
    }

    func shouldSteerSendIntoActiveTurn(
        additionalDeveloperContextBlocks: [String],
        dynamicDeveloperContextBlocks: [MSPAgentDynamicDeveloperContextBlock],
        additionalEnvironmentNotes: [String],
        onRequestBuilt: RequestBuiltHandler?
    ) -> Bool {
        configuration.compactionPolicy.enabled
            && additionalDeveloperContextBlocks.isEmpty
            && dynamicDeveloperContextBlocks.isEmpty
            && additionalEnvironmentNotes.isEmpty
            && onRequestBuilt == nil
            && turnInterruptController.canAcceptPendingUserInput()
            && canSteerActiveUserTurn()
    }

    func waitForActiveUserTurnResult() async throws -> MSPAgentRunResult {
        try await withCheckedThrowingContinuation { continuation in
            activeUserTurnResultWaiters.append(continuation)
        }
    }

    func resolveActiveUserTurnResultWaiters(returning result: MSPAgentRunResult) {
        let waiters = activeUserTurnResultWaiters
        activeUserTurnResultWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func resolveActiveUserTurnResultWaiters(throwing error: Error) {
        let waiters = activeUserTurnResultWaiters
        activeUserTurnResultWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    @discardableResult
    func installActiveTurnRecorder(
        _ recorder: MSPAgentTurnTranscriptRecorder,
        id turnID: UUID
    ) -> Bool {
        turnInterruptController.installRecorder(recorder, id: turnID)
    }

    @discardableResult
    func installActiveTurnTask(
        _ task: Task<MSPAgentRunResult, Error>,
        id turnID: UUID
    ) -> Bool {
        turnInterruptController.installTask(task, id: turnID)
    }

    func shouldAppendResultTranscript(for turnID: UUID) -> Bool {
        turnInterruptController.shouldAcceptResult(id: turnID)
    }

    func finishActiveTurn(
        id turnID: UUID,
        status: MSPTurnInterruptTurnStatus = .completed
    ) async {
        await finishGoalTurn(
            id: turnID,
            status: MSPGoalTurnStatus(interruptStatus: status)
        )
        turnInterruptController.finishTurn(id: turnID, status: status)
        let steerItems = await finishTurnSteer(
            id: turnID,
            status: MSPTurnSteerTurnStatus(interruptStatus: status)
        )
        if !steerItems.isEmpty {
            appendTranscriptItems(steerItems)
        }
    }

    func replaceActiveTurnTranscriptAppendItems(
        _ items: [MSPAgentJSONValue],
        id turnID: UUID
    ) async {
        await turnInterruptController.replaceTranscriptAppendItems(items, id: turnID)
    }

    func appendActiveTurnTranscriptSnapshotIfAccepted(id turnID: UUID) async {
        guard shouldAppendResultTranscript(for: turnID),
              let items = await turnInterruptController.transcriptAppendItemsSnapshot(id: turnID) else {
            return
        }
        appendTranscriptItems(items)
    }

    static func isCancellationLikeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        return nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }
}

private extension MSPTurnSteerTurnStatus {
    init(interruptStatus: MSPTurnInterruptTurnStatus) {
        switch interruptStatus {
        case .running:
            self = .running
        case .interrupting:
            self = .interrupting
        case .completed:
            self = .completed
        case .interrupted:
            self = .interrupted
        case .failed:
            self = .failed
        }
    }
}

private extension MSPGoalTurnStatus {
    init(interruptStatus: MSPTurnInterruptTurnStatus) {
        switch interruptStatus {
        case .running:
            self = .running
        case .interrupting, .interrupted:
            self = .interrupted
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        }
    }
}
