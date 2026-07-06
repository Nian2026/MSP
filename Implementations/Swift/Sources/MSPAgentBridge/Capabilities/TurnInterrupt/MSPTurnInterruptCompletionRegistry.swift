import Foundation

final class MSPTurnInterruptCompletionRegistry {
    private var terminalTurns: [String: MSPTurnInterruptTerminalTurn] = [:]
    private var terminalTurnOrder: [String] = []
    private var interruptCompletionsInProgress: Set<String> = []
    private var resolvedInterruptResponses: [String: MSPTurnInterruptResponse] = [:]
    private var pendingInterruptWaiters:
        [String: [CheckedContinuation<MSPTurnInterruptResponse, Error>]] = [:]

    func terminalTurn(_ turnID: String) -> MSPTurnInterruptTerminalTurn? {
        terminalTurns[turnID]
    }

    func waitForPendingInterrupt(turnID: String) async throws -> MSPTurnInterruptResponse {
        if let response = resolvedInterruptResponses[turnID] {
            return response
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingInterruptWaiters[turnID, default: []].append(continuation)
        }
    }

    func beginInterruptCompletion(turnID: String) -> Bool {
        if resolvedInterruptResponses[turnID] != nil {
            return false
        }
        if terminalTurns[turnID] != nil {
            return false
        }
        guard !interruptCompletionsInProgress.contains(turnID) else {
            return false
        }
        interruptCompletionsInProgress.insert(turnID)
        return true
    }

    func rememberTerminalTurn(
        _ turnID: String,
        status: MSPTurnInterruptTurnStatus,
        reason: MSPTurnInterruptAbortReason?
    ) {
        terminalTurns[turnID] = MSPTurnInterruptTerminalTurn(
            turnID: turnID,
            status: status,
            reason: reason
        )
        terminalTurnOrder.append(turnID)
        while terminalTurnOrder.count > 64 {
            let removed = terminalTurnOrder.removeFirst()
            terminalTurns.removeValue(forKey: removed)
            resolvedInterruptResponses.removeValue(forKey: removed)
        }
    }

    func resolveInterrupt(
        turnID: String,
        response: MSPTurnInterruptResponse
    ) {
        interruptCompletionsInProgress.remove(turnID)
        resolvedInterruptResponses[turnID] = response
        let waiters = pendingInterruptWaiters.removeValue(forKey: turnID) ?? []
        for waiter in waiters {
            waiter.resume(returning: response)
        }
    }
}
