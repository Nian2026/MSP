import Foundation

public struct MSPExecCommandCall: Sendable, Equatable {
    public var cmd: String
    public var workdir: String?
    public var shell: String?
    public var tty: Bool
    public var yieldTimeMilliseconds: Int?
    public var maxOutputTokens: Int?

    public init(
        cmd: String,
        workdir: String? = nil,
        shell: String? = nil,
        tty: Bool = false,
        yieldTimeMilliseconds: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.cmd = cmd
        self.workdir = workdir
        self.shell = shell
        self.tty = tty
        self.yieldTimeMilliseconds = yieldTimeMilliseconds
        self.maxOutputTokens = maxOutputTokens
    }

    public init(arguments: [String: String]) throws {
        try Self.validateArgumentKeys(arguments.keys)
        guard let cmd = arguments[MSPExecCommandToolSchema.commandArgumentName] else {
            throw MSPExecCommandCallError.missingCommand
        }
        self.cmd = cmd
        self.workdir = arguments[MSPExecCommandToolSchema.workdirArgumentName]
        self.shell = arguments[MSPExecCommandToolSchema.shellArgumentName]
        if let rawTTY = arguments[MSPExecCommandToolSchema.ttyArgumentName] {
            switch rawTTY.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1":
                self.tty = true
            case "false", "0":
                self.tty = false
            default:
                throw MSPExecCommandCallError.invalidTTY(rawTTY)
            }
        } else {
            self.tty = false
        }
        if let rawYieldTime = arguments[MSPExecCommandToolSchema.yieldTimeMillisecondsArgumentName] {
            guard let parsed = Int(rawYieldTime), parsed >= 0 else {
                throw MSPExecCommandCallError.invalidYieldTimeMilliseconds(rawYieldTime)
            }
            self.yieldTimeMilliseconds = parsed
        } else {
            self.yieldTimeMilliseconds = nil
        }
        if let rawMaxOutputTokens = arguments[MSPExecCommandToolSchema.maxOutputTokensArgumentName] {
            guard let parsed = Int(rawMaxOutputTokens), parsed >= 0 else {
                throw MSPExecCommandCallError.invalidMaxOutputTokens(rawMaxOutputTokens)
            }
            self.maxOutputTokens = parsed
        } else {
            self.maxOutputTokens = nil
        }
    }

    public init(arguments: [String: MSPAgentJSONValue]) throws {
        try Self.validateArgumentKeys(arguments.keys)
        guard let commandValue = arguments[MSPExecCommandToolSchema.commandArgumentName] else {
            throw MSPExecCommandCallError.missingCommand
        }
        guard let cmd = commandValue.stringValue else {
            throw MSPExecCommandCallError.invalidStringArgument(
                MSPExecCommandToolSchema.commandArgumentName,
                Self.argumentDescription(commandValue)
            )
        }
        self.cmd = cmd
        self.workdir = try Self.optionalStringArgument(
            arguments[MSPExecCommandToolSchema.workdirArgumentName],
            name: MSPExecCommandToolSchema.workdirArgumentName
        )
        self.shell = try Self.optionalStringArgument(
            arguments[MSPExecCommandToolSchema.shellArgumentName],
            name: MSPExecCommandToolSchema.shellArgumentName
        )
        if let value = arguments[MSPExecCommandToolSchema.ttyArgumentName] {
            guard case let .bool(parsed) = value else {
                throw MSPExecCommandCallError.invalidTTY(Self.argumentDescription(value))
            }
            self.tty = parsed
        } else {
            self.tty = false
        }
        if let value = arguments[MSPExecCommandToolSchema.yieldTimeMillisecondsArgumentName] {
            guard let parsed = Self.nonNegativeIntegerArgument(value) else {
                throw MSPExecCommandCallError.invalidYieldTimeMilliseconds(
                    Self.argumentDescription(value)
                )
            }
            self.yieldTimeMilliseconds = parsed
        } else {
            self.yieldTimeMilliseconds = nil
        }
        if let value = arguments[MSPExecCommandToolSchema.maxOutputTokensArgumentName] {
            guard let parsed = Self.nonNegativeIntegerArgument(value) else {
                throw MSPExecCommandCallError.invalidMaxOutputTokens(
                    Self.argumentDescription(value)
                )
            }
            self.maxOutputTokens = parsed
        } else {
            self.maxOutputTokens = nil
        }
    }

    private static let allowedArgumentKeys = Set([
        MSPExecCommandToolSchema.commandArgumentName,
        MSPExecCommandToolSchema.workdirArgumentName,
        MSPExecCommandToolSchema.shellArgumentName,
        MSPExecCommandToolSchema.ttyArgumentName,
        MSPExecCommandToolSchema.yieldTimeMillisecondsArgumentName,
        MSPExecCommandToolSchema.maxOutputTokensArgumentName
    ])

    private static func validateArgumentKeys<S: Sequence>(_ keys: S) throws where S.Element == String {
        let sortedKeys = keys.sorted()
        guard Set(sortedKeys).isSubset(of: allowedArgumentKeys) else {
            throw MSPExecCommandCallError.invalidArgumentKeys(sortedKeys)
        }
    }

    private static func optionalStringArgument(
        _ value: MSPAgentJSONValue?,
        name: String
    ) throws -> String? {
        guard let value else {
            return nil
        }
        guard let string = value.stringValue else {
            throw MSPExecCommandCallError.invalidStringArgument(
                name,
                argumentDescription(value)
            )
        }
        return string
    }

    private static func nonNegativeIntegerArgument(_ value: MSPAgentJSONValue) -> Int? {
        guard case let .number(number) = value,
              number.isFinite,
              number >= 0,
              number.rounded(.towardZero) == number,
              number <= Double(Int.max)
        else {
            return nil
        }
        return Int(number)
    }

    private static func argumentDescription(_ value: MSPAgentJSONValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return "\(number)"
        case .bool(let bool):
            return "\(bool)"
        case .object:
            return "object"
        case .array:
            return "array"
        case .null:
            return "null"
        }
    }
}

public enum MSPExecCommandCallError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidArgumentKeys([String])
    case missingCommand
    case invalidStringArgument(String, String)
    case invalidTTY(String)
    case invalidYieldTimeMilliseconds(String)
    case invalidMaxOutputTokens(String)

    public var description: String {
        switch self {
        case .invalidArgumentKeys(let keys):
            return "exec_command arguments contain unsupported keys, got \(keys)"
        case .missingCommand:
            return "exec_command arguments missing cmd"
        case .invalidStringArgument(let name, let value):
            return "exec_command \(name) must be a string, got \(value)"
        case .invalidTTY(let value):
            return "exec_command tty must be a boolean, got \(value)"
        case .invalidYieldTimeMilliseconds(let value):
            return "exec_command yield_time_ms must be a non-negative integer, got \(value)"
        case .invalidMaxOutputTokens(let value):
            return "exec_command max_output_tokens must be a non-negative integer, got \(value)"
        }
    }
}
