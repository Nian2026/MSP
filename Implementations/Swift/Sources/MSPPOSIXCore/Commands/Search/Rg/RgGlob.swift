import Foundation

struct RgGlobRule {
    var pattern: String
    var isExclusion: Bool
    private var regex: NSRegularExpression

    init(rawPattern: String) throws {
        let parsedPattern: String
        if rawPattern.hasPrefix("!") {
            self.isExclusion = true
            parsedPattern = String(rawPattern.dropFirst())
        } else {
            self.isExclusion = false
            parsedPattern = rawPattern
        }
        self.pattern = parsedPattern
        self.regex = try NSRegularExpression(
            pattern: "^" + rgGlobRegex(parsedPattern) + "$"
        )
    }

    func matches(_ displayPath: String) -> Bool {
        let comparablePath = rgComparableGlobPath(displayPath)
        let target = pattern.contains("/")
            ? comparablePath
            : MSPPOSIXCommandSupport.basename(comparablePath)
        return regex.firstMatch(
            in: target,
            range: NSRange(target.startIndex..., in: target)
        ) != nil
    }
}

struct RgGlobParseError: Error {
    var message: String
}

private func rgComparableGlobPath(_ displayPath: String) -> String {
    var path = displayPath
    while path.hasPrefix("./") {
        path.removeFirst(2)
    }
    while path.hasPrefix("/") {
        path.removeFirst()
    }
    return path
}

private func rgGlobRegex(_ pattern: String) throws -> String {
    let characters = Array(pattern)
    var output = ""
    var index = 0
    while index < characters.count {
        let character = characters[index]
        switch character {
        case "*":
            output += ".*"
        case "?":
            output += "."
        case "[":
            let characterClass = try rgGlobCharacterClass(
                characters,
                openingIndex: index
            )
            output += characterClass.regex
            index = characterClass.closingIndex
        case ".", "\\", "+", "(", ")", "]", "{", "}", "^", "$", "|":
            output += "\\\(character)"
        default:
            output.append(character)
        }
        index += 1
    }
    return output
}

private func rgGlobCharacterClass(
    _ characters: [Character],
    openingIndex: Int
) throws -> (regex: String, closingIndex: Int) {
    var index = openingIndex + 1
    var output = "["

    guard index < characters.count else {
        throw RgGlobParseError(message: "unclosed character class; missing ']'")
    }

    if characters[index] == "!" {
        output += "^"
        index += 1
    } else if characters[index] == "^" {
        output += "\\^"
        index += 1
    }

    if index < characters.count, characters[index] == "]" {
        output += "\\]"
        index += 1
    }

    while index < characters.count {
        let character = characters[index]
        if character == "]" {
            output += "]"
            return (output, index)
        }
        switch character {
        case "\\":
            let nextIndex = index + 1
            if nextIndex < characters.count {
                output += "\\\(characters[nextIndex])"
                index = nextIndex
            } else {
                output += "\\\\"
            }
        case "[", "^":
            output += "\\\(character)"
        default:
            output.append(character)
        }
        index += 1
    }

    throw RgGlobParseError(message: "unclosed character class; missing ']'")
}
