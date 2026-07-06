import Foundation

extension MSPGoalController {
    func createRequest(
        from call: MSPAgentToolCall,
        turnID: UUID
    ) throws -> MSPGoalCreateRequest {
        guard let threadID = activeTurn?.threadID else {
            throw MSPGoalToolArgumentError.message("create_goal requires an active thread")
        }
        let objective = try requiredStringArgument("objective", from: call)
        let tokenBudget = try optionalIntArgument("token_budget", from: call)
        return MSPGoalCreateRequest(
            threadID: threadID,
            objective: objective,
            tokenBudget: tokenBudget,
            source: .modelTool,
            sourceTurnID: turnID.uuidString
        )
    }

    func updateRequest(
        from call: MSPAgentToolCall,
        turnID: UUID
    ) throws -> MSPGoalUpdateRequest {
        guard let threadID = activeTurn?.threadID ?? goal?.threadID else {
            throw MSPGoalToolArgumentError.message("update_goal requires an active thread goal")
        }
        let statusString = try requiredStringArgument("status", from: call)
        guard let status = MSPGoalStatus(rawValue: statusString) else {
            throw MSPGoalToolArgumentError.message("unsupported goal status: \(statusString)")
        }
        return MSPGoalUpdateRequest(
            threadID: threadID,
            status: status,
            source: .modelTool,
            sourceTurnID: turnID.uuidString
        )
    }

    private func requiredStringArgument(
        _ name: String,
        from call: MSPAgentToolCall
    ) throws -> String {
        guard let value = call.arguments[name]?.stringValue else {
            throw MSPGoalToolArgumentError.message("missing required argument: \(name)")
        }
        return value
    }

    private func optionalIntArgument(
        _ name: String,
        from call: MSPAgentToolCall
    ) throws -> Int? {
        guard let value = call.arguments[name], value != .null else {
            return nil
        }
        if let intValue = value.intValue {
            return intValue
        }
        throw MSPGoalToolArgumentError.message("argument \(name) must be an integer")
    }
}

private enum MSPGoalToolArgumentError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
