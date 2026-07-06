import Foundation

final class MSPGoalController {
    static let maximumObjectiveCharacters = 4_000

    let capability: MSPGoalCapability
    var goal: MSPGoalSnapshot?
    var activeTurn: MSPGoalRuntimeTurn?
    var lastBudgetLimitContextGoalID: String?

    init(capability: MSPGoalCapability) {
        self.capability = capability
        self.goal = capability.restoredGoal?.withRecomputedBudget
    }

    var declaration: MSPGoalCapabilityDeclaration {
        capability.declaration
    }

    func currentGoal(threadID: String, conversationThreadID: String) throws -> MSPGoalSnapshot? {
        try validateThread(threadID, conversationThreadID)
        try validateCapability()
        try validateStoredGoalThread(conversationThreadID)
        return goal
    }

    func createGoal(
        _ request: MSPGoalCreateRequest,
        conversationThreadID: String
    ) throws -> MSPGoalMutationOutcome {
        try validateThread(request.threadID, conversationThreadID)
        try validateCapability()
        try validateStoredGoalThread(conversationThreadID)
        let objective = try normalizedObjective(request.objective)
        try validateBudget(request.tokenBudget)
        if let existing = goal, existing.status.isUnfinished {
            throw MSPGoalError.unfinishedGoalExists(goalID: existing.goalID)
        }

        let previous = goal
        let now = Date()
        let created = MSPGoalSnapshot(
            threadID: request.threadID,
            objective: objective,
            status: .active,
            tokenBudget: request.tokenBudget,
            createdAt: now,
            updatedAt: now
        ).withRecomputedBudget
        goal = created
        markActiveGoalIfCurrentTurn(created)
        let reason: MSPGoalMutationReason = previous == nil ? .created : .replaced
        return mutationOutcome(
            goal: created,
            previous: previous,
            source: request.source,
            sourceTurnID: request.sourceTurnID,
            reason: reason,
            eventID: eventID(reason: reason, turnID: request.sourceTurnID)
        )
    }

    func setGoal(
        _ request: MSPGoalSetRequest,
        conversationThreadID: String
    ) throws -> MSPGoalMutationOutcome {
        try validateThread(request.threadID, conversationThreadID)
        try validateCapability()
        try validateStoredGoalThread(conversationThreadID)
        if let objective = request.objective {
            _ = try normalizedObjective(objective)
        }
        if case .set(let budget) = request.tokenBudget {
            try validateBudget(budget)
        }
        let preEvents = accountActiveGoalProgress(
            eventID: activeTurn.map { "\($0.id.uuidString):external-goal-mutation" }
                ?? "goal-external-mutation:\(UUID().uuidString)",
            mode: .activeOnly,
            disposition: .clearActive,
            source: .runtime
        )
        let now = Date()
        let previous = goal
        guard let previousGoal = previous else {
            guard let objective = request.objective else {
                throw MSPGoalError.noGoal(threadID: request.threadID)
            }
            let created = MSPGoalSnapshot(
                threadID: request.threadID,
                objective: try normalizedObjective(objective),
                status: request.status ?? .active,
                tokenBudget: request.tokenBudget.valueForCreate,
                createdAt: now,
                updatedAt: now
            ).withRecomputedBudget
            goal = created
            markActiveGoalIfCurrentTurn(created)
            var outcome = mutationOutcome(
                goal: created,
                previous: nil,
                source: request.source,
                sourceTurnID: request.sourceTurnID,
                reason: .created,
                eventID: eventID(reason: .created, turnID: request.sourceTurnID)
            )
            outcome.events = preEvents + outcome.events
            outcome.response.runtimeEvents = outcome.events
            return outcome
        }

        var updated = previousGoal
        let objectiveChanged: Bool
        if let objective = request.objective {
            let normalized = try normalizedObjective(objective)
            objectiveChanged = normalized != updated.objective
            updated.objective = normalized
        } else {
            objectiveChanged = false
        }
        if let status = request.status {
            updated.status = statusAfterBudgetLimit(status, goal: updated)
        }
        if case .set(let tokenBudget) = request.tokenBudget {
            updated.tokenBudget = tokenBudget
        }
        updated.updatedAt = now
        updated = updated.withRecomputedBudget
        goal = updated
        applyActiveAccountingState(for: updated)
        if objectiveChanged {
            appendContextToActiveTurn(
                MSPGoalChatMapping.objectiveUpdatedInputItem(for: updated)
            )
        }
        var outcome = mutationOutcome(
            goal: updated,
            previous: previous,
            source: request.source,
            sourceTurnID: request.sourceTurnID,
            reason: .updated,
            eventID: eventID(reason: .updated, turnID: request.sourceTurnID)
        )
        outcome.events = preEvents + outcome.events
        outcome.response.runtimeEvents = outcome.events
        return outcome
    }

    func updateGoal(
        _ request: MSPGoalUpdateRequest,
        conversationThreadID: String
    ) throws -> MSPGoalMutationOutcome {
        try validateThread(request.threadID, conversationThreadID)
        try validateCapability()
        try validateStoredGoalThread(conversationThreadID)
        if request.source == .modelTool,
           request.status != .complete,
           request.status != .blocked {
            throw MSPGoalError.modelToolStatusUnsupported(status: request.status)
        }
        let preEvents = accountActiveGoalProgress(
            eventID: request.sourceTurnID ?? "goal-update:\(UUID().uuidString)",
            mode: request.status == .complete ? .activeOrComplete : .activeOrStopped,
            disposition: .clearActive,
            source: .runtime
        )
        guard var current = goal else {
            throw MSPGoalError.noGoal(threadID: request.threadID)
        }
        let previous = current
        current.status = statusAfterBudgetLimit(request.status, goal: current)
        current.updatedAt = Date()
        current = current.withRecomputedBudget
        goal = current
        applyActiveAccountingState(for: current)
        var outcome = mutationOutcome(
            goal: current,
            previous: previous,
            source: request.source,
            sourceTurnID: request.sourceTurnID,
            reason: .statusChanged,
            eventID: eventID(reason: .statusChanged, turnID: request.sourceTurnID)
        )
        outcome.events = preEvents + outcome.events
        outcome.response.runtimeEvents = outcome.events
        return outcome
    }

    func clearGoal(threadID: String, conversationThreadID: String) throws -> (MSPGoalClearResponse, [MSPAgentEvent]) {
        try validateThread(threadID, conversationThreadID)
        try validateCapability()
        try validateStoredGoalThread(conversationThreadID)
        let preEvents = accountActiveGoalProgress(
            eventID: activeTurn.map { "\($0.id.uuidString):external-goal-mutation" }
                ?? "goal-clear-mutation:\(UUID().uuidString)",
            mode: .activeOnly,
            disposition: .clearActive,
            source: .runtime
        )
        let cleared = goal
        goal = nil
        activeTurn?.activeGoalID = nil
        let now = Date()
        let eventID = "goal-clear:\(UUID().uuidString)"
        var response = MSPGoalClearResponse(
            threadID: threadID,
            cleared: cleared != nil,
            clearedGoal: cleared,
            source: .sdk,
            eventID: eventID,
            clearedAt: now
        )
        guard let cleared else {
            response.runtimeEvents = preEvents
            return (response, preEvents)
        }
        let events = preEvents + [
            .threadGoalCleared(MSPGoalClearedEvent(
                threadID: threadID,
                clearedGoal: cleared,
                source: .sdk,
                eventID: eventID,
                occurredAt: now
            ))
        ]
        response.runtimeEvents = events
        return (response, events)
    }

}
