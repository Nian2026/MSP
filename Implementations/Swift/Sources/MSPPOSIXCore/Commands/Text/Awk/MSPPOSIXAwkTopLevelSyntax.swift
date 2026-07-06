import Foundation

extension MSPPOSIXAwkSyntax {
    static func splitStatements(_ body: String) -> [String] {
        splitTopLevel(body, separator: ";", alsoSplitNewlines: true)
    }

    static func splitTopLevel(_ text: String, separator: Character, alsoSplitNewlines: Bool = false) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var regex = false
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var previousNonWhitespace: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                current.append(character)
                if character == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        current.append(text[next])
                        index = next
                    }
                } else if character == activeQuote {
                    quote = nil
                }
                index = text.index(after: index)
                continue
            }
            if regex {
                current.append(character)
                if character == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        current.append(text[next])
                        index = next
                    }
                } else if character == "/" {
                    regex = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "/", isRegexStart(previousNonWhitespace) {
                regex = true
                current.append(character)
            } else if character == "(" {
                parenDepth += 1
                current.append(character)
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
            } else if character == "{" {
                braceDepth += 1
                current.append(character)
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                current.append(character)
                if alsoSplitNewlines, separator == ";",
                   parenDepth == 0, braceDepth == 0, bracketDepth == 0,
                   shouldSplitAfterClosedAwkBlock(in: text, at: index) {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                    current = ""
                }
            } else if character == "[" {
                bracketDepth += 1
                current.append(character)
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            } else if parenDepth == 0, braceDepth == 0, bracketDepth == 0,
                      character == separator || (alsoSplitNewlines && character == "\n") {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
            if !character.isWhitespace {
                previousNonWhitespace = character
            }
            index = text.index(after: index)
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }

    static func splitByTopLevelOperator(_ text: String, operatorText: String) -> [String]? {
        var parts: [String] = []
        var start = text.startIndex
        var cursor = text.startIndex
        while let range = findTopLevelOperator(operatorText, in: text, startingAt: cursor) {
            parts.append(String(text[start..<range.lowerBound]))
            cursor = range.upperBound
            start = range.upperBound
        }
        guard !parts.isEmpty else { return nil }
        parts.append(String(text[start...]))
        return parts
    }

    static func splitTernary(_ text: String) -> (condition: String, trueExpression: String, falseExpression: String)? {
        guard let questionRange = findTopLevel("?", in: text, startingAt: text.startIndex),
              let colonRange = findTopLevel(":", in: text, startingAt: questionRange.upperBound) else {
            return nil
        }
        let question = questionRange.lowerBound
        let colon = colonRange.lowerBound
        return (
            String(text[..<question]),
            String(text[questionRange.upperBound..<colon]),
            String(text[colonRange.upperBound...])
        )
    }

    static func splitIfBodies(_ text: String) -> (thenBody: String, elseBody: String?) {
        guard let elseRange = findTopLevelKeyword("else", in: text) else {
            return (text, nil)
        }
        return (
            String(text[..<elseRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[elseRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func findTopLevelAssignment(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        while let range = findTopLevel("=", in: text, startingAt: index) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : "\0"
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : "\0"
            if before != "=" && before != "!" && before != "<" && before != ">" && after != "=" {
                return range
            }
            index = range.upperBound
        }
        return nil
    }

    static func findTopLevelInOperator(in text: String) -> Range<String.Index>? {
        findTopLevelKeyword("in", in: text)
    }

    static func findTopLevelOperator(_ operatorText: String, in text: String, startingAt start: String.Index? = nil) -> Range<String.Index>? {
        findTopLevel(operatorText, in: text, startingAt: start ?? text.startIndex)
    }

    static func findRightmostTopLevelArithmeticOperator(
        _ operatorTexts: [String],
        in text: String
    ) -> (String, Range<String.Index>)? {
        var best: (String, Range<String.Index>)?
        for operatorText in operatorTexts {
            var cursor = text.startIndex
            while let range = findTopLevelOperator(operatorText, in: text, startingAt: cursor) {
                if !isIncrementOrDecrementOperator(operatorText, at: range, in: text),
                   !isUnaryArithmeticOperator(operatorText, at: range, in: text),
                   best == nil || range.lowerBound > best!.1.lowerBound {
                    best = (operatorText, range)
                }
                cursor = range.upperBound
            }
        }
        return best
    }

    static func findTopLevelKeyword(_ keyword: String, in text: String) -> Range<String.Index>? {
        var cursor = text.startIndex
        while let range = findTopLevel(keyword, in: text, startingAt: cursor) {
            if isWordBoundary(text, before: range.lowerBound), isWordBoundary(text, after: range.upperBound) {
                return range
            }
            cursor = range.upperBound
        }
        return nil
    }

    static func findTopLevel(_ needle: String, in text: String, startingAt start: String.Index) -> Range<String.Index>? {
        var quote: Character?
        var regex = false
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var previousNonWhitespace: Character?
        var index = start
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
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if parenDepth == 0, braceDepth == 0, bracketDepth == 0, text[index...].hasPrefix(needle) {
                let end = text.index(index, offsetBy: needle.count)
                return index..<end
            }
            if !character.isWhitespace {
                previousNonWhitespace = character
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func findTopLevelOpeningBrace(in text: String, startingAt start: String.Index) -> String.Index? {
        var quote: Character?
        var regex = false
        var parenDepth = 0
        var bracketDepth = 0
        var previousNonWhitespace: Character?
        var index = start
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
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{", parenDepth == 0, bracketDepth == 0 {
                return index
            }
            if !character.isWhitespace {
                previousNonWhitespace = character
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func shouldSplitAfterClosedAwkBlock(in text: String, at closeBrace: String.Index) -> Bool {
        var index = text.index(after: closeBrace)
        while index < text.endIndex, text[index].isWhitespace {
            if text[index] == "\n" { return true }
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return false }
        if text[index] == ";" { return false }
        if keywordAt(index, in: text, is: "else") { return false }
        return true
    }

    static func keywordAt(_ index: String.Index, in text: String, is keyword: String) -> Bool {
        guard let end = text.index(index, offsetBy: keyword.count, limitedBy: text.endIndex),
              String(text[index..<end]) == keyword else {
            return false
        }
        return isWordBoundary(text, before: index) && isWordBoundary(text, after: end)
    }

    private static func isIncrementOrDecrementOperator(
        _ operatorText: String,
        at range: Range<String.Index>,
        in text: String
    ) -> Bool {
        guard operatorText == "+" || operatorText == "-" else { return false }
        if range.lowerBound > text.startIndex {
            let previous = text.index(before: range.lowerBound)
            if text[previous] == Character(operatorText) {
                return true
            }
        }
        if range.upperBound < text.endIndex, text[range.upperBound] == Character(operatorText) {
            return true
        }
        return false
    }

    private static func isUnaryArithmeticOperator(
        _ operatorText: String,
        at range: Range<String.Index>,
        in text: String
    ) -> Bool {
        guard operatorText == "+" || operatorText == "-" else { return false }
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isWhitespace { continue }
            return "+-*/%(,=<>!?:".contains(character)
        }
        return true
    }
}
