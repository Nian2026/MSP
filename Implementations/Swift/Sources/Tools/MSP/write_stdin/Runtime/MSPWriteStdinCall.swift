import Foundation

public struct MSPWriteStdinCall: Sendable, Equatable {
    public var sessionID: Int
    public var chars: String
    public var stdinData: Data?
    public var yieldTimeMilliseconds: Int?
    public var maxOutputTokens: Int?

    public init(
        sessionID: Int,
        chars: String = "",
        stdinData: Data? = nil,
        yieldTimeMilliseconds: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.chars = chars
        self.stdinData = stdinData
        self.yieldTimeMilliseconds = yieldTimeMilliseconds
        self.maxOutputTokens = maxOutputTokens
    }

    public var stdinBytes: Data {
        stdinData ?? Data(chars.utf8)
    }

    public init(arguments: [String: String]) throws {
        try Self.validateArgumentKeys(arguments.keys)
        guard let rawSessionID = arguments[MSPWriteStdinToolSchema.sessionIDArgumentName],
              let sessionID = Int(rawSessionID),
              sessionID >= 0 else {
            throw MSPWriteStdinCallError.invalidSessionID(
                arguments[MSPWriteStdinToolSchema.sessionIDArgumentName] ?? ""
            )
        }
        self.sessionID = sessionID
        self.chars = arguments[MSPWriteStdinToolSchema.charsArgumentName] ?? ""
        self.stdinData = nil
        if let rawYieldTime = arguments[MSPWriteStdinToolSchema.yieldTimeMillisecondsArgumentName] {
            guard let parsed = Int(rawYieldTime), parsed >= 0 else {
                throw MSPWriteStdinCallError.invalidYieldTimeMilliseconds(rawYieldTime)
            }
            self.yieldTimeMilliseconds = parsed
        } else {
            self.yieldTimeMilliseconds = nil
        }
        if let rawMaxOutputTokens = arguments[MSPWriteStdinToolSchema.maxOutputTokensArgumentName] {
            guard let parsed = Int(rawMaxOutputTokens), parsed >= 0 else {
                throw MSPWriteStdinCallError.invalidMaxOutputTokens(rawMaxOutputTokens)
            }
            self.maxOutputTokens = parsed
        } else {
            self.maxOutputTokens = nil
        }
    }

    public init(arguments: [String: MSPAgentJSONValue]) throws {
        try Self.validateArgumentKeys(arguments.keys)
        guard let sessionValue = arguments[MSPWriteStdinToolSchema.sessionIDArgumentName],
              let sessionID = Self.nonNegativeIntegerArgument(sessionValue) else {
            throw MSPWriteStdinCallError.invalidSessionID(
                arguments[MSPWriteStdinToolSchema.sessionIDArgumentName]
                    .map(Self.argumentDescription) ?? ""
            )
        }
        self.sessionID = sessionID
        if let value = arguments[MSPWriteStdinToolSchema.charsArgumentName] {
            guard let chars = value.stringValue else {
                throw MSPWriteStdinCallError.invalidChars(Self.argumentDescription(value))
            }
            self.chars = chars
        } else {
            self.chars = ""
        }
        self.stdinData = nil
        if let value = arguments[MSPWriteStdinToolSchema.yieldTimeMillisecondsArgumentName] {
            guard let parsed = Self.nonNegativeIntegerArgument(value) else {
                throw MSPWriteStdinCallError.invalidYieldTimeMilliseconds(
                    Self.argumentDescription(value)
                )
            }
            self.yieldTimeMilliseconds = parsed
        } else {
            self.yieldTimeMilliseconds = nil
        }
        if let value = arguments[MSPWriteStdinToolSchema.maxOutputTokensArgumentName] {
            guard let parsed = Self.nonNegativeIntegerArgument(value) else {
                throw MSPWriteStdinCallError.invalidMaxOutputTokens(
                    Self.argumentDescription(value)
                )
            }
            self.maxOutputTokens = parsed
        } else {
            self.maxOutputTokens = nil
        }
    }

    private static let allowedArgumentKeys = Set([
        MSPWriteStdinToolSchema.sessionIDArgumentName,
        MSPWriteStdinToolSchema.charsArgumentName,
        MSPWriteStdinToolSchema.yieldTimeMillisecondsArgumentName,
        MSPWriteStdinToolSchema.maxOutputTokensArgumentName
    ])

    private static func validateArgumentKeys<S: Sequence>(_ keys: S) throws where S.Element == String {
        let sortedKeys = keys.sorted()
        guard Set(sortedKeys).isSubset(of: allowedArgumentKeys) else {
            throw MSPWriteStdinCallError.invalidArgumentKeys(sortedKeys)
        }
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

public enum MSPWriteStdinCallError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidArgumentKeys([String])
    case invalidSessionID(String)
    case invalidChars(String)
    case invalidYieldTimeMilliseconds(String)
    case invalidMaxOutputTokens(String)

    public var description: String {
        switch self {
        case .invalidArgumentKeys(let keys):
            return "write_stdin arguments contain unsupported keys, got \(keys)"
        case .invalidSessionID(let value):
            return "write_stdin session_id must be a non-negative integer, got \(value)"
        case .invalidChars(let value):
            return "write_stdin chars must be a string, got \(value)"
        case .invalidYieldTimeMilliseconds(let value):
            return "write_stdin yield_time_ms must be a non-negative integer, got \(value)"
        case .invalidMaxOutputTokens(let value):
            return "write_stdin max_output_tokens must be a non-negative integer, got \(value)"
        }
    }
}
