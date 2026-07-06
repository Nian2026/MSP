import Foundation

struct MSPShellCommandSubstitutionCaseState {
    private var wordBuffer = ""
    private var wordCanBeReserved = true
    private var nextWordCanBeReserved = true
    private(set) var caseDepth = 0
    private(set) var inCasePattern = false

    mutating func consumeWordCharacter(_ character: Character) -> Bool {
        guard character == "_" || character.isLetter || character.isNumber else {
            return false
        }
        if wordBuffer.isEmpty {
            wordCanBeReserved = nextWordCanBeReserved
        }
        wordBuffer.append(character)
        nextWordCanBeReserved = false
        return true
    }

    mutating func flushWord(before delimiter: Character?) {
        let hadWord = !wordBuffer.isEmpty
        switch wordBuffer {
        case "case" where wordCanBeReserved:
            caseDepth += 1
            inCasePattern = false
        case "in" where caseDepth > 0:
            inCasePattern = true
        case "esac" where wordCanBeReserved && caseDepth > 0:
            caseDepth -= 1
            inCasePattern = false
        default:
            break
        }
        wordBuffer = ""
        wordCanBeReserved = true
        nextWordCanBeReserved = Self.nextWordCanBeReserved(after: delimiter, flushedWord: hadWord)
    }

    mutating func enterOpaqueWordPart() {
        wordBuffer = ""
        wordCanBeReserved = false
        nextWordCanBeReserved = false
    }

    mutating func observeCaseTerminator(_ character: Character, next: Character?) {
        if caseDepth > 0, character == ";", next == ";" {
            inCasePattern = true
        }
    }

    mutating func consumeCasePatternCloseIfNeeded() -> Bool {
        guard inCasePattern else { return false }
        inCasePattern = false
        return true
    }

    private static func nextWordCanBeReserved(after delimiter: Character?, flushedWord: Bool) -> Bool {
        guard let delimiter else { return true }
        if delimiter == "\n" {
            return true
        }
        if delimiter.isWhitespace {
            return !flushedWord
        }
        return ";|&()".contains(delimiter)
    }
}

