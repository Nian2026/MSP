import Foundation

public enum MSPGoalChatMapping {
    public static let threadGoalUpdatedTimelineType = "thread_goal_updated"
    public static let threadGoalClearedTimelineType = "thread_goal_cleared"
    public static let threadGoalAccountedTimelineType = "thread_goal_accounted"

    public static func continuationInputItem(
        for goal: MSPGoalSnapshot
    ) -> MSPAgentJSONValue {
        internalGoalContextItem("""
        <goal_continuation>
        Continue working toward the thread goal.
        Objective: \(escapeXML(goal.objective))
        Status: \(goal.status.rawValue)
        Tokens used: \(goal.tokensUsed)
        Token budget: \(goal.tokenBudget.map(String.init) ?? "none")
        Remaining tokens: \(goal.remainingTokens.map(String.init) ?? "unbounded")
        </goal_continuation>
        """)
    }

    public static func objectiveUpdatedInputItem(
        for goal: MSPGoalSnapshot
    ) -> MSPAgentJSONValue {
        internalGoalContextItem("""
        <goal_objective_updated>
        The active thread goal was updated.
        Objective: \(escapeXML(goal.objective))
        Status: \(goal.status.rawValue)
        Tokens used: \(goal.tokensUsed)
        Token budget: \(goal.tokenBudget.map(String.init) ?? "none")
        Remaining tokens: \(goal.remainingTokens.map(String.init) ?? "unbounded")
        </goal_objective_updated>
        """)
    }

    public static func budgetLimitInputItem(
        for goal: MSPGoalSnapshot
    ) -> MSPAgentJSONValue {
        internalGoalContextItem("""
        <goal_budget_limited>
        The active thread goal has reached its token budget.
        Objective: \(escapeXML(goal.objective))
        Tokens used: \(goal.tokensUsed)
        Token budget: \(goal.tokenBudget.map(String.init) ?? "none")
        </goal_budget_limited>
        """)
    }

    public static func timelinePayload(
        for event: MSPGoalUpdatedEvent
    ) -> [String: MSPAgentJSONValue] {
        var payload = goalPayload(event.goal)
        payload["event_id"] = .string(event.eventID)
        payload["source"] = .string(event.source.rawValue)
        payload["reason"] = .string(event.reason.rawValue)
        if let turnID = event.turnID {
            payload["turn_id"] = .string(turnID)
        }
        if let previousGoal = event.previousGoal {
            payload["previous_goal_id"] = .string(previousGoal.goalID)
            payload["previous_status"] = .string(previousGoal.status.rawValue)
        }
        return payload
    }

    public static func timelinePayload(
        for event: MSPGoalClearedEvent
    ) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "thread_id": .string(event.threadID),
            "event_id": .string(event.eventID),
            "source": .string(event.source.rawValue),
            "cleared": .bool(event.clearedGoal != nil)
        ]
        if let clearedGoal = event.clearedGoal {
            payload["goal_id"] = .string(clearedGoal.goalID)
            payload["objective"] = .string(clearedGoal.objective)
            payload["status"] = .string(clearedGoal.status.rawValue)
        }
        return payload
    }

    public static func timelinePayload(
        for event: MSPGoalAccountedEvent
    ) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "thread_id": .string(event.threadID),
            "goal_id": .string(event.goalID),
            "event_id": .string(event.eventID),
            "token_delta": .number(Double(event.tokenDelta)),
            "time_delta_seconds": .number(Double(event.timeDeltaSeconds)),
            "tokens_used": .number(Double(event.tokensUsed)),
            "time_used_seconds": .number(Double(event.timeUsedSeconds)),
            "status": .string(event.status.rawValue)
        ]
        if let turnID = event.turnID {
            payload["turn_id"] = .string(turnID)
        }
        return payload
    }

    public static func goalPayload(
        _ goal: MSPGoalSnapshot
    ) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "thread_id": .string(goal.threadID),
            "goal_id": .string(goal.goalID),
            "objective": .string(goal.objective),
            "status": .string(goal.status.rawValue),
            "tokens_used": .number(Double(goal.tokensUsed)),
            "time_used_seconds": .number(Double(goal.timeUsedSeconds)),
            "created_at": .string(isoString(goal.createdAt)),
            "updated_at": .string(isoString(goal.updatedAt))
        ]
        if let tokenBudget = goal.tokenBudget {
            payload["token_budget"] = .number(Double(tokenBudget))
        }
        if let remainingTokens = goal.remainingTokens {
            payload["remaining_tokens"] = .number(Double(remainingTokens))
        }
        return payload
    }

    private static func internalGoalContextItem(_ text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text)
                ])
            ]),
            "metadata": .object([
                "msp_internal_context_source": .string("goal")
            ])
        ])
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
