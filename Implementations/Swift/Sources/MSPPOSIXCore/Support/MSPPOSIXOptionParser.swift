import MSPCore

struct MSPPOSIXParsedArguments {
    var options: [MSPPOSIXOption]
    var operands: [String]
}

struct MSPPOSIXOption: Equatable {
    enum Name: Equatable {
        case short(Character)
        case long(String)
    }

    var name: Name
    var value: String?
}

struct MSPPOSIXCommandSpec {
    var name: String
    var allowedShortOptions: Set<Character>
    var allowedLongOptions: Set<String>
    var shortOptionsRequiringValue: Set<Character>
    var longOptionsRequiringValue: Set<String>
    var shortOptionsWithOptionalValue: Set<Character>
    var longOptionsWithOptionalValue: Set<String>
    var unsupportedOptionAdjective: String

    init(
        name: String,
        allowedShortOptions: Set<Character> = [],
        allowedLongOptions: Set<String> = [],
        shortOptionsRequiringValue: Set<Character> = [],
        longOptionsRequiringValue: Set<String> = [],
        shortOptionsWithOptionalValue: Set<Character> = [],
        longOptionsWithOptionalValue: Set<String> = [],
        unsupportedOptionAdjective: String = "unsupported"
    ) {
        self.name = name
        self.allowedShortOptions = allowedShortOptions
            .union(shortOptionsRequiringValue)
            .union(shortOptionsWithOptionalValue)
        self.allowedLongOptions = allowedLongOptions
            .union(longOptionsRequiringValue)
            .union(longOptionsWithOptionalValue)
        self.shortOptionsRequiringValue = shortOptionsRequiringValue
        self.longOptionsRequiringValue = longOptionsRequiringValue
        self.shortOptionsWithOptionalValue = shortOptionsWithOptionalValue
        self.longOptionsWithOptionalValue = longOptionsWithOptionalValue
        self.unsupportedOptionAdjective = unsupportedOptionAdjective
    }

    func parse(
        _ arguments: [String],
        stopAtFirstOperand: Bool = false,
        treatNegativeNumbersAsOperands: Bool = false
    ) throws -> MSPPOSIXParsedArguments {
        let parsed = try MSPPOSIXOptionParser.parse(
            arguments,
            command: name,
            shortOptionsRequiringValue: shortOptionsRequiringValue,
            longOptionsRequiringValue: longOptionsRequiringValue,
            shortOptionsWithOptionalValue: shortOptionsWithOptionalValue,
            longOptionsWithOptionalValue: longOptionsWithOptionalValue,
            stopAtFirstOperand: stopAtFirstOperand,
            treatNegativeNumbersAsOperands: treatNegativeNumbersAsOperands
        )
        for option in parsed.options {
            switch option.name {
            case .short(let value):
                guard allowedShortOptions.contains(value) else {
                    throw MSPCommandFailure.usage(
                        "\(MSPPOSIXOptionParser.unsupportedOptionMessage(command: name, option: option, adjective: unsupportedOptionAdjective))\n"
                    )
                }
            case .long(let value):
                guard allowedLongOptions.contains(value) else {
                    throw MSPCommandFailure.usage(
                        "\(MSPPOSIXOptionParser.unsupportedOptionMessage(command: name, option: option, adjective: unsupportedOptionAdjective))\n"
                    )
                }
            }
        }
        return parsed
    }

    func requireOperandCount(
        _ operands: [String],
        min: Int = 0,
        max: Int? = nil
    ) throws {
        if operands.count < min {
            throw MSPCommandFailure.usage("\(name): missing operand\n")
        }
        if let max, operands.count > max {
            throw MSPCommandFailure.usage("\(name): too many operands\n")
        }
    }
}

enum MSPPOSIXOptionParser {
    static func parse(
        _ arguments: [String],
        command: String,
        shortOptionsRequiringValue: Set<Character> = [],
        longOptionsRequiringValue: Set<String> = [],
        shortOptionsWithOptionalValue: Set<Character> = [],
        longOptionsWithOptionalValue: Set<String> = [],
        stopAtFirstOperand: Bool = false,
        treatNegativeNumbersAsOperands: Bool = false
    ) throws -> MSPPOSIXParsedArguments {
        var options: [MSPPOSIXOption] = []
        var operands: [String] = []
        var parsingOptions = true
        var index = 0

        func requireNextValue(for displayName: String) throws -> String {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw MSPCommandFailure.usage("\(command): option requires an argument -- \(displayName)\n")
            }
            index = nextIndex
            return arguments[nextIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if !parsingOptions {
                operands.append(argument)
                index += 1
                continue
            }

            if argument == "--" {
                parsingOptions = false
                index += 1
                continue
            }

            if treatNegativeNumbersAsOperands, isNegativeNumericOperand(argument) {
                operands.append(argument)
                if stopAtFirstOperand {
                    operands.append(contentsOf: arguments.dropFirst(index + 1))
                    break
                }
                index += 1
                continue
            }

            if argument.hasPrefix("--"), argument.count > 2 {
                let rawBody = String(argument.dropFirst(2))
                let parts = rawBody.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                var value = parts.count == 2 ? String(parts[1]) : nil
                if longOptionsRequiringValue.contains(name), value == nil {
                    value = try requireNextValue(for: name)
                }
                options.append(MSPPOSIXOption(name: .long(name), value: value))
                index += 1
                continue
            }

            if argument.hasPrefix("-"), argument != "-" {
                let characters = Array(argument.dropFirst())
                var characterIndex = 0
                while characterIndex < characters.count {
                    let option = characters[characterIndex]
                    if shortOptionsRequiringValue.contains(option) || shortOptionsWithOptionalValue.contains(option) {
                        var value = String(characters[(characterIndex + 1)...])
                        if value.hasPrefix("="), shortOptionsWithOptionalValue.contains(option) {
                            value.removeFirst()
                        }
                        if value.isEmpty, shortOptionsRequiringValue.contains(option) {
                            value = try requireNextValue(for: String(option))
                        }
                        options.append(MSPPOSIXOption(
                            name: .short(option),
                            value: value.isEmpty && shortOptionsWithOptionalValue.contains(option) ? nil : value
                        ))
                        characterIndex = characters.count
                    } else {
                        options.append(MSPPOSIXOption(name: .short(option), value: nil))
                        characterIndex += 1
                    }
                }
                index += 1
                continue
            }

            operands.append(argument)
            if stopAtFirstOperand {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            index += 1
        }

        return MSPPOSIXParsedArguments(options: options, operands: operands)
    }

    static func unsupportedOptionMessage(
        command: String,
        option: MSPPOSIXOption,
        adjective: String = "unsupported"
    ) -> String {
        switch option.name {
        case .short(let name):
            return "\(command): \(adjective) option -- \(name)"
        case .long(let name):
            return "\(command): \(adjective) option -- \(name)"
        }
    }

    static func optionDisplayName(_ option: MSPPOSIXOption) -> String {
        switch option.name {
        case .short(let name):
            return "-\(name)"
        case .long(let name):
            return "--\(name)"
        }
    }

    private static func isNegativeNumericOperand(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), argument != "-" else {
            return false
        }
        return Double(argument) != nil
    }
}

extension MSPPOSIXOption {
    func matches(short: Character? = nil, long: String? = nil) -> Bool {
        switch name {
        case .short(let value):
            return value == short
        case .long(let value):
            return value == long
        }
    }
}
