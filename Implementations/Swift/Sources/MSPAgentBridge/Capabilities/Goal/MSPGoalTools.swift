import Foundation

public enum MSPGoalTools {
    public static let getGoalName = "get_goal"
    public static let createGoalName = "create_goal"
    public static let updateGoalName = "update_goal"
    public static let toolNames = [getGoalName, createGoalName, updateGoalName]

    public static var modelToolDefinitions: [MSPAgentModelToolDefinition] {
        [getGoalToolDefinition, createGoalToolDefinition, updateGoalToolDefinition]
    }

    static func isGoalTool(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    static func isGoalTool(_ name: MSPAgentToolName) -> Bool {
        isGoalTool(name.rawValue)
    }

    static let getGoalToolDefinition = MSPAgentModelToolDefinition(
        name: getGoalName,
        description: "Get the current goal for this thread, including status, budgets, token and elapsed-time usage, and remaining token budget.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
            "additionalProperties": .bool(false)
        ]),
        strict: false
    )

    static let createGoalToolDefinition = MSPAgentModelToolDefinition(
        name: createGoalName,
        description: """
        Create a goal only when explicitly requested by the user or system/developer instructions; do not infer goals from ordinary tasks.
        Set token_budget only when an explicit token budget is requested. Fails if an unfinished goal exists; use update_goal only for status.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "objective": .object([
                    "type": .string("string"),
                    "description": .string("Required. The concrete objective to start pursuing.")
                ]),
                "token_budget": .object([
                    "type": .string("integer"),
                    "description": .string("Positive token budget for the new goal. Omit unless explicitly requested.")
                ])
            ]),
            "required": .array([.string("objective")]),
            "additionalProperties": .bool(false)
        ]),
        strict: false
    )

    static let updateGoalToolDefinition = MSPAgentModelToolDefinition(
        name: updateGoalName,
        description: """
        Update the existing goal.
        Use this tool only to mark the goal achieved or genuinely blocked.
        You cannot use this tool to pause, resume, budget-limit, or usage-limit a goal; those status changes are controlled by the user or system.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("complete"), .string("blocked")]),
                    "description": .string("Required. Set to complete only when achieved, or blocked only at a real impasse.")
                ])
            ]),
            "required": .array([.string("status")]),
            "additionalProperties": .bool(false)
        ]),
        strict: false
    )
}
