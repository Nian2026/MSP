import Foundation

extension MSPPOSIXAwkSyntax {
    static func matchingParen(in text: String, open: String.Index) throws -> String.Index {
        try matchingPair(in: text, open: open, openCharacter: "(", closeCharacter: ")")
    }

    static func matchingPair(
        in text: String,
        open: String.Index,
        openCharacter: Character,
        closeCharacter: Character
    ) throws -> String.Index {
        var depth = 0
        var quote: Character?
        var regex = false
        var previousNonWhitespace: Character?
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == "\\" {
                    let next = text.index(after: index)
                    index = next < text.endIndex ? text.index(after: next) : next
                    continue
                }
                if character == activeQuote { quote = nil }
                index = text.index(after: index)
                continue
            }
            if regex {
                if character == "\\" {
                    let next = text.index(after: index)
                    index = next < text.endIndex ? text.index(after: next) : next
                    continue
                }
                if character == "/" { regex = false }
                index = text.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "/", isRegexStart(previousNonWhitespace) {
                regex = true
            } else if character == openCharacter {
                depth += 1
            } else if character == closeCharacter {
                depth -= 1
                if depth == 0 { return index }
            }
            if !character.isWhitespace {
                previousNonWhitespace = character
            }
            index = text.index(after: index)
        }
        throw MSPPOSIXAwkError.usage("awk: unmatched \(openCharacter)")
    }

    static func topLevelSubscript(in text: String) -> (nameEnd: String.Index, keyRange: Range<String.Index>)? {
        guard text.hasSuffix("]") else { return nil }
        var quote: Character?
        var parenDepth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == "\\" {
                    let next = text.index(after: index)
                    index = next < text.endIndex ? text.index(after: next) : next
                    continue
                }
                if character == activeQuote { quote = nil }
                index = text.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
            } else if character == "[", parenDepth == 0 {
                let name = String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.allSatisfy(isIdentifierBody) else {
                    return nil
                }
                return (index, text.index(after: index)..<text.index(before: text.endIndex))
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func strippingOuterParens(_ text: String) -> String {
        var current = text
        while current.hasPrefix("("), current.hasSuffix(")") {
            do {
                let close = try matchingParen(in: current, open: current.startIndex)
                guard close == current.index(before: current.endIndex) else { return current }
                current = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return current
            }
        }
        return current
    }
}
