import Foundation

final class MSPTurnInterruptController {
    private let capability: MSPTurnInterruptCapability
    private var activeTurn: MSPTurnInterruptRuntimeTurn?
    private var waitingTurnContinuations: [CheckedContinuation<Void, Never>] = []
    private let completionRegistry = MSPTurnInterruptCompletionRegistry()

    init(capability: MSPTurnInterruptCapability) {
        self.capability = capability
    }

    var declaration: MSPTurnInterruptCapabilityDeclaration {
        capability.declaration
    }

    var gracefulAbortTimeoutNanoseconds: UInt64 {
        capability.gracefulAbortTimeoutNanoseconds
    }

    func waitForTurnSlot() async {
        while activeTurn != nil {
            await withCheckedContinuation { continuation in
                waitingTurnContinuations.append(continuation)
            }
        }
    }

    func startTurn(
        id: UUID,
        threadID: String,
        kind: MSPTurnInterruptTurnKind,
        transcriptRecorder: MSPAgentTurnTranscriptRecorder?,
        fallbackTranscriptItems: [MSPAgentJSONValue],
        eventHandler: @escaping MSPAgentConversation.EventHandler
    ) -> MSPTurnInterruptTurnStartedEvent {
        let startedAt = Date()
        activeTurn = MSPTurnInterruptRuntimeTurn(
            id: id,
            threadID: threadID,
            kind: kind,
            status: .running,
            task: nil,
            transcriptRecorder: transcriptRecorder,
            fallbackTranscriptItems: fallbackTranscriptItems,
            eventHandler: eventHandler,
            startedAt: startedAt
        )
        return MSPTurnInterruptTurnStartedEvent(
            threadID: threadID,
            turnID: id.uuidString,
            startedAt: startedAt
        )
    }

    func activeSnapshot() -> MSPTurnInterruptActiveTurn? {
        activeTurn?.activeSnapshot
    }

    func canAcceptPendingUserInput() -> Bool {
        guard let activeTurn else {
            return false
        }
        return activeTurn.kind == .user && activeTurn.status == .running
    }

    func installRecorder(
        _ recorder: MSPAgentTurnTranscriptRecorder,
        id turnID: UUID
    ) -> Bool {
        guard var turn = activeTurn, turn.id == turnID else {
            return true
        }
        let shouldInterrupt = turn.status == .interrupting
        turn.transcriptRecorder = recorder
        activeTurn = turn
        return shouldInterrupt
    }

    func installTask(
        _ task: Task<MSPAgentRunResult, Error>,
        id turnID: UUID
    ) -> Bool {
        guard var turn = activeTurn, turn.id == turnID else {
            task.cancel()
            return true
        }
        let shouldInterrupt = turn.status == .interrupting
        turn.task = task
        activeTurn = turn
        return shouldInterrupt
    }

    func shouldAcceptResult(id turnID: UUID) -> Bool {
        guard let turn = activeTurn, turn.id == turnID else {
            return false
        }
        return turn.status == .running
    }

    func shouldEmitRuntimeEvent(id turnID: UUID) -> Bool {
        shouldAcceptResult(id: turnID)
    }

    func runtimeEventTarget() -> MSPAgentConversation.EventHandler? {
        activeTurn?.eventHandler
    }

    func replaceTranscriptAppendItems(
        _ items: [MSPAgentJSONValue],
        id turnID: UUID
    ) async {
        guard let turn = activeTurn,
              turn.id == turnID,
              let recorder = turn.transcriptRecorder else {
            return
        }
        await recorder.replaceTranscriptAppendItems(items)
    }

    func transcriptAppendItemsSnapshot(id turnID: UUID) async -> [MSPAgentJSONValue]? {
        guard let turn = activeTurn,
              turn.id == turnID,
              turn.status == .running else {
            return nil
        }
        if let recorder = turn.transcriptRecorder {
            return await recorder.transcriptAppendItemsSnapshot()
        }
        return turn.fallbackTranscriptItems
    }

    func finishTurn(id turnID: UUID, status: MSPTurnInterruptTurnStatus) {
        guard let turn = activeTurn,
              turn.id == turnID,
              turn.status == .running else {
            return
        }
        activeTurn = nil
        completionRegistry.rememberTerminalTurn(
            turn.id.uuidString,
            status: status,
            reason: nil
        )
        resumeTurnWaiters()
    }

