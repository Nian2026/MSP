import Foundation

extension MSPGoalController {
    func mutationOutcome(
        goal: MSPGoalSnapshot,
        previous: MSPGoalSnapshot?,
        source: MSPGoalUpdateSource,
        sourceTurnID: String?,
        reason: MSPGoalMutationReason,
        eventID: String
    ) -> MSPGoalMutationOutcome {
        let acceptedAt = Date()
        let event = MSPAgentEvent.threadGoalUpdated(MSPGoalUpdatedEvent(
            threadID: goal.threadID,
            turnID: sourceTurnID,
            goal: goal,
            previousGoal: previous,
            source: source,
            reason: reason,
            eventID: eventID,
            occurredAt: acceptedAt
        ))
        let response = MSPGoalMutationResponse(
            goal: goal,
            previousGoal: previous,
            source: source,
            sourceTurnID: sourceTurnID,
            eventID: eventID,
            acceptedAt: acceptedAt,
            reason: reason,
            runtimeEvents: [event]
        )
        return MSPGoalMutationOutcome(
            response: response,
            events: [event]
        )
    }

    func eventID(reason: MSPGoalMutationReason, turnID: String?) -> String {
        if let turnID, !turnID.isEmpty {
            return "\(turnID):goal-\(reason.rawValue)"
        }
        return "goal-\(reason.rawValue):\(UUID().uuidString)"
    }

    func markActiveGoalIfCurrentTurn(_ goal: MSPGoalSnapshot) {
        guard var turn = activeTurn, turn.accountTokens else {
            return
        }
        if goal.status == .active {
            turn.activeGoalID = goal.goalID
            turn.unaccountedTokens = 0
            turn.lastAccountedAt = goal.updatedAt
        } else {
            turn.activeGoalID = nil
        }
        activeTurn = turn
    }

    func applyActiveAccountingState(for goal: MSPGoalSnapshot) {
        guard var turn = activeTurn,
              turn.threadID == goal.threadID,
              turn.accountTokens else {
            return
        }
        if goal.status == .active {
            turn.activeGoalID = goal.goalID
            turn.unaccountedTokens = 0
            turn.lastAccountedAt = goal.updatedAt
            activeTurn = turn
            return
        }
        guard turn.activeGoalID == goal.goalID else {
            return
        }
        if MSPGoalAccounting.shouldClearActiveGoal(status: goal.status, disposition: .clearActive) {
            turn.activeGoalID = nil
        }
        activeTurn = turn
    }

    func appendContextToActiveTurn(_ item: MSPAgentJSONValue) {
        guard var turn = activeTurn else {
            return
        }
        turn.pendingContextItems.append(item)
        activeTurn = turn
    }

    func statusAfterBudgetLimit(
        _ requestedStatus: MSPGoalStatus,
        goal: MSPGoalSnapshot
    ) -> MSPGoalStatus {
        if goal.status == .budgetLimited,
           requestedStatus == .paused || requestedStatus == .blocked {
            return .budgetLimited
        }
        guard requestedStatus == .active,
              let tokenBudget = goal.tokenBudget,
              goal.tokensUsed >= tokenBudget else {
            return requestedStatus
        }
        return .budgetLimited
    }

    func statusAfterAccounting(
        _ status: MSPGoalStatus,
        tokenBudget: Int?,
        tokensUsed: Int,
        mode: MSPGoalAccountingMode
    ) -> MSPGoalStatus {
        guard let tokenBudget, tokensUsed >= tokenBudget else {
            return status
        }
        switch mode {
        case .activeOnly, .activeOrComplete:
            return status == .active ? .budgetLimited : status
        case .activeOrStopped:
            return status == .complete ? status : .budgetLimited
        }
    }

