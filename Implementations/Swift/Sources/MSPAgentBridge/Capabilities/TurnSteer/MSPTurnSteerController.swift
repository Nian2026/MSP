import Foundation

final class MSPTurnSteerController {
    private let lock = NSRecursiveLock()
    private let capability: MSPTurnSteerCapability
    private var activeTurn: MSPTurnSteerRuntimeTurn?
    private var terminalTurns: [String: MSPTurnSteerTerminalTurn] = [:]
    private var nextSequenceNumber = 1
    private var appliedEvents: [String: MSPTurnSteerAppliedEvent] = [:]
    private var appliedContinuations:
        [String: [CheckedContinuation<MSPTurnSteerAppliedEvent, Error>]] = [:]

    init(capability: MSPTurnSteerCapability) {
        self.capability = capability
    }

    var declaration: MSPTurnSteerCapabilityDeclaration {
        withLock {
            capability.declaration
        }
    }

    func startTurn(
        id: UUID,
        threadID: String,
        kind: MSPTurnSteerTurnKind,
        startedAt: Date,
        eventHandler: @escaping MSPAgentConversation.EventHandler
    ) {
        withLock {
            activeTurn = MSPTurnSteerRuntimeTurn(
                id: id,
                threadID: threadID,
                kind: kind,
                status: .running,
                startedAt: startedAt,
                eventHandler: eventHandler
            )
        }
    }

    func activeSnapshot() -> MSPTurnSteerActiveTurn? {
        withLock {
            guard capability.isEnabled else {
                return nil
            }
            return activeTurn?.activeSnapshot
        }
    }

    func canAcceptActiveTurnSteer() -> Bool {
        withLock {
            guard capability.isEnabled,
                  let activeTurn else {
                return false
            }
            return activeTurn.kind == .user && activeTurn.status == .running
        }
    }

