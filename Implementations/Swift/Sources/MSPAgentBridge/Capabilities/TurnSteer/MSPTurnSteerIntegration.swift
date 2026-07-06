import Foundation

extension MSPAgentConversation: MSPTurnSteerProtocol {
    public func steerTurn(
        _ request: MSPTurnSteerRequest
    ) async throws -> MSPTurnSteerResponse {
        let acceptance = try turnSteerController.acceptSteer(
            request: request,
            conversationThreadID: threadID
        )
        await acceptance.eventHandler(.turnSteerAccepted(
            acceptance.acceptedInput.acceptedEvent
        ))
        return acceptance.acceptedInput.response
    }

    public func steerActiveTurn(
        _ input: MSPTurnSteerInput
    ) async throws -> MSPTurnSteerHandle {
        guard turnSteerController.declaration.enabled else {
            throw MSPTurnSteerError.capabilityDisabled
        }
        guard let active = turnSteerController.activeSnapshot() else {
            throw MSPTurnSteerError.noActiveTurn(turnID: "")
        }
        let response = try await steerTurn(MSPTurnSteerRequest(
            threadID: active.threadID,
            turnID: active.turnID,
            input: input
        ))
        return MSPTurnSteerHandle(
            response: response,
            appliedEventTask: appliedEventTask(for: response)
        )
    }

    public func currentTurnSteerTarget()
        async -> MSPTurnSteerActiveTurn? {
        turnSteerController.activeSnapshot()
    }

    public func turnSteerCapabilityDeclaration()
        async -> MSPTurnSteerCapabilityDeclaration {
        turnSteerController.declaration
    }

    func startTrackedSteerTurn(
        id turnID: UUID,
        kind: MSPTurnSteerTurnKind,
        startedAt: Date,
        onEvent: @escaping EventHandler
    ) {
        turnSteerController.startTurn(
            id: turnID,
            threadID: threadID,
            kind: kind,
            startedAt: startedAt,
            eventHandler: onEvent
        )
    }

    func canSteerActiveUserTurn() -> Bool {
        turnSteerController.canAcceptActiveTurnSteer()
    }

    func steerActiveUserTurnFromSend(_ userMessage: String) async throws -> Bool {
        guard let active = turnSteerController.activeSnapshot(),
              active.kind == .user,
              active.status == .running else {
            return false
        }
        _ = try await steerTurn(MSPTurnSteerRequest(
            threadID: active.threadID,
            turnID: active.turnID,
            input: MSPTurnSteerInput(text: userMessage)
        ))
        return true
    }

    func activeTurnSteerPendingInput(
        _ request: MSPAgentToolLoop.PendingInputRequest,
        id turnID: UUID
    ) async -> [MSPAgentJSONValue] {
        let drain = turnSteerController.pendingInput(request, turnID: turnID)
        await emitTurnSteerAppliedEvents(drain)
        return drain.items
    }

    func activeTurnSteerPendingInput(
        _ request: MSPAgentToolLoop.PendingInputRequest
    ) -> [MSPAgentJSONValue] {
        turnSteerController.pendingInputForActiveTurn(request)
    }

    func beginTurnSteerInterrupt(id turnID: UUID) {
        turnSteerController.beginInterrupt(id: turnID)
    }

    func interruptedTurnSteerTranscriptItems(
        id turnID: UUID
    ) async -> [MSPAgentJSONValue] {
        let drain = turnSteerController
            .drainPendingInputsForInterruptedTurn(id: turnID)
        await emitTurnSteerAppliedEvents(drain)
        return drain.items
    }

    func finishTurnSteer(
        id turnID: UUID,
        status: MSPTurnSteerTurnStatus
    ) async -> [MSPAgentJSONValue] {
        let drain = turnSteerController.finishTurn(id: turnID, status: status)
        await emitTurnSteerAppliedEvents(drain)
        return drain.items
    }

    private func appliedEventTask(
        for response: MSPTurnSteerResponse
    ) -> Task<MSPTurnSteerAppliedEvent, Error> {
        Task {
            try await self.waitForTurnSteerApplied(
                turnID: response.target.turnID,
                sequenceNumber: response.sequenceNumber
            )
        }
    }

    private func waitForTurnSteerApplied(
        turnID: String,
        sequenceNumber: Int
    ) async throws -> MSPTurnSteerAppliedEvent {
        try await turnSteerController.waitForAppliedEvent(
            turnID: turnID,
            sequenceNumber: sequenceNumber
        )
    }

    private func emitTurnSteerAppliedEvents(
        _ drain: MSPTurnSteerPendingInputDrain
    ) async {
        guard let eventHandler = drain.eventHandler else {
            return
        }
        for event in drain.appliedEvents {
            await eventHandler(.turnSteerApplied(event))
        }
    }
}
