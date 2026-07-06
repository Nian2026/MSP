import Foundation

extension MSPPOSIXAwkSyntax {
    static func splitConcatenation(_ expression: String) -> [String] {
        var parts: [String] = []
        var previousNonWhitespace: Character?
        var index = expression.startIndex

        while index < expression.endIndex {
            while index < expression.endIndex, expression[index].isWhitespace {
                index = expression.index(after: index)
            }
            guard index < expression.endIndex else { break }
            let start = index
            let character = expression[index]
            if character == "\"" || character == "'" {
                index = expression.index(after: index)
                while index < expression.endIndex {
                    let value = expression[index]
                    if value == "\\" {
                        let next = expression.index(after: index)
                        index = next < expression.endIndex ? expression.index(after: next) : next
                        continue
                    }
                    index = expression.index(after: index)
                    if value == character { break }
                }
                parts.append(String(expression[start..<index]))
                continue
            }
            if character == "/", isRegexStart(previousNonWhitespace) {
                index = expression.index(after: index)
                while index < expression.endIndex {
                    let value = expression[index]
                    if value == "\\" {
                        let next = expression.index(after: index)
                        index = next < expression.endIndex ? expression.index(after: next) : next
                        continue
                    }
                    index = expression.index(after: index)
                    if value == "/" { break }
                }
                parts.append(String(expression[start..<index]))
                continue
            }
            if character == "$" {
                index = expression.index(after: index)
                while index < expression.endIndex, isIdentifierBody(expression[index]) {
                    index = expression.index(after: index)
                }
                parts.append(String(expression[start..<index]))
                continue
            }
            if character == "(" {
                if let close = try? matchingParen(in: expression, open: index) {
                    index = expression.index(after: close)
                    parts.append(String(expression[start..<index]))
                    previousNonWhitespace = ")"
                    continue
                }
            }
            if expression[index...].hasPrefix("++") || expression[index...].hasPrefix("--") {
                index = expression.index(index, offsetBy: 2)
                while index < expression.endIndex, expression[index].isWhitespace {
                    index = expression.index(after: index)
                }
                while index < expression.endIndex, isIdentifierBody(expression[index]) || expression[index] == "." {
                    index = expression.index(after: index)
                }
                while index < expression.endIndex, expression[index] == "[" || expression[index] == "(" {
                    let open = index
                    let closeCharacter: Character = expression[index] == "[" ? "]" : ")"
                    if let close = try? matchingPair(
                        in: expression,
                        open: open,
                        openCharacter: expression[open],
                        closeCharacter: closeCharacter
                    ) {
                        index = expression.index(after: close)
                    } else {
                        break
                    }
                }
                parts.append(String(expression[start..<index]))
                previousNonWhitespace = expression[expression.index(before: index)]
                continue
            }
            if character == "_" || character.isLetter || character.isNumber {
                index = expression.index(after: index)
                while index < expression.endIndex, isIdentifierBody(expression[index]) || expression[index] == "." {
                    index = expression.index(after: index)
                }
                while index < expression.endIndex, expression[index] == "[" || expression[index] == "(" {
                    let open = index
                    let closeCharacter: Character = expression[index] == "[" ? "]" : ")"
                    if let close = try? matchingPair(
                        in: expression,
                        open: open,
                        openCharacter: expression[open],
                        closeCharacter: closeCharacter
                    ) {
                        index = expression.index(after: close)
                    } else {
                        break
                    }
                }
                parts.append(String(expression[start..<index]))
                previousNonWhitespace = expression[expression.index(before: index)]
                continue
            }
            index = expression.index(after: index)
            parts.append(String(expression[start..<index]))
            if !character.isWhitespace {
                previousNonWhitespace = character
            }
        }
        return parts
    }
}
