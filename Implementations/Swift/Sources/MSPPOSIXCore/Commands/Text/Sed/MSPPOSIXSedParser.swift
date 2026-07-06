import Foundation

enum MSPPOSIXSedParser {
    private static let invocationSpec = MSPPOSIXCommandSpec(
        name: "sed",
        allowedShortOptions: ["n", "i", "E", "r"],
        allowedLongOptions: ["quiet", "silent", "in-place", "regexp-extended"],
        shortOptionsRequiringValue: ["e", "f"],
        longOptionsRequiringValue: ["expression", "file"]
    )

    static func parseInvocation(_ arguments: [String]) throws -> MSPPOSIXSedInvocation {
        var suppressAutomaticPrint = false
        var inPlace = false
        var extendedRegex = false
        var scriptSources: [MSPPOSIXSedScriptSource] = []
        let parsed = try invocationSpec.parse(arguments)
        for option in parsed.options {
            switch option.name {
            case .short("n"), .long("quiet"), .long("silent"):
                suppressAutomaticPrint = true
            case .short("i"), .long("in-place"):
                inPlace = true
            case .short("E"), .short("r"), .long("regexp-extended"):
                extendedRegex = true
            case .short("e"), .long("expression"):
                guard let script = option.value else {
                    throw MSPPOSIXSedError.usage("sed: \(MSPPOSIXOptionParser.optionDisplayName(option)) requires a script")
                }
                scriptSources.append(.expression(script))
            case .short("f"), .long("file"):
                guard let path = option.value else {
                    throw MSPPOSIXSedError.usage("sed: \(MSPPOSIXOptionParser.optionDisplayName(option)) requires a file")
                }
                scriptSources.append(.file(path))
            default:
                throw MSPPOSIXSedError.usage(MSPPOSIXOptionParser.unsupportedOptionMessage(command: "sed", option: option))
            }
        }
        var paths = parsed.operands
        if scriptSources.isEmpty, !paths.isEmpty {
            scriptSources.append(.expression(paths.removeFirst()))
        }
        guard !scriptSources.isEmpty else {
            throw MSPPOSIXSedError.usage("sed: missing script")
        }
        return MSPPOSIXSedInvocation(
            suppressAutomaticPrint: suppressAutomaticPrint,
            inPlace: inPlace,
            extendedRegex: extendedRegex,
            scriptSources: scriptSources,
            paths: paths
        )
    }

    static func parseSubstitution(_ script: String, extendedRegex: Bool) throws -> MSPPOSIXSedSubstitution? {
        guard script.first == "s", script.count >= 2 else { return nil }
        let delimiterIndex = script.index(after: script.startIndex)
        let delimiter = script[delimiterIndex]
        var index = script.index(after: delimiterIndex)
        guard let pattern = readSubstitutionField(
            in: script,
            delimiter: delimiter,
            index: &index,
            regex: true
        ),
              let replacement = readSubstitutionField(
                in: script,
                delimiter: delimiter,
                index: &index,
                regex: false
              )
        else {
            throw MSPPOSIXSedError.usage(
                "sed: -e expression #1, char \(script.utf8.count): unterminated `s' command"
            )
        }
        let flags = try parseSubstitutionFlags(String(script[index...]))
        return MSPPOSIXSedSubstitution(
            pattern: pattern,
            replacement: replacement,
            global: flags.global,
            occurrence: flags.occurrence,
            print: flags.print,
            caseInsensitive: flags.caseInsensitive,
            extendedRegex: extendedRegex
        )
    }

