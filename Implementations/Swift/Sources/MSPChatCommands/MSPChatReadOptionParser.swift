import MSPCore

struct MSPChatReadOptions: Equatable, Sendable {
    enum Scope: String, Codable, Equatable, Sendable {
        case recent
        case full
    }

    enum Format: Equatable, Sendable {
        case markdown
        case json
    }

    static let defaultMaxOutputCharsPerItem = 12_000
    static let defaultRecentTurnLimit = 5

    var scope: Scope = .full
    var cursor: String?
    var turnLimit: Int?
    var includeOutputs = true
    var maxOutputCharsPerItem: Int? = Self.defaultMaxOutputCharsPerItem
    var format: Format = .markdown
}

enum MSPChatReadOptionParser {
    static func parse(
        _ arguments: [String],
        command: String
    ) throws -> (options: MSPChatReadOptions, positionals: [String]) {
        var options = MSPChatReadOptions()
        var positionals: [String] = []
        var index = 0

        func value(after option: String) throws -> String {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw MSPCommandFailure.usage("\(command): \(option) requires a value\n")
            }
            return arguments[nextIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--scope" {
                options.scope = try parseScope(value(after: argument), command: command)
                index += 1
            } else if argument.hasPrefix("--scope=") {
                options.scope = try parseScope(String(argument.dropFirst("--scope=".count)), command: command)
            } else if argument == "--cursor" {
                options.cursor = try value(after: argument)
                index += 1
            } else if argument.hasPrefix("--cursor=") {
                options.cursor = String(argument.dropFirst("--cursor=".count))
            } else if argument == "--turn-limit" || argument == "--turnLimit" {
                options.turnLimit = try parsePositiveInt(value(after: argument), option: argument, command: command)
                index += 1
            } else if argument.hasPrefix("--turn-limit=") {
                options.turnLimit = try parsePositiveInt(
                    String(argument.dropFirst("--turn-limit=".count)),
                    option: "--turn-limit",
                    command: command
                )
            } else if argument.hasPrefix("--turnLimit=") {
                options.turnLimit = try parsePositiveInt(
                    String(argument.dropFirst("--turnLimit=".count)),
                    option: "--turnLimit",
                    command: command
                )
            } else if argument == "--include-outputs" || argument == "--includeOutputs" {
                options.includeOutputs = true
            } else if argument == "--no-outputs"
                || argument == "--no-include-outputs"
                || argument == "--noIncludeOutputs" {
                options.includeOutputs = false
            } else if argument.hasPrefix("--include-outputs=") {
                options.includeOutputs = try parseBool(
                    String(argument.dropFirst("--include-outputs=".count)),
                    option: "--include-outputs",
                    command: command
                )
            } else if argument.hasPrefix("--includeOutputs=") {
                options.includeOutputs = try parseBool(
                    String(argument.dropFirst("--includeOutputs=".count)),
                    option: "--includeOutputs",
                    command: command
                )
            } else if argument == "--max-output-chars-per-item" || argument == "--maxOutputCharsPerItem" {
                options.maxOutputCharsPerItem = try parseNonNegativeInt(value(after: argument), option: argument, command: command)
                index += 1
            } else if argument.hasPrefix("--max-output-chars-per-item=") {
                options.maxOutputCharsPerItem = try parseNonNegativeInt(
                    String(argument.dropFirst("--max-output-chars-per-item=".count)),
                    option: "--max-output-chars-per-item",
                    command: command
                )
            } else if argument.hasPrefix("--maxOutputCharsPerItem=") {
                options.maxOutputCharsPerItem = try parseNonNegativeInt(
                    String(argument.dropFirst("--maxOutputCharsPerItem=".count)),
                    option: "--maxOutputCharsPerItem",
                    command: command
                )
            } else if argument == "--json" {
                options.format = .json
            } else if argument.hasPrefix("-") {
                throw MSPCommandFailure.usage("\(command): unsupported option \(argument)\n")
            } else {
                positionals.append(argument)
            }
            index += 1
        }

        return (options, positionals)
    }

    private static func parseScope(
        _ value: String,
        command: String
    ) throws -> MSPChatReadOptions.Scope {
        guard let scope = MSPChatReadOptions.Scope(rawValue: value) else {
            throw MSPCommandFailure.usage("\(command): --scope must be full or recent\n")
        }
        return scope
    }

    private static func parsePositiveInt(
        _ value: String,
        option: String,
        command: String
    ) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw MSPCommandFailure.usage("\(command): \(option) must be a positive integer\n")
        }
        return parsed
    }

    private static func parseNonNegativeInt(
        _ value: String,
        option: String,
        command: String
    ) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw MSPCommandFailure.usage("\(command): \(option) must be a non-negative integer\n")
        }
        return parsed
    }

    private static func parseBool(
        _ value: String,
        option: String,
        command: String
    ) throws -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            throw MSPCommandFailure.usage("\(command): \(option) must be true or false\n")
        }
    }
}
