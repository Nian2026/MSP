import Foundation

public enum MSPUpdatePlanToolSchema {
    public static let name = "update_plan"

    public static let explanationArgumentName = "explanation"
    public static let planArgumentName = "plan"
    public static let stepArgumentName = "step"
    public static let statusArgumentName = "status"

    public static let pendingStatus = "pending"
    public static let inProgressStatus = "in_progress"
    public static let completedStatus = "completed"
    public static let statusValues = [
        pendingStatus,
        inProgressStatus,
        completedStatus
    ]

    public static let description =
        "Updates the task plan.\n"
        + "Provide an optional explanation and a list of plan items, each with a step and status.\n"
        + "At most one step can be in_progress at a time.\n"

    public static let parameters: MSPAgentJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            explanationArgumentName: .object([
                "type": .string("string"),
                "description": .string("Optional explanation for this plan update.")
            ]),
            planArgumentName: .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        stepArgumentName: .object([
                            "type": .string("string"),
                            "description": .string("Task step text.")
                        ]),
                        statusArgumentName: .object([
                            "type": .string("string"),
                            "enum": .array(statusValues.map { .string($0) }),
                            "description": .string("Step status.")
                        ])
                    ]),
                    "required": .array([
                        .string(stepArgumentName),
                        .string(statusArgumentName)
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                "description": .string("The list of steps")
            ])
        ]),
        "required": .array([.string(planArgumentName)]),
        "additionalProperties": .bool(false)
    ])
}
