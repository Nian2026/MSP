import Foundation

enum MSPGoalRuntime {
    static func modelToolResult(
        call: MSPAgentToolCall,
        ok: Bool,
        content: MSPAgentJSONValue?,
        errorMessage: String? = nil
    ) -> MSPAgentToolResult {
        MSPAgentToolResult(
            callID: call.id,
            name: call.name,
            outputKind: call.outputKind,
            ok: ok,
            content: content,
            errorMessage: errorMessage
        )
    }

    static func toolOutput(
        goal: MSPGoalSnapshot?,
        includeCompletionBudgetReport: Bool = false
    ) -> MSPAgentJSONValue {
        var object: [String: MSPAgentJSONValue] = [
            "goal": goal.map { .object(toolGoalPayload($0)) } ?? .null,
            "remainingTokens": goal?.remainingTokens.map { .number(Double($0)) } ?? .null,
            "completionBudgetReport": .null
        ]
        if includeCompletionBudgetReport,
           let goal,
           goal.status == .complete,
           goal.tokenBudget != nil || goal.timeUsedSeconds > 0 {
            object["completionBudgetReport"] = .string(
                "Goal achieved. Report final usage from this tool result's structured goal fields."
            )
        }
        return .object(object)
    }

    static func toolGoalPayload(_ goal: MSPGoalSnapshot) -> [String: MSPAgentJSONValue] {
        var payload: [String: MSPAgentJSONValue] = [
            "threadId": .string(goal.threadID),
            "goalId": .string(goal.goalID),
            "objective": .string(goal.objective),
            "status": .string(goal.status.rawValue),
            "tokensUsed": .number(Double(goal.tokensUsed)),
            "timeUsedSeconds": .number(Double(goal.timeUsedSeconds)),
            "createdAt": .number(goal.createdAt.timeIntervalSince1970),
            "updatedAt": .number(goal.updatedAt.timeIntervalSince1970)
        ]
        if let tokenBudget = goal.tokenBudget {
            payload["tokenBudget"] = .number(Double(tokenBudget))
        } else {
            payload["tokenBudget"] = .null
        }
        if let remainingTokens = goal.remainingTokens {
            payload["remainingTokens"] = .number(Double(remainingTokens))
        } else {
            payload["remainingTokens"] = .null
        }
        return payload
    }
}
