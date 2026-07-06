import Foundation

package enum MSPShellExpansionScanner {
    package static func ansiCQuotedExpansionText(
        in text: String,
        startingAt dollarIndex: String.Index
    ) throws -> (text: String, nextIndex: String.Index) {
        try MSPShellAnsiCQuote.quotedText(in: text, startingAt: dollarIndex)
    }

    package static func bracedParameterEndIndex(
        in text: String,
        openingBraceIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) -> String.Index? {
        var index = text.index(after: openingBraceIndex)
        var nestedDepth = 0
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = text.index(after: index)
                    continue
                }
                if character == "\\" {
                    let next = text.index(after: index)
                    index = next < text.endIndex ? text.index(after: next) : next
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                let next = text.index(after: index)
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if character == "`" {
                do {
                    let substitution = try MSPShellSubstitutionScanner.backtickSubstitutionCommand(
                        in: text,
                        startingAt: index
                    )
                    index = substitution.nextIndex
                    continue
                } catch {
                    return nil
                }
            }
            if character == "$" {
                let next = text.index(after: index)
                if grammar.recognizesAnsiCQuote(in: .parameterOperationWord),
                   next < text.endIndex,
                   text[next] == "'" {
                    do {
                        let quoted = try ansiCQuotedExpansionText(in: text, startingAt: index)
                        index = quoted.nextIndex
                        continue
                    } catch {
                        return nil
                    }
                }
                if next < text.endIndex, text[next] == "(" {
                    do {
                        let secondNext = text.index(after: next)
                        if secondNext < text.endIndex, text[secondNext] == "(" {
                            index = try MSPShellSubstitutionScanner.arithmeticExpansionEndIndex(
                                in: text,
                                startingAt: index,
                                grammar: grammar
                            )
                        } else {
                            index = try MSPShellSubstitutionScanner.commandSubstitutionEndIndex(
                                in: text,
                                startingAt: index,
                                grammar: grammar
                            )
                        }
                        continue
                    } catch {
                        return nil
                    }
                }
                if next < text.endIndex, text[next] == "{" {
                    nestedDepth += 1
                    index = text.index(after: next)
                    continue
                }
            }
            if character == "}" {
                if nestedDepth == 0 {
                    return index
                }
                nestedDepth -= 1
            }
            index = text.index(after: index)
        }
        return nil
    }

    package static func isShellVariableStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    package static func isShellVariableBody(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    package static func isShellVariableName(_ value: String) -> Bool {
        guard let first = value.first,
              isShellVariableStart(first) else {
            return false
        }
        return value.dropFirst().allSatisfy(isShellVariableBody)
    }
}
