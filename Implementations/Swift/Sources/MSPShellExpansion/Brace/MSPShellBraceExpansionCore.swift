import Foundation
import MSPShellLanguage

private struct MSPShellBraceExpression {
    var partIndex: Int
    var openOffset: Int
    var closeOffset: Int
    var alternatives: [String]
}

func mspShellBraceExpandedWords(_ word: MSPParsedWord) -> [MSPParsedWord]? {
    guard let expression = mspShellFirstBraceExpression(in: word) else {
        return nil
    }
    let expanded = expression.alternatives.flatMap { alternative in
        mspShellBraceExpandedWords(
            mspShellWordByReplacingBraceExpression(
                in: word,
                expression: expression,
                alternative: alternative
            )
        ) ?? [
            mspShellWordByReplacingBraceExpression(
                in: word,
                expression: expression,
                alternative: alternative
            )
        ]
    }
    return expanded
}

private func mspShellFirstBraceExpression(in word: MSPParsedWord) -> MSPShellBraceExpression? {
    for (partIndex, part) in word.parts.enumerated() where !part.isQuoted {
        guard let expression = mspShellFirstBraceExpression(in: part.text) else {
            continue
        }
        return MSPShellBraceExpression(
            partIndex: partIndex,
            openOffset: part.text.distance(from: part.text.startIndex, to: expression.open),
            closeOffset: part.text.distance(from: part.text.startIndex, to: expression.close),
            alternatives: expression.alternatives
        )
    }
    return nil
}

private func mspShellWordByReplacingBraceExpression(
    in word: MSPParsedWord,
    expression: MSPShellBraceExpression,
    alternative: String
) -> MSPParsedWord {
    var parts: [MSPParsedWord.Part] = []
    for (partIndex, part) in word.parts.enumerated() {
        guard partIndex == expression.partIndex else {
            parts.append(part)
            continue
        }
        let open = part.text.index(part.text.startIndex, offsetBy: expression.openOffset)
        let close = part.text.index(part.text.startIndex, offsetBy: expression.closeOffset)
        parts.append(MSPParsedWord.Part(
            text: String(part.text[..<open]),
            isExpandable: part.isExpandable,
            isQuoted: part.isQuoted
        ))
        parts.append(MSPParsedWord.Part(
            text: alternative,
            isExpandable: part.isExpandable,
            isQuoted: part.isQuoted
        ))
        parts.append(MSPParsedWord.Part(
            text: String(part.text[part.text.index(after: close)...]),
            isExpandable: part.isExpandable,
            isQuoted: part.isQuoted
        ))
    }
    return MSPParsedWord(
        parts: parts.filter { !$0.text.isEmpty },
        hasExplicitEmptyQuotedFragment: word.hasExplicitEmptyQuotedFragment
    )
}

private func mspShellFirstBraceExpression(
    in text: String
) -> (open: String.Index, close: String.Index, alternatives: [String])? {
    var index = text.startIndex
    while index < text.endIndex {
        if let nextIndex = mspShellBraceOpaqueSegmentEnd(in: text, startingAt: index) {
            index = nextIndex
            continue
        }
        guard text[index] == "{" else {
            index = text.index(after: index)
            continue
        }

        var cursor = text.index(after: index)
        var depth = 0
        var current = ""
        var alternatives: [String] = []
        var hasComma = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "{" {
                depth += 1
                current.append(character)
            } else if character == "}" {
                if depth == 0 {
                    if hasComma {
                        alternatives.append(current)
                        return (index, cursor, alternatives)
                    }
                    if let sequence = mspShellBraceSequenceAlternatives(current) {
                        return (index, cursor, sequence)
                    }
                    break
                }
                depth -= 1
                current.append(character)
            } else if character == ",", depth == 0 {
                hasComma = true
                alternatives.append(current)
                current = ""
            } else {
                current.append(character)
            }
            cursor = text.index(after: cursor)
        }
        index = text.index(after: index)
    }
    return nil
}

