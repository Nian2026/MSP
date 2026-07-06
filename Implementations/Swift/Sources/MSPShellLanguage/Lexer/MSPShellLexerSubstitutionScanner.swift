import Foundation

enum MSPShellLexerSubstitutionScanner {
    static let doubleQuoteEscapableCharacters = Set<Character>(["$", "`", "\"", "\\", "\n"])

    static func commandSubstitutionText(
        in command: String,
        startingAt dollarIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) throws -> (text: String, nextIndex: String.Index) {
        let openIndex = command.index(after: dollarIndex)
        var index = command.index(after: openIndex)
        var quote: Character?
        var nestedParentheses = 0
        var caseState = MSPShellCommandSubstitutionCaseState()

        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = command.index(after: index)
                    continue
                }
                if character == "\\" {
                    let next = command.index(after: index)
                    index = next < command.endIndex ? command.index(after: next) : next
                    continue
                }
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionText(in: command, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "{" {
                    let nestedParameter = try bracedParameterExpansionText(in: command, startingAt: index, grammar: grammar)
                    index = nestedParameter.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "(" {
                    if command.index(index, offsetBy: 2, limitedBy: command.index(before: command.endIndex)) != nil,
                       command[command.index(index, offsetBy: 2)] == "(" {
                        let nestedArithmetic = try arithmeticExpansionText(in: command, startingAt: index)
                        index = nestedArithmetic.nextIndex
                    } else {
                        let nestedCommand = try commandSubstitutionText(in: command, startingAt: index, grammar: grammar)
                        index = nestedCommand.nextIndex
                    }
                    continue
                }
                if activeQuote == "\"",
                   grammar.recognizesProcessSubstitution(in: .nestedShellInput),
                   (character == "<" || character == ">"),
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "(" {
                    let nestedProcess = try MSPShellLexerProcessSubstitutionScanner.processSubstitutionText(
                        in: command,
                        startingAt: index,
                        mode: character == "<" ? .input : .output,
                        grammar: grammar
                    )
                    index = nestedProcess.nextIndex
                    continue
                }
                index = command.index(after: index)
                continue
            }

            if caseState.consumeWordCharacter(character) {
                index = command.index(after: index)
                continue
            }
            caseState.flushWord(before: character)
            if character == "'" || character == "\"" {
                caseState.enterOpaqueWordPart()
                quote = character
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                caseState.enterOpaqueWordPart()
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == "$",
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "(" {
                caseState.enterOpaqueWordPart()
                if command.index(index, offsetBy: 2, limitedBy: command.index(before: command.endIndex)) != nil,
                   command[command.index(index, offsetBy: 2)] == "(" {
                    let arithmetic = try arithmeticExpansionText(in: command, startingAt: index)
                    index = arithmetic.nextIndex
                } else {
                    let nested = try commandSubstitutionText(in: command, startingAt: index, grammar: grammar)
                    index = nested.nextIndex
                }
                continue
            }
            if grammar.recognizesProcessSubstitution(in: .nestedShellInput),
               (character == "<" || character == ">"),
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "(" {
                caseState.enterOpaqueWordPart()
                let nestedProcess = try MSPShellLexerProcessSubstitutionScanner.processSubstitutionText(
                    in: command,
                    startingAt: index,
                    mode: character == "<" ? .input : .output,
                    grammar: grammar
                )
                index = nestedProcess.nextIndex
                continue
            }
            if character == "(" {
                if !caseState.inCasePattern {
                    nestedParentheses += 1
                }
                index = command.index(after: index)
                continue
            }
            if character == ")" {
                if caseState.consumeCasePatternCloseIfNeeded() {
                    index = command.index(after: index)
                    continue
                }
                if nestedParentheses > 0 {
                    nestedParentheses -= 1
                    index = command.index(after: index)
                    continue
                }
                let next = command.index(after: index)
                return (String(command[dollarIndex..<next]), next)
            }
            let next = command.index(after: index)
            caseState.observeCaseTerminator(character, next: next < command.endIndex ? command[next] : nil)
            index = command.index(after: index)
        }

        throw ShellExit.usage("$(: unterminated command substitution")
    }