    func beginInterrupt(
        request: MSPTurnInterruptRequest,
        conversationThreadID: String
    ) throws -> MSPTurnInterruptBeginResult {
        try validateCapability()
        try validateThread(request.threadID, conversationThreadID)
        if request.turnID.isEmpty {
            return try startupInterruptResponse(threadID: conversationThreadID)
        }
        if let activeTurn {
            return try beginActiveTurnInterrupt(request.turnID, activeTurn)
        }
        if let terminal = completionRegistry.terminalTurn(request.turnID) {
            throw MSPTurnInterruptError.terminalTurn(
                turnID: request.turnID,
                status: terminal.status
            )
        }
        throw MSPTurnInterruptError.noActiveTurn(turnID: request.turnID)
    }

    func waitForPendingInterrupt(turnID: String) async throws -> MSPTurnInterruptResponse {
        try await completionRegistry.waitForPendingInterrupt(turnID: turnID)
    }

    func beginInterruptCompletion(_ commit: MSPTurnInterruptCommit) -> Bool {
        completionRegistry.beginInterruptCompletion(turnID: commit.turnID)
    }

    func completeInterrupt(
        _ commit: MSPTurnInterruptCommit,
        reason: MSPTurnInterruptAbortReason
    ) -> MSPTurnInterruptResponse {
        let event = abortEvent(for: commit, reason: reason)
        if activeTurn?.id == commit.turn.id {
            activeTurn = nil
        }
        completionRegistry.rememberTerminalTurn(
            commit.turnID,
            status: .interrupted,
            reason: reason
        )
        resumeTurnWaiters()
        let response = MSPTurnInterruptResponse(
            threadID: commit.turn.threadID,
            turnID: commit.turnID,
            reason: reason,
            terminalEvent: event
        )
        completionRegistry.resolveInterrupt(
            turnID: commit.turnID,
            response: response
        )
        return response
    }

    func completeCancellation(
        id turnID: UUID,
        reason: MSPTurnInterruptAbortReason
    ) -> MSPTurnInterruptCommit? {
        guard var turn = activeTurn, turn.id == turnID else {
            return nil
        }
        let recordsInterruptedTranscript = turn.kind == .user || turn.status == .interrupting
        turn.status = .interrupting
        activeTurn = turn
        turn.task?.cancel()
        return MSPTurnInterruptCommit(
            turn: turn,
            requestedTurnID: turnID.uuidString,
            completedAt: Date(),
            recordsInterruptedTranscript: recordsInterruptedTranscript
        )
    }

    private func beginActiveTurnInterrupt(
        _ requestedTurnID: String,
        _ turn: MSPTurnInterruptRuntimeTurn
    ) throws -> MSPTurnInterruptBeginResult {
        guard turn.id.uuidString == requestedTurnID else {
            throw MSPTurnInterruptError.activeTurnMismatch(
                requested: requestedTurnID,
                active: turn.id.uuidString
            )
        }
        guard turn.status == .running else {
            return .waitForPending(turnID: requestedTurnID)
        }
        var updated = turn
        updated.status = .interrupting
        updated.task?.cancel()
        activeTurn = updated
        return .perform(MSPTurnInterruptCommit(
            turn: updated,
            requestedTurnID: requestedTurnID,
            completedAt: Date(),
            recordsInterruptedTranscript: true
        ))
    }

    private func startupInterruptResponse(
        threadID: String
    ) throws -> MSPTurnInterruptBeginResult {
        guard capability.supportsStartupInterrupt else {
            throw MSPTurnInterruptError.startupInterruptUnsupported
        }
        return .startupAck(MSPTurnInterruptResponse(
            threadID: threadID,
            turnID: nil,
            reason: .interrupted,
            terminalEvent: nil
        ))
    }

    private func validateCapability() throws {
        guard capability.isEnabled else {
            throw MSPTurnInterruptError.capabilityDisabled
        }
    }

    private func validateThread(_ requested: String, _ actual: String) throws {
        guard requested == actual else {
            throw MSPTurnInterruptError.threadMismatch(
                expected: requested,
                actual: actual
            )
        }
    }

    private func abortEvent(
        for commit: MSPTurnInterruptCommit,
        reason: MSPTurnInterruptAbortReason
    ) -> MSPTurnInterruptTurnAbortedEvent {
        let duration = Int(commit.completedAt.timeIntervalSince(commit.turn.startedAt) * 1000)
        return MSPTurnInterruptTurnAbortedEvent(
            threadID: commit.turn.threadID,
            turnID: commit.turnID,
            reason: reason,
            completedAt: commit.completedAt,
            durationMilliseconds: max(0, duration)
        )
    }

    private func resumeTurnWaiters() {
        let continuations = waitingTurnContinuations
        waitingTurnContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}