private func mspShellBraceSequenceAlternatives(_ text: String) -> [String]? {
    let pieces = text.components(separatedBy: "..")
    guard pieces.count == 2 || pieces.count == 3 else {
        return nil
    }

    if let start = Int(pieces[0]), let end = Int(pieces[1]) {
        let rawStep = pieces.count == 3 ? Int(pieces[2]) : nil
        let stepMagnitude = abs(rawStep ?? (start <= end ? 1 : -1))
        guard stepMagnitude > 0 else {
            return nil
        }
        let width = mspShellBraceSequenceWidth(pieces[0], pieces[1])
        let step = start <= end ? stepMagnitude : -stepMagnitude
        var value = start
        var alternatives: [String] = []
        while start <= end ? value <= end : value >= end {
            alternatives.append(mspShellFormattedBraceSequenceValue(value, width: width))
            guard alternatives.count < 10_000 else {
                return nil
            }
            value += step
        }
        return alternatives
    }

    guard pieces[0].unicodeScalars.count == 1,
          pieces[1].unicodeScalars.count == 1,
          let start = pieces[0].unicodeScalars.first,
          let end = pieces[1].unicodeScalars.first else {
        return nil
    }
    let rawStep = pieces.count == 3 ? Int(pieces[2]) : nil
    let stepMagnitude = abs(rawStep ?? 1)
    guard stepMagnitude > 0 else {
        return nil
    }
    let startValue = Int(start.value)
    let endValue = Int(end.value)
    let step = startValue <= endValue ? stepMagnitude : -stepMagnitude
    var value = startValue
    var alternatives: [String] = []
    while startValue <= endValue ? value <= endValue : value >= endValue {
        guard let scalar = UnicodeScalar(value) else {
            return nil
        }
        alternatives.append(String(Character(scalar)))
        guard alternatives.count < 10_000 else {
            return nil
        }
        value += step
    }
    return alternatives
}

private func mspShellBraceSequenceWidth(_ lhs: String, _ rhs: String) -> Int? {
    func paddedWidth(_ text: String) -> Int? {
        let signless = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        guard signless.count > 1, signless.hasPrefix("0") else {
            return nil
        }
        return signless.count
    }
    return [paddedWidth(lhs), paddedWidth(rhs)].compactMap { $0 }.max()
}

private func mspShellFormattedBraceSequenceValue(_ value: Int, width: Int?) -> String {
    guard let width else {
        return String(value)
    }
    let sign = value < 0 ? "-" : ""
    let digits = String(abs(value))
    return sign + String(repeating: "0", count: max(0, width - digits.count)) + digits
}

private func mspShellBraceOpaqueSegmentEnd(
    in text: String,
    startingAt index: String.Index
) -> String.Index? {
    let character = text[index]
    if character == "`",
       let substitution = try? MSPShellSubstitutionScanner.backtickSubstitutionCommand(
            in: text,
            startingAt: index
       ) {
        return substitution.nextIndex
    }
    guard character == "$" else {
        return nil
    }
    let next = text.index(after: index)
    guard next < text.endIndex else {
        return nil
    }
    if text[next] == "{",
       let closingBrace = MSPShellExpansionScanner.bracedParameterEndIndex(
            in: text,
            openingBraceIndex: next,
            grammar: .msp
       ) {
        return text.index(after: closingBrace)
    }
    if text[next] == "(" {
        let secondNext = text.index(after: next)
        if secondNext < text.endIndex, text[secondNext] == "(" {
            return try? MSPShellSubstitutionScanner.arithmeticExpansionEndIndex(
                in: text,
                startingAt: index,
                grammar: .msp
            )
        }
        return try? MSPShellSubstitutionScanner.commandSubstitutionEndIndex(
            in: text,
            startingAt: index,
            grammar: .msp
        )
    }
    return nil
}