    static func arithmeticExpansionText(
        in command: String,
        startingAt dollarIndex: String.Index
    ) throws -> (text: String, nextIndex: String.Index) {
        let firstOpenIndex = command.index(after: dollarIndex)
        let secondOpenIndex = command.index(after: firstOpenIndex)
        var index = command.index(after: secondOpenIndex)
        var nestedParentheses = 0
        while index < command.endIndex {
            let character = command[index]
            if character == "\\" {
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == "(" {
                nestedParentheses += 1
                index = command.index(after: index)
                continue
            }
            if character == ")" {
                let next = command.index(after: index)
                if nestedParentheses == 0, next < command.endIndex, command[next] == ")" {
                    let afterClose = command.index(after: next)
                    return (String(command[dollarIndex..<afterClose]), afterClose)
                }
                if nestedParentheses > 0 {
                    nestedParentheses -= 1
                }
            }
            index = command.index(after: index)
        }
        throw ShellExit.usage("$((: unterminated arithmetic expansion")
    }

    static func arithmeticCommandText(
        in command: String,
        startingAt firstOpenIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) throws -> (expression: String, nextIndex: String.Index) {
        let secondOpenIndex = command.index(after: firstOpenIndex)
        var index = command.index(after: secondOpenIndex)
        var nestedParentheses = 0
        var quote: Character?
        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = command.index(after: index)
                    continue
                }
                if character == "\\" {
                    let next = command.index(after: index)
                    index = next < command.endIndex ? command.index(after: next) : next
                    continue
                }
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionText(in: command, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "{" {
                    let nestedParameter = try bracedParameterExpansionText(in: command, startingAt: index, grammar: grammar)
                    index = nestedParameter.nextIndex
                    continue
                }
                index = command.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == "(" {
                nestedParentheses += 1
                index = command.index(after: index)
                continue
            }
            if character == ")" {
                let next = command.index(after: index)
                if nestedParentheses == 0, next < command.endIndex, command[next] == ")" {
                    let expressionStart = command.index(after: secondOpenIndex)
                    return (String(command[expressionStart..<index]), command.index(after: next))
                }
                if nestedParentheses > 0 {
                    nestedParentheses -= 1
                }
            }
            index = command.index(after: index)
        }
        throw ShellExit.usage("((: unterminated arithmetic command")
    }

    static func backtickSubstitutionText(
        in command: String,
        startingAt openIndex: String.Index
    ) throws -> (text: String, nextIndex: String.Index) {
        var index = command.index(after: openIndex)
        while index < command.endIndex {
            let character = command[index]
            if character == "\\" {
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == "`" {
                let next = command.index(after: index)
                return (String(command[openIndex..<next]), next)
            }
            index = command.index(after: index)
        }
        throw ShellExit.usage("`: unterminated command substitution")
    }

    static func bracedParameterExpansionText(
        in command: String,
        startingAt dollarIndex: String.Index,
        grammar: MSPShellGrammar = .msp
    ) throws -> (text: String, nextIndex: String.Index) {
        let openIndex = command.index(after: dollarIndex)
        var index = command.index(after: openIndex)
        var depth = 1
        var quote: Character?

        while index < command.endIndex {
            let character = command[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = command.index(after: index)
                    continue
                }
                if character == "\\" {
                    let next = command.index(after: index)
                    index = next < command.endIndex ? command.index(after: next) : next
                    continue
                }
                if activeQuote == "\"", character == "`" {
                    let nestedBacktick = try backtickSubstitutionText(in: command, startingAt: index)
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "{" {
                    let nestedParameter = try bracedParameterExpansionText(in: command, startingAt: index, grammar: grammar)
                    index = nestedParameter.nextIndex
                    continue
                }
                index = command.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == "`" {
                let substitution = try backtickSubstitutionText(in: command, startingAt: index)
                index = substitution.nextIndex
                continue
            }
            if character == "$" {
                let next = command.index(after: index)
                guard next < command.endIndex else {
                    index = next
                    continue
                }
                if grammar.recognizesAnsiCQuote(in: .parameterOperationWord), command[next] == "'" {
                    let quoted = try MSPShellAnsiCQuote.quotedText(in: command, startingAt: index)
                    index = quoted.nextIndex
                    continue
                }
                if command[next] == "{" {
                    depth += 1
                    index = command.index(after: next)
                    continue
                }
                if command[next] == "(" {
                    if command.index(next, offsetBy: 1, limitedBy: command.index(before: command.endIndex)) != nil,
                       command[command.index(after: next)] == "(" {
                        let arithmetic = try arithmeticExpansionText(in: command, startingAt: index)
                        index = arithmetic.nextIndex
                    } else {
                        let nested = try commandSubstitutionText(in: command, startingAt: index, grammar: grammar)
                        index = nested.nextIndex
                    }
                    continue
                }
            }
            if grammar.recognizesProcessSubstitution(in: .parameterOperationWord),
               (character == "<" || character == ">"),
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "(" {
                let nestedProcess = try MSPShellLexerProcessSubstitutionScanner.processSubstitutionText(
                    in: command,
                    startingAt: index,
                    mode: character == "<" ? .input : .output,
                    grammar: grammar
                )
                index = nestedProcess.nextIndex
                continue
            }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    let next = command.index(after: index)
                    return (String(command[dollarIndex..<next]), next)
                }
            }
            index = command.index(after: index)
        }

        throw ShellExit.usage("${: unterminated parameter expansion")
    }
}
