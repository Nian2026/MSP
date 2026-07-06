import Foundation

enum MSPPOSIXSedRegex {
    static func pattern(for sedPattern: String, extended: Bool) -> String {
        if extended {
            return normalizeExtendedRegexPattern(sedPattern)
        }
        return basicRegexPattern(for: sedPattern)
    }

    private static func normalizeExtendedRegexPattern(_ pattern: String) -> String {
        normalizeCharacterClasses(in: pattern) { character, escaped in
            if escaped {
                return "\\" + String(character)
            }
            return String(character)
        }
    }

    private static func basicRegexPattern(for pattern: String) -> String {
        var output = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "[" {
                let parsed = parseCharacterClass(in: pattern, from: index)
                output += parsed.regex
                index = parsed.nextIndex
                continue
            }
            if character == "\\" {
                let next = pattern.index(after: index)
                guard next < pattern.endIndex else {
                    output += "\\\\"
                    index = next
                    continue
                }
                switch pattern[next] {
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                case "(", ")", "+", "?", "|", "{", "}":
                    output.append(pattern[next])
                default:
                    output += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                }
                index = pattern.index(after: next)
                continue
            }
            switch character {
            case "+", "?", "{", "}", "|", "(", ")":
                output += NSRegularExpression.escapedPattern(for: String(character))
            default:
                output.append(character)
            }
            index = pattern.index(after: index)
        }
        return output
    }

    private static func normalizeCharacterClasses(
        in pattern: String,
        outsideClass: (Character, Bool) -> String
    ) -> String {
        var output = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "[" {
                let parsed = parseCharacterClass(in: pattern, from: index)
                output += parsed.regex
                index = parsed.nextIndex
                continue
            }
            if character == "\\" {
                let next = pattern.index(after: index)
                guard next < pattern.endIndex else {
                    output += "\\\\"
                    index = next
                    continue
                }
                output += escapedRegexCharacter(pattern[next], escaped: true)
                index = pattern.index(after: next)
                continue
            }
            output += outsideClass(character, false)
            index = pattern.index(after: index)
        }
        return output
    }

    private static func parseCharacterClass(
        in pattern: String,
        from openIndex: String.Index
    ) -> (regex: String, nextIndex: String.Index) {
        var output = "["
        var index = pattern.index(after: openIndex)
        var isFirstContent = true
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "\\" {
                let next = pattern.index(after: index)
                guard next < pattern.endIndex else {
                    output += "\\\\"
                    index = next
                    continue
                }
                output += escapedCharacterClassLiteral(pattern[next], isFirst: isFirstContent, escaped: true)
                isFirstContent = false
                index = pattern.index(after: next)
                continue
            }
            if character == "]", !isFirstContent {
                output.append("]")
                return (output, pattern.index(after: index))
            }
            output += escapedCharacterClassLiteral(character, isFirst: isFirstContent, escaped: false)
            isFirstContent = false
            index = pattern.index(after: index)
        }
        return (String(pattern[openIndex...]), pattern.endIndex)
    }

    private static func escapedCharacterClassLiteral(
        _ character: Character,
        isFirst: Bool,
        escaped: Bool
    ) -> String {
        if escaped {
            switch character {
            case "n":
                return "\n"
            case "r":
                return "\r"
            case "t":
                return "\t"
            default:
                break
            }
        }
        switch character {
        case "\\", "]", "[":
            return "\\" + String(character)
        case "^" where isFirst:
            return "\\^"
        case "-" where escaped:
            return "\\-"
        default:
            return String(character)
        }
    }

    private static func escapedRegexCharacter(_ character: Character, escaped: Bool) -> String {
        guard escaped else { return String(character) }
        switch character {
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        default:
            return "\\" + String(character)
        }
    }
}
