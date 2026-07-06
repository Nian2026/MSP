import Foundation

extension MSPGoalController {
    func startTurn(
        id: UUID,
        threadID: String,
        kind: MSPGoalTurnKind,
        startedAt: Date
    ) {
        let activeGoalID = goal.flatMap { goal in
            goal.threadID == threadID && (goal.status == .active || goal.status == .budgetLimited)
                ? goal.goalID
                : nil
        }
        activeTurn = MSPGoalRuntimeTurn(
            id: id,
            threadID: threadID,
            kind: kind,
            startedAt: startedAt,
            activeGoalID: activeGoalID
        )
    }

    func recordTokenUsage(_ usage: MSPAgentContextUsageRecord, turnID: UUID) {
        guard var turn = activeTurn,
              turn.id == turnID,
              turn.accountTokens,
              turn.activeGoalID != nil else {
            return
        }
        turn.unaccountedTokens += MSPGoalAccounting.tokenDelta(from: usage)
        activeTurn = turn
    }

    func pendingInput(
        _ request: MSPAgentToolLoop.PendingInputRequest,
        turnID: UUID
    ) -> [MSPAgentJSONValue] {
        guard var turn = activeTurn, turn.id == turnID else {
            return []
        }
        switch request {
        case .peek:
            return turn.pendingContextItems
        case .drain:
            let items = turn.pendingContextItems
            turn.pendingContextItems.removeAll(keepingCapacity: false)
            activeTurn = turn
            return items
        }
    }

    func initialInput(turnID: UUID) -> [MSPAgentJSONValue] {
        guard let turn = activeTurn,
              turn.id == turnID,
              turn.kind == .user,
              let current = goal,
              current.threadID == turn.threadID,
              current.status == .active else {
            return []
        }
        return [MSPGoalChatMapping.continuationInputItem(for: current)]
    }

    func idleContinuationInput(
        threadID: String,
        conversationThreadID: String
    ) throws -> [MSPAgentJSONValue] {
        try validateThread(threadID, conversationThreadID)
        try validateCapability()
        try validateStoredGoalThread(conversationThreadID)
        guard activeTurn == nil,
              let current = goal,
              current.threadID == threadID,
              current.status == .active else {
            return []
        }
        return [MSPGoalChatMapping.continuationInputItem(for: current)]
    }

    func executeGoalTool(
        _ call: MSPAgentToolCall,
        turnID: UUID
    ) -> MSPGoalToolExecutionOutcome? {
        guard MSPGoalTools.isGoalTool(call.name) else {
            return nil
        }
        guard capability.toolsVisible else {
            return MSPGoalToolExecutionOutcome(
                result: toolError(call, "goals feature is disabled"),
                events: []
            )
        }
        do {
            switch call.name.rawValue {
            case MSPGoalTools.getGoalName:
                return MSPGoalToolExecutionOutcome(
                    result: MSPGoalRuntime.modelToolResult(
                        call: call,
                        ok: true,
                        content: MSPGoalRuntime.toolOutput(goal: goal)
                    ),
                    events: []
                )
            case MSPGoalTools.createGoalName:
                let request = try createRequest(from: call, turnID: turnID)
                let outcome = try createGoal(request, conversationThreadID: request.threadID)
                return MSPGoalToolExecutionOutcome(
                    result: MSPGoalRuntime.modelToolResult(
                        call: call,
                        ok: true,
                        content: MSPGoalRuntime.toolOutput(goal: outcome.response.goal)
                    ),
                    events: outcome.events
                )
            case MSPGoalTools.updateGoalName:
                let request = try updateRequest(from: call, turnID: turnID)
                let outcome = try updateGoal(request, conversationThreadID: request.threadID)
                return MSPGoalToolExecutionOutcome(
                    result: MSPGoalRuntime.modelToolResult(
                        call: call,
                        ok: true,
                        content: MSPGoalRuntime.toolOutput(
                            goal: outcome.response.goal,
                            includeCompletionBudgetReport: request.status == .complete
                        )
                    ),
                    events: outcome.events
                )
            default:
                return nil
            }
        } catch let error as MSPGoalError {
            return MSPGoalToolExecutionOutcome(
                result: toolError(call, error.errorDescription ?? error.reason.rawValue),
                events: []
            )
        } catch {
            return MSPGoalToolExecutionOutcome(
                result: toolError(call, "\(error)"),
                events: []
            )
        }
    }

    func toolFinished(
        _ call: MSPAgentToolCall,
        result: MSPAgentToolResult,
        turnID: UUID
    ) -> MSPGoalLifecycleOutcome {
        guard MSPGoalAccounting.shouldCountToolFinish(call: call, result: result) else {
            return MSPGoalLifecycleOutcome(events: [])
        }
        let events = accountActiveGoalProgress(
            eventID: call.id,
            mode: .activeOnly,
            disposition: .keepActive,
            source: .runtime
        )
        return MSPGoalLifecycleOutcome(events: events)
    }

    func finishTurn(
        id turnID: UUID,
        status: MSPGoalTurnStatus
    ) -> MSPGoalLifecycleOutcome {
        guard let turn = activeTurn, turn.id == turnID else {
            return MSPGoalLifecycleOutcome(events: [])
        }
        let events: [MSPAgentEvent]
        switch status {
        case .completed, .interrupted:
            events = accountActiveGoalProgress(
                eventID: "\(turn.id.uuidString):turn-\(status == .interrupted ? "abort" : "stop")",
                mode: .activeOnly,
                disposition: .clearActive,
                source: .runtime
            )
        case .usageLimited:
            events = stopActiveGoalForTurn(
                status: .usageLimited,
                turnID: turn.id.uuidString
            )
        case .failed:
            events = stopActiveGoalForTurn(
                status: .blocked,
                turnID: turn.id.uuidString
            )
        case .running:
            events = []
        }
        activeTurn = nil
        return MSPGoalLifecycleOutcome(events: events)
    }

    func restoreAfterResume() -> MSPGoalLifecycleOutcome {
        guard capability.isEnabled, var restored = goal, restored.status == .active else {
            return MSPGoalLifecycleOutcome(events: [])
        }
        restored.updatedAt = Date()
        goal = restored.withRecomputedBudget
        return MSPGoalLifecycleOutcome(events: [])
    }
}
