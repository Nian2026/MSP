import Foundation

enum MSPGoalAccountingMode: Hashable, Sendable {
    case activeOnly
    case activeOrComplete
    case activeOrStopped
}

enum MSPGoalBudgetLimitedDisposition: Hashable, Sendable {
    case keepActive
    case clearActive
}

struct MSPGoalAccountingResult: Hashable, Sendable {
    var goal: MSPGoalSnapshot
    var previousGoal: MSPGoalSnapshot
    var tokenDelta: Int
    var timeDeltaSeconds: Int
    var eventID: String
    var turnID: String?
    var budgetLimitJustReached: Bool
}

enum MSPGoalAccounting {
    static func tokenDelta(from usage: MSPAgentContextUsageRecord) -> Int {
        let input = usage.serverInputTokens ?? usage.estimatedInputTokens
        let cachedInput = usage.serverCachedInputTokens ?? 0
        let output = usage.serverOutputTokens ?? 0
        return max(0, input - max(0, cachedInput)) + max(0, output)
    }

    static func canAccount(
        status: MSPGoalStatus,
        mode: MSPGoalAccountingMode
    ) -> Bool {
        switch mode {
        case .activeOnly:
            return status == .active || status == .budgetLimited
        case .activeOrComplete:
            return status == .active || status == .budgetLimited || status == .complete
        case .activeOrStopped:
            return status != .complete
        }
    }

    static func shouldClearActiveGoal(
        status: MSPGoalStatus,
        disposition: MSPGoalBudgetLimitedDisposition
    ) -> Bool {
        switch status {
        case .active:
            return false
        case .budgetLimited:
            return disposition == .clearActive
        case .paused, .blocked, .usageLimited, .complete:
            return true
        }
    }

    static func shouldCountToolFinish(
        call: MSPAgentToolCall,
        result: MSPAgentToolResult
    ) -> Bool {
        guard !MSPGoalTools.isGoalTool(call.name) else {
            return false
        }
        return result.ok || result.internalContent != nil
    }
}