    func acceptSteer(
        request: MSPTurnSteerRequest,
        conversationThreadID: String
    ) throws -> MSPTurnSteerAcceptance {
        try withLock {
            try validateCapability()
            try validateThread(request.threadID, conversationThreadID)
            guard !request.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MSPTurnSteerError.emptyExpectedTurnID
            }
            guard var turn = activeTurn else {
                if let terminal = terminalTurns[request.turnID] {
                    throw MSPTurnSteerError.terminalTurn(
                        turnID: request.turnID,
                        status: terminal.status
                    )
                }
                throw MSPTurnSteerError.noActiveTurn(turnID: request.turnID)
            }
            guard turn.id.uuidString == request.turnID else {
                throw MSPTurnSteerError.expectedTurnMismatch(
                    expected: request.turnID,
                    actual: turn.id.uuidString
                )
            }
            guard turn.status == .running else {
                throw MSPTurnSteerError.interruptedTurn(
                    turnID: request.turnID,
                    status: turn.status
                )
            }
            guard turn.kind == .user else {
                throw MSPTurnSteerError.activeTurnNotSteerable(
                    turnID: request.turnID,
                    kind: turn.kind
                )
            }
            guard request.input.hasUserInput else {
                throw MSPTurnSteerError.emptyInput
            }

            let requestedAt = Date()
            let acceptedAt = Date()
            let accepted = MSPTurnSteerAcceptedInput(
                target: turn.activeSnapshot,
                sequenceNumber: nextSequenceNumber,
                input: request.input,
                requestedAt: requestedAt,
                acceptedAt: acceptedAt,
                modelVisibleItems: MSPTurnSteerChatMapping.modelVisibleItems(
                    for: request.input
                )
            )
            nextSequenceNumber += 1
            turn.pendingInputs.append(accepted)
            activeTurn = turn
            return MSPTurnSteerAcceptance(
                acceptedInput: accepted,
                eventHandler: turn.eventHandler
            )
        }
    }

    func pendingInput(
        _ request: MSPAgentToolLoop.PendingInputRequest,
        turnID: UUID
    ) -> MSPTurnSteerPendingInputDrain {
        withLock {
            guard let turn = activeTurn,
                  turn.id == turnID,
                  turn.status == .running else {
                return MSPTurnSteerPendingInputDrain(
                    items: [],
                    appliedEvents: [],
                    eventHandler: nil
                )
            }
            switch request {
            case .peek:
                return MSPTurnSteerPendingInputDrain(
                    items: turn.pendingInputs.flatMap(\.modelVisibleItems),
                    appliedEvents: [],
                    eventHandler: nil
                )
            case .drain:
                return drainPendingInputs(
                    for: turn,
                    boundary: .modelInput
                )
            }
        }
    }

    func pendingInputForActiveTurn(
        _ request: MSPAgentToolLoop.PendingInputRequest
    ) -> [MSPAgentJSONValue] {
        withLock {
            guard let turn = activeTurn else {
                return []
            }
            return pendingInput(request, turnID: turn.id).items
        }
    }

    func beginInterrupt(id turnID: UUID) {
        withLock {
            guard var turn = activeTurn, turn.id == turnID else {
                return
            }
            turn.status = .interrupting
            activeTurn = turn
        }
    }

    func drainPendingInputsForInterruptedTurn(
        id turnID: UUID
    ) -> MSPTurnSteerPendingInputDrain {
        withLock {
            guard let turn = activeTurn, turn.id == turnID else {
                return MSPTurnSteerPendingInputDrain(
                    items: [],
                    appliedEvents: [],
                    eventHandler: nil
                )
            }
            return drainPendingInputs(
                for: turn,
                boundary: .interruptedTranscript
            )
        }
    }

    func finishTurn(
        id turnID: UUID,
        status: MSPTurnSteerTurnStatus
    ) -> MSPTurnSteerPendingInputDrain {
        withLock {
            guard var turn = activeTurn, turn.id == turnID else {
                return MSPTurnSteerPendingInputDrain(
                    items: [],
                    appliedEvents: [],
                    eventHandler: nil
                )
            }
            turn.status = status
            activeTurn = turn
            let boundary: MSPTurnSteerApplicationBoundary =
                status == .interrupted ? .interruptedTranscript : .terminalTranscript
            let drain = drainPendingInputs(for: turn, boundary: boundary)
            activeTurn = nil
            terminalTurns[turn.id.uuidString] = MSPTurnSteerTerminalTurn(
                turnID: turn.id.uuidString,
                status: status
            )
            return drain
        }
    }

    func waitForAppliedEvent(
        turnID: String,
        sequenceNumber: Int
    ) async throws -> MSPTurnSteerAppliedEvent {
        let key = appliedKey(turnID: turnID, sequenceNumber: sequenceNumber)
        return try await withCheckedThrowingContinuation { continuation in
            let event: MSPTurnSteerAppliedEvent? = withLock {
                if let event = appliedEvents[key] {
                    return event
                }
                appliedContinuations[key, default: []].append(continuation)
                return nil
            }
            if let event {
                continuation.resume(returning: event)
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func drainPendingInputs(
        for turn: MSPTurnSteerRuntimeTurn,
        boundary: MSPTurnSteerApplicationBoundary
    ) -> MSPTurnSteerPendingInputDrain {
        guard !turn.pendingInputs.isEmpty else {
            return MSPTurnSteerPendingInputDrain(
                items: [],
                appliedEvents: [],
                eventHandler: nil
            )
        }
        let acceptedInputs = turn.pendingInputs
        let appliedAt = Date()
        let applied = acceptedInputs.map {
            $0.appliedEvent(at: appliedAt, boundary: boundary)
        }
        var updatedTurn = turn
        updatedTurn.pendingInputs.removeAll(keepingCapacity: false)
        activeTurn = updatedTurn
        for event in applied {
            rememberAppliedEvent(event)
        }
        return MSPTurnSteerPendingInputDrain(
            items: acceptedInputs.flatMap(\.modelVisibleItems),
            appliedEvents: applied,
            eventHandler: turn.eventHandler
        )
    }

    private func rememberAppliedEvent(_ event: MSPTurnSteerAppliedEvent) {
        let key = appliedKey(
            turnID: event.turnID,
            sequenceNumber: event.sequenceNumber
        )
        appliedEvents[key] = event
        let continuations = appliedContinuations.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume(returning: event)
        }
    }

    private func appliedKey(turnID: String, sequenceNumber: Int) -> String {
        "\(turnID)#\(sequenceNumber)"
    }

    private func validateCapability() throws {
        guard capability.isEnabled else {
            throw MSPTurnSteerError.capabilityDisabled
        }
    }

    private func validateThread(_ requested: String, _ actual: String) throws {
        guard requested == actual else {
            throw MSPTurnSteerError.threadMismatch(
                expected: requested,
                actual: actual
            )
        }
    }
}
