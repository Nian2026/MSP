import Foundation

extension MSPPOSIXAwkSyntax {
    static func parseFunctionCall(_ text: String) -> (name: String, arguments: String)? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.allSatisfy({ isIdentifierBody($0) }) else { return nil }
        return (name, String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
    }

    static func enclosedArguments(_ text: String) -> String {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return "" }
        return String(text[text.index(after: open)..<text.index(before: text.endIndex)])
    }

    static func isQuotedString(_ value: String) -> Bool {
        (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
    }

    static func isRegexLiteral(_ value: String) -> Bool {
        value.hasPrefix("/") && value.hasSuffix("/") && value.count >= 2
    }

    static func isPrimaryStart(_ character: Character) -> Bool {
        character == "$" || character == "\"" || character == "'" || character == "(" || character == "/" || character == "_" || character.isLetter || character.isNumber
    }

    static func isRegexStart(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return "({[=~!,:?;".contains(previous)
    }

    static func isWordBoundary(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return !isIdentifierBody(text[text.index(before: index)])
    }

    static func isWordBoundary(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        return !isIdentifierBody(text[index])
    }

    static func isIdentifierBody(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    static func isAwkIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else {
            return false
        }
        return text.allSatisfy(isIdentifierBody)
    }

    static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    static func decodeAwkString(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                output.append(character)
                index = value.index(after: index)
                continue
            }
            let next = value.index(after: index)
            guard next < value.endIndex else {
                output.append(character)
                index = next
                continue
            }
            switch value[next] {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "\\": output.append("\\")
            case "\"": output.append("\"")
            default: output.append(value[next])
            }
            index = value.index(after: next)
        }
        return output
    }
}
