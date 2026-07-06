import Foundation

public enum MSPUpdatePlanStepStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct MSPUpdatePlanItem: Codable, Hashable, Sendable {
    public var step: String
    public var status: MSPUpdatePlanStepStatus

    public init(
        step: String,
        status: MSPUpdatePlanStepStatus
    ) {
        self.step = step
        self.status = status
    }
}

public struct MSPUpdatePlanArguments: Codable, Hashable, Sendable {
    public var explanation: String?
    public var plan: [MSPUpdatePlanItem]

    public init(
        explanation: String? = nil,
        plan: [MSPUpdatePlanItem]
    ) {
        self.explanation = explanation
        self.plan = plan
    }
}

public enum MSPUpdatePlanArgumentError: Error, Equatable, CustomStringConvertible, Sendable {
    case unknownArgument(String, expected: [String])
    case missingArgument(String)
    case invalidRoot
    case invalidString(String)
    case invalidPlan
    case invalidPlanItem(Int)
    case invalidStatus(String)
    case parseFailure(String)

    public var description: String {
        switch self {
        case .unknownArgument(let key, let expected):
            return "failed to parse function arguments: unknown field `\(key)`, expected \(expectedList(expected))"
        case .missingArgument(let key):
            return "failed to parse function arguments: missing field `\(key)`"
        case .invalidRoot:
            return "failed to parse function arguments: invalid type: expected object for `update_plan` arguments"
        case .invalidString(let key):
            return "failed to parse function arguments: invalid type: expected string for `\(key)`"
        case .invalidPlan:
            return "failed to parse function arguments: invalid type: expected array for `plan`"
        case .invalidPlanItem(let index):
            return "failed to parse function arguments: invalid type: expected object for `plan[\(index)]`"
        case .invalidStatus(let status):
            return "failed to parse function arguments: unknown variant `\(status)`, expected one of `pending`, `in_progress`, `completed`"
        case .parseFailure(let message):
            return "failed to parse function arguments: \(message)"
        }
    }

    private func expectedList(_ expected: [String]) -> String {
        expected.map { "`\($0)`" }.joined(separator: " or ")
    }
}

public enum MSPUpdatePlanRuntime {
    public static let planUpdatedMessage = "Plan updated"

    public static func parseArguments(
        rawArguments: String?,
        decodedArguments: [String: MSPAgentJSONValue]
    ) throws -> MSPUpdatePlanArguments {
        guard let rawArguments else {
            return try parseArguments(decodedArguments)
        }
        return try parseArguments(rawArguments)
    }

    public static func parseArguments(
        _ rawArguments: String
    ) throws -> MSPUpdatePlanArguments {
        guard let data = rawArguments.data(using: .utf8) else {
            throw MSPUpdatePlanArgumentError.parseFailure("invalid UTF-8")
        }
        let value: MSPAgentJSONValue
        do {
            value = try JSONDecoder().decode(MSPAgentJSONValue.self, from: data)
        } catch {
            throw MSPUpdatePlanArgumentError.parseFailure(jsonErrorDescription(error))
        }
        guard let object = value.objectValue else {
            throw MSPUpdatePlanArgumentError.invalidRoot
        }
        return try parseArguments(object)
    }

