import Foundation

extension MSPGoalController {
    func validateCapability() throws {
        guard capability.isEnabled else {
            throw MSPGoalError.capabilityDisabled
        }
        guard capability.persistentThreadStateAvailable else {
            throw MSPGoalError.nonPersistentThread(threadID: activeTurn?.threadID ?? goal?.threadID ?? "")
        }
    }

    func validateThread(_ requested: String, _ actual: String) throws {
        guard requested == actual else {
            throw MSPGoalError.threadMismatch(expected: actual, actual: requested)
        }
        guard capability.persistentThreadStateAvailable else {
            throw MSPGoalError.nonPersistentThread(threadID: requested)
        }
    }

    func validateStoredGoalThread(_ threadID: String) throws {
        guard let goal, goal.threadID != threadID else {
            return
        }
        throw MSPGoalError.threadMismatch(expected: threadID, actual: goal.threadID)
    }

    func normalizedObjective(_ rawObjective: String) throws -> String {
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw MSPGoalError.emptyObjective
        }
        guard objective.count <= Self.maximumObjectiveCharacters else {
            throw MSPGoalError.objectiveTooLong(maxCharacters: Self.maximumObjectiveCharacters)
        }
        return objective
    }

    func validateBudget(_ budget: Int?) throws {
        if let budget, budget <= 0 {
            throw MSPGoalError.invalidTokenBudget
        }
    }

    func toolError(
        _ call: MSPAgentToolCall,
        _ message: String
    ) -> MSPAgentToolResult {
        MSPGoalRuntime.modelToolResult(
            call: call,
            ok: false,
            content: .object(["error": .string(message)]),
            errorMessage: message
        )
    }
}