    func accountActiveGoalProgress(
        eventID: String,
        mode: MSPGoalAccountingMode,
        disposition: MSPGoalBudgetLimitedDisposition,
        source: MSPGoalUpdateSource
    ) -> [MSPAgentEvent] {
        guard var current = goal,
              MSPGoalAccounting.canAccount(status: current.status, mode: mode) else {
            return []
        }

        let now = Date()
        let previous = current
        let turnID: String?
        let tokenDelta: Int
        let timeDelta: Int
        if let turn = activeTurn {
            guard turn.activeGoalID == current.goalID else {
                return []
            }
            turnID = turn.id.uuidString
            tokenDelta = max(0, turn.unaccountedTokens)
            timeDelta = max(0, Int(now.timeIntervalSince(turn.lastAccountedAt)))
        } else {
            guard current.status == .active else {
                return []
            }
            turnID = nil
            tokenDelta = 0
            timeDelta = max(0, Int(now.timeIntervalSince(current.updatedAt)))
        }
        if tokenDelta == 0 && timeDelta == 0 {
            return []
        }

        current.tokensUsed += tokenDelta
        current.timeUsedSeconds += timeDelta
        current.updatedAt = now
        current.status = statusAfterAccounting(
            current.status,
            tokenBudget: current.tokenBudget,
            tokensUsed: current.tokensUsed,
            mode: mode
        )
        current = current.withRecomputedBudget
        goal = current

        if var turn = activeTurn {
            turn.unaccountedTokens = 0
            turn.lastAccountedAt = now
            if turn.activeGoalID == current.goalID,
               MSPGoalAccounting.shouldClearActiveGoal(
                   status: current.status,
                   disposition: disposition
               ) {
                turn.activeGoalID = nil
            }
            activeTurn = turn
        }

        var events: [MSPAgentEvent] = [
            .threadGoalAccounted(MSPGoalAccountedEvent(
                threadID: current.threadID,
                turnID: turnID,
                goalID: current.goalID,
                tokenDelta: tokenDelta,
                timeDeltaSeconds: timeDelta,
                tokensUsed: current.tokensUsed,
                timeUsedSeconds: current.timeUsedSeconds,
                status: current.status,
                eventID: eventID
            ))
        ]
        if previous.status != current.status {
            events.append(.threadGoalUpdated(MSPGoalUpdatedEvent(
                threadID: current.threadID,
                turnID: turnID,
                goal: current,
                previousGoal: previous,
                source: source,
                reason: .accounted,
                eventID: "\(eventID):status",
                occurredAt: now
            )))
            if current.status == .budgetLimited {
                appendContextToActiveTurn(MSPGoalChatMapping.budgetLimitInputItem(for: current))
            }
        }
        return events
    }

    func stopActiveGoalForTurn(
        status: MSPGoalStatus,
        turnID: String
    ) -> [MSPAgentEvent] {
        guard let initialGoal = goal,
              let activeGoalID = activeTurn?.activeGoalID,
              activeGoalID == initialGoal.goalID else {
            return []
        }
        var events = accountActiveGoalProgress(
            eventID: "\(turnID):goal-stop-accounting",
            mode: .activeOrStopped,
            disposition: .clearActive,
            source: .runtime
        )
        guard var current = goal,
              current.goalID == activeGoalID,
              current.status != .complete else {
            return events
        }
        let canStop = current.status == .active
            || (current.status == .budgetLimited && status == .usageLimited)
        guard canStop else {
            return events
        }
        let nextStatus = statusAfterBudgetLimit(status, goal: current)
        guard current.status != nextStatus else {
            return events
        }
        let previous = current
        current.status = nextStatus
        current.updatedAt = Date()
        current = current.withRecomputedBudget
        goal = current
        applyActiveAccountingState(for: current)
        events.append(.threadGoalUpdated(MSPGoalUpdatedEvent(
            threadID: current.threadID,
            turnID: turnID,
            goal: current,
            previousGoal: previous,
            source: .runtime,
            reason: .statusChanged,
            eventID: "\(turnID):goal-stop-\(current.status.rawValue)"
        )))
        return events
    }

}