    public static func parseArguments(
        _ arguments: [String: MSPAgentJSONValue]
    ) throws -> MSPUpdatePlanArguments {
        let allowedRootKeys = [
            MSPUpdatePlanToolSchema.explanationArgumentName,
            MSPUpdatePlanToolSchema.planArgumentName
        ]
        try rejectUnknownKeys(
            arguments.keys,
            allowed: allowedRootKeys
        )

        let explanation: String?
        if let explanationValue = arguments[MSPUpdatePlanToolSchema.explanationArgumentName] {
            if explanationValue == .null {
                explanation = nil
            } else if let value = explanationValue.stringValue {
                explanation = value
            } else {
                throw MSPUpdatePlanArgumentError.invalidString(
                    MSPUpdatePlanToolSchema.explanationArgumentName
                )
            }
        } else {
            explanation = nil
        }

        guard let planValue = arguments[MSPUpdatePlanToolSchema.planArgumentName] else {
            throw MSPUpdatePlanArgumentError.missingArgument(
                MSPUpdatePlanToolSchema.planArgumentName
            )
        }
        guard let planArray = planValue.arrayValue else {
            throw MSPUpdatePlanArgumentError.invalidPlan
        }

        let items = try planArray.enumerated().map { index, value in
            try parsePlanItem(value, index: index)
        }
        return MSPUpdatePlanArguments(explanation: explanation, plan: items)
    }

    public static func modelToolResult(
        call: MSPAgentToolCall
    ) -> MSPAgentToolResult {
        MSPAgentToolResult(
            callID: call.id,
            name: call.name,
            outputKind: .function,
            ok: true,
            content: .string(planUpdatedMessage),
            modelOutputContent: .string(planUpdatedMessage),
            errorMessage: nil
        )
    }

    public static func modelToolError(
        call: MSPAgentToolCall,
        message: String
    ) -> MSPAgentToolResult {
        MSPAgentToolResult(
            callID: call.id,
            name: call.name,
            outputKind: .function,
            ok: false,
            content: .string(message),
            modelOutputContent: .string(message),
            errorMessage: message
        )
    }

    private static func parsePlanItem(
        _ value: MSPAgentJSONValue,
        index: Int
    ) throws -> MSPUpdatePlanItem {
        guard let object = value.objectValue else {
            throw MSPUpdatePlanArgumentError.invalidPlanItem(index)
        }
        try rejectUnknownKeys(
            object.keys,
            allowed: [
                MSPUpdatePlanToolSchema.stepArgumentName,
                MSPUpdatePlanToolSchema.statusArgumentName
            ]
        )
        guard let step = object[MSPUpdatePlanToolSchema.stepArgumentName]?.stringValue else {
            throw object[MSPUpdatePlanToolSchema.stepArgumentName] == nil
                ? MSPUpdatePlanArgumentError.missingArgument(MSPUpdatePlanToolSchema.stepArgumentName)
                : MSPUpdatePlanArgumentError.invalidString(MSPUpdatePlanToolSchema.stepArgumentName)
        }
        guard let statusString = object[MSPUpdatePlanToolSchema.statusArgumentName]?.stringValue else {
            throw object[MSPUpdatePlanToolSchema.statusArgumentName] == nil
                ? MSPUpdatePlanArgumentError.missingArgument(MSPUpdatePlanToolSchema.statusArgumentName)
                : MSPUpdatePlanArgumentError.invalidString(MSPUpdatePlanToolSchema.statusArgumentName)
        }
        guard let status = MSPUpdatePlanStepStatus(rawValue: statusString) else {
            throw MSPUpdatePlanArgumentError.invalidStatus(statusString)
        }
        return MSPUpdatePlanItem(step: step, status: status)
    }

    private static func rejectUnknownKeys<S: Sequence>(
        _ keys: S,
        allowed: [String]
    ) throws where S.Element == String {
        let allowedSet = Set(allowed)
        if let unknownKey = keys.sorted().first(where: { !allowedSet.contains($0) }) {
            throw MSPUpdatePlanArgumentError.unknownArgument(
                unknownKey,
                expected: allowed
            )
        }
    }

    private static func jsonErrorDescription(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .dataCorrupted(let context):
                return context.debugDescription
            case .typeMismatch(_, let context):
                return context.debugDescription
            case .valueNotFound(_, let context):
                return context.debugDescription
            case .keyNotFound(let key, _):
                return "missing field `\(key.stringValue)`"
            @unknown default:
                return "\(decodingError)"
            }
        }
        return "\(error)"
    }
}