package enum MSPShellSubstitutionScanner {
    package static func maximumCommandSubstitutionDepth(in text: String) throws -> Int {
        var maximumDepth = 0
        var index = text.startIndex
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
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionCommand(in: text, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index) {
                    index = text.index(after: nestedParameterEnd)
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   text.index(after: index) < text.endIndex,
                   text[text.index(after: index)] == "(" {
                    if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                       text[text.index(index, offsetBy: 2)] == "(" {
                        index = try arithmeticExpansionEndIndex(in: text, startingAt: index)
                    } else {
                        let end = try commandSubstitutionEndIndex(in: text, startingAt: index)
                        let bodyStart = text.index(index, offsetBy: 2)
                        let bodyEnd = text.index(before: end)
                        let nested = try maximumCommandSubstitutionDepth(in: String(text[bodyStart..<bodyEnd]))
                        maximumDepth = max(maximumDepth, 1 + nested)
                        index = end
                    }
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
            if character == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                   text[text.index(index, offsetBy: 2)] == "(" {
                    index = try arithmeticExpansionEndIndex(in: text, startingAt: index)
                } else {
                    let end = try commandSubstitutionEndIndex(in: text, startingAt: index)
                    let bodyStart = text.index(index, offsetBy: 2)
                    let bodyEnd = text.index(before: end)
                    let nested = try maximumCommandSubstitutionDepth(in: String(text[bodyStart..<bodyEnd]))
                    maximumDepth = max(maximumDepth, 1 + nested)
                    index = end
                }
                continue
            }
            index = text.index(after: index)
        }

        return maximumDepth
    }

    package static func commandSubstitutionEndIndex(
        in text: String,
        startingAt dollarIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) throws -> String.Index {
        let openIndex = text.index(after: dollarIndex)
        var index = text.index(after: openIndex)
        var quote: Character?
        var nestedParentheses = 0
        var caseState = MSPShellCommandSubstitutionCaseState()
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
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionCommand(in: text, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index, grammar: grammar) {
                    index = text.index(after: nestedParameterEnd)
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   text.index(after: index) < text.endIndex,
                   text[text.index(after: index)] == "(" {
                    if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                       text[text.index(index, offsetBy: 2)] == "(" {
                        index = try arithmeticExpansionEndIndex(in: text, startingAt: index, grammar: grammar)
                    } else {
                        index = try commandSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                    }
                    continue
                }
                if activeQuote == "\"",
                   grammar.recognizesProcessSubstitution(in: .nestedShellInput),
                   (character == "<" || character == ">"),
                   text.index(after: index) < text.endIndex,
                   text[text.index(after: index)] == "(" {
                    index = try processSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                    continue
                }
                index = text.index(after: index)
                continue
            }

            if caseState.consumeWordCharacter(character) {
                index = text.index(after: index)
                continue
            }
            caseState.flushWord(before: character)
            if character == "'" || character == "\"" {
                caseState.enterOpaqueWordPart()
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                caseState.enterOpaqueWordPart()
                let next = text.index(after: index)
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index, grammar: grammar) {
                caseState.enterOpaqueWordPart()
                index = text.index(after: nestedParameterEnd)
                continue
            }
            if character == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                caseState.enterOpaqueWordPart()
                if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                   text[text.index(index, offsetBy: 2)] == "(" {
                    index = try arithmeticExpansionEndIndex(in: text, startingAt: index, grammar: grammar)
                } else {
                    index = try commandSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                }
                continue
            }
            if grammar.recognizesProcessSubstitution(in: .nestedShellInput),
               (character == "<" || character == ">"),
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                caseState.enterOpaqueWordPart()
                index = try processSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                continue
            }
            if character == "(" {
                if !caseState.inCasePattern {
                    nestedParentheses += 1
                }
                index = text.index(after: index)
                continue
            }
            if character == ")" {
                if caseState.consumeCasePatternCloseIfNeeded() {
                    index = text.index(after: index)
                    continue
                }
                if nestedParentheses > 0 {
                    nestedParentheses -= 1
                    index = text.index(after: index)
                    continue
                }
                return text.index(after: index)
            }
            let next = text.index(after: index)
            caseState.observeCaseTerminator(character, next: next < text.endIndex ? text[next] : nil)
            index = text.index(after: index)
        }
        throw ShellExit.usage("$(: unterminated command substitution")
    }

    static func processSubstitutionEndIndex(
        in text: String,
        startingAt operatorIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) throws -> String.Index {
        let openIndex = text.index(after: operatorIndex)
        var index = text.index(after: openIndex)
        var depth = 1
        var quote: Character?
        var caseState = MSPShellCommandSubstitutionCaseState()

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
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionCommand(in: text, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index, grammar: grammar) {
                    index = text.index(after: nestedParameterEnd)
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   text.index(after: index) < text.endIndex,
                   text[text.index(after: index)] == "(" {
                    if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                       text[text.index(index, offsetBy: 2)] == "(" {
                        index = try arithmeticExpansionEndIndex(in: text, startingAt: index, grammar: grammar)
                    } else {
                        index = try commandSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                    }
                    continue
                }
                if activeQuote == "\"",
                   grammar.recognizesProcessSubstitution(in: .nestedShellInput),
                   (character == "<" || character == ">"),
                   text.index(after: index) < text.endIndex,
                   text[text.index(after: index)] == "(" {
                    index = try processSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                    continue
                }
                index = text.index(after: index)
                continue
            }

            if caseState.consumeWordCharacter(character) {
                index = text.index(after: index)
                continue
            }
            caseState.flushWord(before: character)
            if character == "'" || character == "\"" {
                caseState.enterOpaqueWordPart()
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                caseState.enterOpaqueWordPart()
                let next = text.index(after: index)
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index, grammar: grammar) {
                caseState.enterOpaqueWordPart()
                index = text.index(after: nestedParameterEnd)
                continue
            }
            if character == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                caseState.enterOpaqueWordPart()
                if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                   text[text.index(index, offsetBy: 2)] == "(" {
                    index = try arithmeticExpansionEndIndex(in: text, startingAt: index, grammar: grammar)
                } else {
                    index = try commandSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                }
                continue
            }
            if grammar.recognizesProcessSubstitution(in: .nestedShellInput),
               (character == "<" || character == ">"),
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(" {
                caseState.enterOpaqueWordPart()
                index = try processSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                continue
            }
            if character == "(" {
                if !caseState.inCasePattern {
                    depth += 1
                }
                index = text.index(after: index)
                continue
            }
            if character == ")" {
                if caseState.consumeCasePatternCloseIfNeeded() {
                    index = text.index(after: index)
                    continue
                }
                depth -= 1
                if depth == 0 {
                    return text.index(after: index)
                }
            }
            let next = text.index(after: index)
            caseState.observeCaseTerminator(character, next: next < text.endIndex ? text[next] : nil)
            index = text.index(after: index)
        }
        throw ShellExit.usage("\(text[operatorIndex])(: unterminated process substitution")
    }

    package static func arithmeticExpansionEndIndex(
        in text: String,
        startingAt dollarIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) throws -> String.Index {
        let firstOpenIndex = text.index(after: dollarIndex)
        let secondOpenIndex = text.index(after: firstOpenIndex)
        var index = text.index(after: secondOpenIndex)
        var nestedParentheses = 0
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
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionCommand(in: text, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index, grammar: grammar) {
                    index = text.index(after: nestedParameterEnd)
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   text.index(after: index) < text.endIndex,
                   text[text.index(after: index)] == "(" {
                    if text.index(index, offsetBy: 2, limitedBy: text.index(before: text.endIndex)) != nil,
                       text[text.index(index, offsetBy: 2)] == "(" {
                        index = try arithmeticExpansionEndIndex(in: text, startingAt: index, grammar: grammar)
                    } else {
                        index = try commandSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                    }
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                let next = text.index(after: index)
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "`" {
                let nestedBacktick = try backtickSubstitutionCommand(in: text, startingAt: index)
                index = nestedBacktick.nextIndex
                continue
            }
            if let nestedParameterEnd = bracedParameterExpansionEndIndex(in: text, startingAt: index, grammar: grammar) {
                index = text.index(after: nestedParameterEnd)
                continue
            }
            if character == "$" {
                let next = text.index(after: index)
                if grammar.recognizesAnsiCQuote(in: .nestedShellInput),
                   next < text.endIndex,
                   text[next] == "'" {
                    let quoted = try MSPShellExpansionScanner.ansiCQuotedExpansionText(
                        in: text,
                        startingAt: index
                    )
                    index = quoted.nextIndex
                    continue
                }
                if next < text.endIndex, text[next] == "(" {
                    let secondNext = text.index(after: next)
                    if secondNext < text.endIndex, text[secondNext] == "(" {
                        index = try arithmeticExpansionEndIndex(in: text, startingAt: index, grammar: grammar)
                    } else {
                        index = try commandSubstitutionEndIndex(in: text, startingAt: index, grammar: grammar)
                    }
                    continue
                }
            }
            if character == "(" {
                nestedParentheses += 1
                index = text.index(after: index)
                continue
            }
            if character == ")" {
                let next = text.index(after: index)
                if nestedParentheses == 0, next < text.endIndex, text[next] == ")" {
                    return text.index(after: next)
                }
                if nestedParentheses > 0 {
                    nestedParentheses -= 1
                }
            }
            index = text.index(after: index)
        }
        throw ShellExit.usage("$((: unterminated arithmetic expansion")
    }

    private static func bracedParameterExpansionEndIndex(
        in text: String,
        startingAt dollarIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) -> String.Index? {
        let openIndex = text.index(after: dollarIndex)
        guard openIndex < text.endIndex, text[openIndex] == "{" else { return nil }
        return MSPShellExpansionScanner.bracedParameterEndIndex(
            in: text,
            openingBraceIndex: openIndex,
            grammar: grammar
        )
    }

    package static func backtickSubstitutionCommand(
        in text: String,
        startingAt openIndex: String.Index
    ) throws -> (command: String, nextIndex: String.Index) {
        var index = text.index(after: openIndex)
        var command = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    let escaped = text[next]
                    if escaped == "$" || escaped == "`" || escaped == "\\" {
                        command.append(escaped)
                    } else if escaped != "\n" {
                        command.append("\\")
                        command.append(escaped)
                    }
                    index = text.index(after: next)
                } else {
                    command.append(character)
                    index = next
                }
                continue
            }
            if character == "`" {
                return (command, text.index(after: index))
            }
            command.append(character)
            index = text.index(after: index)
        }
        throw ShellExit.usage("`: unterminated command substitution")
    }
}
