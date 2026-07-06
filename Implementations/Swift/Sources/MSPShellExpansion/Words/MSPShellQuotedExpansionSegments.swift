import Foundation
import MSPShellLanguage

enum MSPShellExpansionSegment {
    case text(String)
    case quotedPositionalParameters(mode: String)
    case quotedArrayValues(name: String, mode: String)
    case quotedArrayIndices(name: String, mode: String)
}

func mspShellExpansionSegmentsPreservingQuotedPositionalParameters(
    in text: String
) -> [MSPShellExpansionSegment] {
    var segments: [MSPShellExpansionSegment] = []
    var literal = ""
    var index = text.startIndex
    while index < text.endIndex {
        if let opaqueEnd = mspShellQuotedExpansionOpaqueSegmentEnd(in: text, startingAt: index) {
            literal += text[index..<opaqueEnd]
            index = opaqueEnd
            continue
        }

        guard text[index] == "$" else {
            literal.append(text[index])
            index = text.index(after: index)
            continue
        }

        let next = text.index(after: index)
        guard next < text.endIndex else {
            literal.append(text[index])
            index = next
            continue
        }

        if text[next] == "@" || text[next] == "*" {
            if !literal.isEmpty {
                segments.append(.text(literal))
                literal = ""
            }
            segments.append(.quotedPositionalParameters(mode: String(text[next])))
            index = text.index(after: next)
            continue
        }

        if text[next] == "{" {
            let nameStart = text.index(after: next)
            if nameStart < text.endIndex,
               text[nameStart] == "@" || text[nameStart] == "*" {
                let nameEnd = text.index(after: nameStart)
                if nameEnd < text.endIndex,
                   text[nameEnd] == "}" {
                    if !literal.isEmpty {
                        segments.append(.text(literal))
                        literal = ""
                    }
                    segments.append(.quotedPositionalParameters(mode: String(text[nameStart])))
                    index = text.index(after: nameEnd)
                    continue
                }
            }
            if let close = text[nameStart...].firstIndex(of: "}") {
                let expression = String(text[nameStart..<close])
                let segment: MSPShellExpansionSegment?
                if expression.hasPrefix("!"),
                   let splat = MSPShellParameterExpansionSyntax.arraySplatExpression(
                    String(expression.dropFirst())
                   ) {
                    segment = .quotedArrayIndices(name: splat.name, mode: splat.mode)
                } else if let splat = MSPShellParameterExpansionSyntax.arraySplatExpression(expression) {
                    segment = .quotedArrayValues(name: splat.name, mode: splat.mode)
                } else {
                    segment = nil
                }
                if let segment {
                    if !literal.isEmpty {
                        segments.append(.text(literal))
                        literal = ""
                    }
                    segments.append(segment)
                    index = text.index(after: close)
                    continue
                }
            }
        }

        literal.append(text[index])
        index = next
    }

    if !literal.isEmpty {
        segments.append(.text(literal))
    }
    return segments
}

private func mspShellQuotedExpansionOpaqueSegmentEnd(
    in text: String,
    startingAt index: String.Index
) -> String.Index? {
    if text[index] == "`",
       let substitution = try? MSPShellSubstitutionScanner.backtickSubstitutionCommand(
        in: text,
        startingAt: index
       ) {
        return substitution.nextIndex
    }
    guard text[index] == "$" else {
        return nil
    }
    let openIndex = text.index(after: index)
    guard openIndex < text.endIndex, text[openIndex] == "(" else {
        return nil
    }
    let bodyStart = text.index(after: openIndex)
    if bodyStart < text.endIndex, text[bodyStart] == "(" {
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