    static func parseProgramCommands(_ scriptCommands: [String], extendedRegex: Bool) throws -> [MSPPOSIXSedProgramCommand] {
        try scriptCommands.map { rawCommand in
            let trimmed = rawCommand.trimmingCharacters(in: .whitespaces)
            let addressParse = try MSPPOSIXSedAddressParser.parseAddressPrefix(trimmed, extendedRegex: extendedRegex)
            var rest = addressParse.rest.trimmingCharacters(in: .whitespaces)
            var negated = false
            if rest.first == "!" {
                negated = true
                rest.removeFirst()
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            guard let command = rest.first else {
                throw MSPPOSIXSedError.usage("sed: missing command")
            }
            func node(_ kind: MSPPOSIXSedProgramKind) -> MSPPOSIXSedProgramCommand {
                MSPPOSIXSedProgramCommand(
                    start: addressParse.start,
                    end: addressParse.end,
                    negated: negated,
                    kind: kind
                )
            }
            switch command {
            case "s":
                guard let substitution = try parseSubstitution(rest, extendedRegex: extendedRegex) else {
                    throw MSPPOSIXSedError.usage("sed: invalid substitute command")
                }
                return node(.substitution(substitution))
            case "p":
                return node(.print)
            case "l":
                return node(.list)
            case "q":
                return node(.quit)
            case "d":
                return node(.delete)
            case "a":
                return node(.append(sedTextArgument(after: command, in: rest)))
            case "i":
                return node(.insert(sedTextArgument(after: command, in: rest)))
            case "c":
                return node(.change(sedTextArgument(after: command, in: rest)))
            case "h":
                return node(.hold)
            case "H":
                return node(.holdAppend)
            case "g":
                return node(.get)
            case "G":
                return node(.getAppend)
            case "x":
                return node(.exchange)
            case ":":
                let label = sedLabelArgument(after: command, in: rest)
                guard let label, !label.isEmpty else {
                    throw MSPPOSIXSedError.usage("sed: missing label")
                }
                return node(.label(label))
            case "b":
                return node(.branch(sedLabelArgument(after: command, in: rest)))
            case "t":
                return node(.branchIfSubstitution(sedLabelArgument(after: command, in: rest)))
            case "{":
                let nestedCommands = try parseProgramCommands(
                    splitScriptCommands(groupBody(from: rest)),
                    extendedRegex: extendedRegex
                )
                return node(.group(nestedCommands))
            default:
                throw MSPPOSIXSedError.usage("sed: unsupported command '\(command)'")
            }
        }
    }

    static func splitScriptCommands(_ script: String) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var index = script.startIndex
        var escaped = false
        var regexAddressOpen = false
        var substitutionDelimiter: Character?
        var substitutionDelimiterCount = 0
        var groupDepth = 0

        while index < script.endIndex {
            let character = script[index]
            if escaped {
                current.append(character)
                escaped = false
                index = script.index(after: index)
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                index = script.index(after: index)
                continue
            }
            if let delimiter = substitutionDelimiter {
                current.append(character)
                if character == delimiter {
                    substitutionDelimiterCount += 1
                    if substitutionDelimiterCount == 3 {
                        substitutionDelimiter = nil
                    }
                }
                index = script.index(after: index)
                continue
            }
            if canStartSubstitutionCommand(after: current),
               character == "s" {
                let delimiterIndex = script.index(after: index)
                if delimiterIndex < script.endIndex {
                    current.append(character)
                    current.append(script[delimiterIndex])
                    substitutionDelimiter = script[delimiterIndex]
                    substitutionDelimiterCount = 1
                    index = script.index(after: delimiterIndex)
                    continue
                }
            }
            if character == "/", regexAddressOpen || canStartRegexAddress(after: current) {
                regexAddressOpen.toggle()
                current.append(character)
                index = script.index(after: index)
                continue
            }
            if character == "{", !regexAddressOpen {
                groupDepth += 1
                current.append(character)
                index = script.index(after: index)
                continue
            }
            if character == "}", !regexAddressOpen {
                guard groupDepth > 0 else {
                    throw MSPPOSIXSedError.usage("sed: unmatched '}'")
                }
                groupDepth -= 1
                current.append(character)
                index = script.index(after: index)
                continue
            }
            if (character == ";" || character == "\n"), !regexAddressOpen, groupDepth == 0 {
                parts.append(current)
                current = ""
                index = script.index(after: index)
                continue
            }
            current.append(character)
            index = script.index(after: index)
        }
        guard !regexAddressOpen else {
            throw MSPPOSIXSedError.usage("sed: unterminated address regex")
        }
        if substitutionDelimiter != nil {
            throw MSPPOSIXSedError.usage(
                "sed: -e expression #1, char \(script.utf8.count): unterminated `s' command"
            )
        }
        if groupDepth != 0 {
            throw MSPPOSIXSedError.usage("sed: unmatched '{'")
        }
        parts.append(current)
        return parts.filter { command in
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
    }

    private static func sedTextArgument(after command: Character, in rest: String) -> String {
        var text = String(rest.dropFirst())
        if text.first == "\\" {
            text.removeFirst()
        }
        if text.first == " " || text.first == "\t" {
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func sedLabelArgument(after command: Character, in rest: String) -> String? {
        let label = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    private static func groupBody(from rest: String) throws -> String {
        var text = rest.trimmingCharacters(in: .whitespaces)
        guard text.first == "{" else {
            throw MSPPOSIXSedError.usage("sed: unmatched '{'")
        }
        text.removeFirst()
        guard text.last == "}" else {
            throw MSPPOSIXSedError.usage("sed: unmatched '{'")
        }
        text.removeLast()
        return text
    }

    private static func canStartSubstitutionCommand(after currentCommand: String) -> Bool {
        let trimmed = currentCommand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let parsed = try? MSPPOSIXSedAddressParser.parseAddressPrefix(trimmed, extendedRegex: false) else {
            return false
        }
        let rest = parsed.rest.trimmingCharacters(in: .whitespaces)
        return parsed.start != nil && (rest.isEmpty || rest == "!")
    }

    private static func canStartRegexAddress(after currentCommand: String) -> Bool {
        let trimmed = currentCommand.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasSuffix(",")
    }

    private static func readSubstitutionField(
        in script: String,
        delimiter: Character,
        index: inout String.Index,
        regex: Bool
    ) -> String? {
        var field = ""
        var escaped = false
        while index < script.endIndex {
            let character = script[index]
            if escaped {
                field.append("\\")
                field.append(character)
                escaped = false
                index = script.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = script.index(after: index)
                continue
            }
            if character == delimiter {
                index = script.index(after: index)
                return field
            }
            if regex, character == "[" {
                guard appendBracketExpression(from: script, index: &index, to: &field) else {
                    return nil
                }
                continue
            }
            field.append(character)
            index = script.index(after: index)
        }
        return nil
    }

    private static func appendBracketExpression(
        from script: String,
        index: inout String.Index,
        to field: inout String
    ) -> Bool {
        field.append(script[index])
        index = script.index(after: index)
        if index < script.endIndex, script[index] == "^" {
            field.append(script[index])
            index = script.index(after: index)
        }
        if index < script.endIndex, script[index] == "]" {
            field.append(script[index])
            index = script.index(after: index)
        }
        while index < script.endIndex {
            let character = script[index]
            field.append(character)
            index = script.index(after: index)
            if character == "]" {
                return true
            }
        }
        return false
    }

    private struct SedSubstitutionFlags {
        var global = false
        var occurrence: Int?
        var print = false
        var caseInsensitive = false
    }

    private static func parseSubstitutionFlags(_ rawFlags: String) throws -> SedSubstitutionFlags {
        let flags = Array(rawFlags)
        var parsed = SedSubstitutionFlags()
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case " ", "\t":
                index += 1
            case "g":
                parsed.global = true
                index += 1
            case "p":
                parsed.print = true
                index += 1
            case "I", "i":
                parsed.caseInsensitive = true
                index += 1
            case "0"..."9":
                guard parsed.occurrence == nil else {
                    throw MSPPOSIXSedError.usage("sed: multiple occurrence flags in substitute command")
                }
                var digits = ""
                while index < flags.count, ("0"..."9").contains(flags[index]) {
                    digits.append(flags[index])
                    index += 1
                }
                guard let occurrence = Int(digits), occurrence > 0 else {
                    throw MSPPOSIXSedError.usage("sed: occurrence flag in substitute command must be positive")
                }
                parsed.occurrence = occurrence
            default:
                throw MSPPOSIXSedError.usage("sed: bad flag in substitute command: '\(flag)'")
            }
        }
        return parsed
    }

}
