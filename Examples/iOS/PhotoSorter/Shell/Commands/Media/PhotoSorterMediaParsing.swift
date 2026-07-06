import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    static func parseMediaOptions(
        _ arguments: [String],
        optionHandler: (_ option: String, _ value: String?, _ index: Int) throws -> Int?,
        operandHandler: (_ operand: String) throws -> Void
    ) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("-") else {
                try operandHandler(argument)
                continue
            }
            let option = optionParts(argument)
            if let consumed = try optionHandler(option.name, option.value, index) {
                index += consumed
                continue
            }
            throw PhotoSorterMediaUsageError(message: "unsupported option \(argument)")
        }
    }

    static func parsePathOptions(
        _ arguments: [String],
        commandName: String,
        defaultLimit _: Int?,
        allowsInlinePaths: Bool,
        format: inout PhotoSorterMediaShowFormat,
        rawPaths: inout [String],
        pathListFile: inout String?,
        limit: inout Int?
    ) throws {
        try parseMediaOptions(arguments) { option, value, index in
            switch option {
            case "--from-file":
                pathListFile = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--limit":
                limit = try parsePositiveInt(
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--format":
                format = try parseEnum(
                    PhotoSorterMediaShowFormat.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            default:
                return nil
            }
        } operandHandler: { operand in
            guard allowsInlinePaths else {
                throw PhotoSorterMediaUsageError(message: "\(commandName): use --from-file <path-list>")
            }
            rawPaths.append(operand)
        }
        guard pathListFile != nil || !rawPaths.isEmpty else {
            throw PhotoSorterMediaUsageError(message: "\(commandName): missing path operand")
        }
    }

    static func optionParts(_ argument: String) -> (name: String, value: String?) {
        if let equals = argument.firstIndex(of: "=") {
            return (
                String(argument[..<equals]),
                String(argument[argument.index(after: equals)...])
            )
        }
        return (argument, nil)
    }

    static func requiredOptionValue(
        _ value: String?,
        _ arguments: [String],
        _ index: Int,
        _ option: String
    ) throws -> String {
        if let value {
            guard !value.isEmpty else {
                throw PhotoSorterMediaUsageError(message: "\(option): missing value")
            }
            return value
        }
        guard index < arguments.count, !arguments[index].hasPrefix("-") else {
            throw PhotoSorterMediaUsageError(message: "\(option): missing value")
        }
        return arguments[index]
    }

    static func parsePositiveInt(_ value: String, option: String) throws -> Int {
        guard let intValue = Int(value), intValue > 0 else {
            throw PhotoSorterMediaUsageError(message: "\(option): expected positive integer")
        }
        return intValue
    }

    static func parseNonNegativeInt(_ value: String, option: String) throws -> Int {
        guard let intValue = Int(value), intValue >= 0 else {
            throw PhotoSorterMediaUsageError(message: "\(option): expected non-negative integer")
        }
        return intValue
    }

    static func parseEnum<T: RawRepresentable>(
        _ type: T.Type,
        _ value: String,
        option: String
    ) throws -> T where T.RawValue == String {
        guard let parsed = type.init(rawValue: value) else {
            throw PhotoSorterMediaUsageError(message: "\(option): unsupported value \(value)")
        }
        return parsed
    }

    static func parseListArguments(_ arguments: [String]) throws -> PhotoSorterMediaListArguments {
        var parsed = PhotoSorterMediaListArguments()
        var operands: [String] = []
        try parseMediaOptions(arguments) { option, value, index in
            switch option {
            case "--scope":
                parsed.scopePath = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--offset":
                parsed.offset = try parseNonNegativeInt(
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--limit":
                parsed.limit = try parsePositiveInt(
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--sort":
                parsed.sort = try parseEnum(
                    PhotoSorterMediaListSort.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--order":
                parsed.order = try parseEnum(
                    PhotoSorterMediaListOrder.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--type":
                parsed.mediaType = try parseEnum(
                    PhotoSorterMediaType.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--format":
                parsed.format = try parseEnum(
                    PhotoSorterMediaListFormat.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            default:
                return nil
            }
        } operandHandler: { operand in
            operands.append(operand)
        }
        if operands.count > 1 {
            throw PhotoSorterMediaUsageError(message: "media list: too many path operands")
        }
        if let scopePath = operands.first {
            parsed.scopePath = scopePath
        }
        return parsed
    }

    static func parseShowArguments(
        _ arguments: [String],
        commandName: String
    ) throws -> PhotoSorterMediaShowArguments {
        var parsed = PhotoSorterMediaShowArguments()
        try parsePathOptions(
            arguments,
            commandName: commandName,
            defaultLimit: nil,
            allowsInlinePaths: true,
            format: &parsed.format,
            rawPaths: &parsed.rawPaths,
            pathListFile: &parsed.pathListFile,
            limit: &parsed.limit
        )
        return parsed
    }

    static func parsePathListArguments(
        _ arguments: [String],
        commandName: String,
        defaultLimit: Int?,
        allowsInlinePaths: Bool
    ) throws -> PhotoSorterMediaPathListArguments {
        var parsed = PhotoSorterMediaPathListArguments(limit: defaultLimit)
        var ignoredFormat = PhotoSorterMediaShowFormat.text
        try parsePathOptions(
            arguments,
            commandName: commandName,
            defaultLimit: defaultLimit,
            allowsInlinePaths: allowsInlinePaths,
            format: &ignoredFormat,
            rawPaths: &parsed.rawPaths,
            pathListFile: &parsed.pathListFile,
            limit: &parsed.limit
        )
        return parsed
    }

    static func parseAskArguments(
        _ arguments: [String],
        commandName: String,
        defaultLimit: Int?,
        allowsInlinePaths: Bool
    ) throws -> PhotoSorterMediaAskArguments {
        var parsed = PhotoSorterMediaAskArguments(limit: defaultLimit)
        try parseMediaOptions(arguments) { option, value, index in
            switch option {
            case "--from-file":
                parsed.pathListFile = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--from-jsonl":
                parsed.jsonlFile = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--limit":
                parsed.limit = try parsePositiveInt(
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--message":
                let message = try requiredOptionValue(value, arguments, index, option)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                parsed.message = message.isEmpty ? nil : message
                return value == nil ? 1 : 0
            case "--write-selected":
                parsed.writeSelectedPath = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--write-excluded":
                parsed.writeExcludedPath = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--write-skipped":
                parsed.writeSkippedPath = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            default:
                return nil
            }
        } operandHandler: { operand in
            guard allowsInlinePaths else {
                throw PhotoSorterMediaUsageError(message: "\(commandName): use --from-file <path-list>")
            }
            parsed.rawPaths.append(operand)
        }
        if parsed.jsonlFile != nil, parsed.pathListFile != nil || !parsed.rawPaths.isEmpty {
            throw PhotoSorterMediaUsageError(
                message: "\(commandName): --from-jsonl cannot be combined with --from-file or path operands"
            )
        }
        guard parsed.jsonlFile != nil || parsed.pathListFile != nil || !parsed.rawPaths.isEmpty else {
            throw PhotoSorterMediaUsageError(message: "\(commandName): missing path operand")
        }
        return parsed
    }

    static func parseStatsArguments(_ arguments: [String]) throws -> PhotoSorterMediaStatsArguments {
        var parsed = PhotoSorterMediaStatsArguments()
        var operands: [String] = []
        try parseMediaOptions(arguments) { option, value, index in
            switch option {
            case "--scope":
                parsed.scopePath = try requiredOptionValue(value, arguments, index, option)
                return value == nil ? 1 : 0
            case "--type":
                parsed.mediaType = try parseEnum(
                    PhotoSorterMediaType.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--group-by":
                parsed.groupBy = try parseEnum(
                    PhotoSorterMediaStatsGroup.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--date", "--date-field":
                parsed.dateField = try parseEnum(
                    PhotoSorterMediaStatsDateField.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            case "--format":
                parsed.format = try parseEnum(
                    PhotoSorterMediaStatsFormat.self,
                    requiredOptionValue(value, arguments, index, option),
                    option: option
                )
                return value == nil ? 1 : 0
            default:
                return nil
            }
        } operandHandler: { operand in
            operands.append(operand)
        }
        if operands.count > 1 {
            throw PhotoSorterMediaUsageError(message: "media stats: too many path operands")
        }
        if let scopePath = operands.first {
            parsed.scopePath = scopePath
        }
        return parsed
    }

    static func parseSearchArguments(
        _ arguments: [String],
        commandName: String
    ) throws -> PhotoSorterMediaSearchArguments {
        let helpTopic = commandName.hasSuffix("--vlm") ? "search --vlm" : "search --ocr"
        let usage = "\(commandName): usage: \(commandName) <keyword> <path>... | \(commandName) <keyword> --from-file <path-list> | \(commandName) --regex <pattern> --from-file <path-list>\nTry 'media help \(helpTopic)' for more information."
        guard let firstArgument = arguments.first else {
            throw PhotoSorterMediaSearchUsageError(message: usage)
        }
        let mode: PhotoSorterMediaSearchMode
        var index: Int
        if firstArgument == "--regex" {
            guard arguments.count >= 2 else {
                throw PhotoSorterMediaSearchUsageError(message: usage)
            }
            let pattern = arguments[1]
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                mode = .regex(pattern: pattern, regex: regex)
                index = 2
            } catch {
                throw PhotoSorterMediaSearchUsageError(
                    message: "\(commandName): invalid regex: \(error.localizedDescription)"
                )
            }
        } else if firstArgument.hasPrefix("-") {
            throw PhotoSorterMediaSearchUsageError(
                message: "\(commandName): unsupported option \(firstArgument)\nTry 'media help \(helpTopic)' for more information."
            )
        } else if !firstArgument.isEmpty {
            mode = .keyword(firstArgument)
            index = 1
        } else {
            throw PhotoSorterMediaSearchUsageError(message: usage)
        }
        var parsed = PhotoSorterMediaSearchArguments(mode: mode, rawPaths: [])
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("-") else {
                parsed.rawPaths.append(argument)
                continue
            }
            let option = Self.optionParts(argument)
            switch option.name {
            case "--from-file":
                parsed.pathListFile = try requiredOptionValue(option.value, arguments, index, option.name)
                if option.value == nil { index += 1 }
            case "--limit":
                parsed.limit = try parsePositiveInt(
                    requiredOptionValue(option.value, arguments, index, option.name),
                    option: option.name
                )
                if option.value == nil { index += 1 }
            case "--format":
                parsed.format = try parseEnum(
                    PhotoSorterMediaSearchFormat.self,
                    requiredOptionValue(option.value, arguments, index, option.name),
                    option: option.name
                )
                if option.value == nil { index += 1 }
            default:
                throw PhotoSorterMediaSearchUsageError(
                    message: "\(commandName): unsupported option \(argument)\nTry 'media help \(helpTopic)' for more information."
                )
            }
        }
        guard parsed.pathListFile != nil || !parsed.rawPaths.isEmpty else {
            throw PhotoSorterMediaSearchUsageError(message: usage)
        }
        return parsed
    }
}
