import Foundation

enum ShellLexer {
    static func tokens(
        from command: String,
        grammar: MSPShellGrammar = .msp
    ) throws -> [ShellToken] {
        let command = try MSPShellHereDocumentPreprocessor.commandWithEncodedHereDocuments(
            command,
            grammar: grammar
        )
        var state = ShellLexerState(grammar: grammar)
        var index = command.startIndex
        var quote: Character?
        var quoteStartSnapshot: ShellLexerQuoteStartSnapshot?

        while index < command.endIndex {
            let character = command[index]

            if let activeQuote = quote {
                if character == activeQuote {
                    if quoteStartSnapshot?.isUnchanged(in: state.current) == true {
                        state.current.appendEmptyQuotedFragment()
                    }
                    quote = nil
                    quoteStartSnapshot = nil
                    index = command.index(after: index)
                    continue
                }
                if character == "\\" && activeQuote == "\"" {
                    let next = command.index(after: index)
                    if next < command.endIndex {
                        if command[next] == "\n" {
                            index = command.index(after: next)
                            continue
                        }
                        if MSPShellLexerSubstitutionScanner.doubleQuoteEscapableCharacters.contains(command[next]) {
                            state.current.append(command[next], expandable: false, quoted: true)
                        } else {
                            state.current.append(character, expandable: false, quoted: true)
                            state.current.append(command[next], expandable: false, quoted: true)
                        }
                        index = command.index(after: next)
                    } else {
                        state.current.append(character, expandable: false, quoted: true)
                        index = next
                    }
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "{" {
                    let parameter = try MSPShellLexerSubstitutionScanner.bracedParameterExpansionText(
                        in: command,
                        startingAt: index,
                        grammar: grammar
                    )
                    state.current.append(parameter.text, expandable: true, quoted: true)
                    index = parameter.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "(" {
                    if command.index(index, offsetBy: 2, limitedBy: command.index(before: command.endIndex)) != nil,
                       command[command.index(index, offsetBy: 2)] == "(" {
                        let substitution = try MSPShellLexerSubstitutionScanner.arithmeticExpansionText(in: command, startingAt: index)
                        state.current.append(substitution.text, expandable: true, quoted: true)
                        index = substitution.nextIndex
                        continue
                    }
                    let substitution = try MSPShellLexerSubstitutionScanner.commandSubstitutionText(
                        in: command,
                        startingAt: index,
                        grammar: grammar
                    )
                    state.current.append(substitution.text, expandable: true, quoted: true)
                    index = substitution.nextIndex
                    continue
                }
                if activeQuote == "\"", character == "`" {
                    let substitution = try MSPShellLexerSubstitutionScanner.backtickSubstitutionText(
                        in: command,
                        startingAt: index
                    )
                    state.current.append(substitution.text, expandable: true, quoted: true)
                    index = substitution.nextIndex
                    continue
                }
                state.current.append(character, expandable: activeQuote != "'", quoted: true)
                index = command.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                state.current.markQuoted()
                quote = character
                quoteStartSnapshot = ShellLexerQuoteStartSnapshot(word: state.current)
                index = command.index(after: index)
                continue
            }

            if grammar.recognizesAnsiCQuote(in: .lexerWord),
               character == "$",
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "'" {
                let quoted = try MSPShellAnsiCQuote.quotedText(in: command, startingAt: index)
                state.current.markQuoted()
                if quoted.text.isEmpty {
                    state.current.appendEmptyQuotedFragment()
                } else {
                    state.current.append(quoted.text, expandable: false, quoted: true)
                }
                index = quoted.nextIndex
                continue
            }

            if character == "$",
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "{" {
                let parameter = try MSPShellLexerSubstitutionScanner.bracedParameterExpansionText(
                    in: command,
                    startingAt: index,
                    grammar: grammar
                )
                state.current.append(parameter.text, expandable: true)
                index = parameter.nextIndex
                continue
            }

            if character == "\\" {
                let next = command.index(after: index)
                if next < command.endIndex {
                    if command[next] == "\n" {
                        index = command.index(after: next)
                        continue
                    }
                    state.current.append(command[next], expandable: false, quoted: true)
                    index = command.index(after: next)
                } else {
                    state.current.append(character, expandable: false, quoted: true)
                    index = next
                }
                continue
            }

            if character == "#", state.current.isEmpty {
                index = command.index(after: index)
                while index < command.endIndex, command[index] != "\n" {
                    index = command.index(after: index)
                }
                continue
            }

            if character == "$",
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "(" {
                if command.index(index, offsetBy: 2, limitedBy: command.index(before: command.endIndex)) != nil,
                   command[command.index(index, offsetBy: 2)] == "(" {
                    let substitution = try MSPShellLexerSubstitutionScanner.arithmeticExpansionText(in: command, startingAt: index)
                    state.current.append(substitution.text, expandable: true)
                    index = substitution.nextIndex
                    continue
                }
                let substitution = try MSPShellLexerSubstitutionScanner.commandSubstitutionText(
                    in: command,
                    startingAt: index,
                    grammar: grammar
                )
                state.current.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }

            if character == "`" {
                let substitution = try MSPShellLexerSubstitutionScanner.backtickSubstitutionText(in: command, startingAt: index)
                state.current.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }

            if grammar.recognizesProcessSubstitution(in: .lexerWord),
               character == "<",
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "(" {
                let substitution = try MSPShellLexerProcessSubstitutionScanner.processSubstitutionText(
                    in: command,
                    startingAt: index,
                    mode: .input,
                    grammar: grammar
                )
                state.current.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }

            if grammar.recognizesProcessSubstitution(in: .lexerWord),
               character == ">",
               command.index(after: index) < command.endIndex,
               command[command.index(after: index)] == "(" {
                let substitution = try MSPShellLexerProcessSubstitutionScanner.processSubstitutionText(
                    in: command,
                    startingAt: index,
                    mode: .output,
                    grammar: grammar
                )
                state.current.append(substitution.text, expandable: true)
                index = substitution.nextIndex
                continue
            }

            if (character == ">" || character == "<"), !state.insideDoubleBracket {
                let ioPrefix = state.flushCommandWordBeforeRedirection()
                let parsed = ShellRedirectionSyntax.lexerOperator(in: command, startingAt: index, grammar: grammar)
                    ?? ShellRedirectionSyntax.LexerOperator(text: String(character), nextIndex: command.index(after: index))
                state.appendRedirectionToken(ioPrefix + parsed.text)
                index = parsed.nextIndex
                continue
            }

            if character == "\n" || character == ";" {
                state.appendCurrentTokenIfNeeded()
                if let action = ShellLexerStructuralSyntax.separatorAction(
                    in: command,
                    startingAt: index,
                    existingTokens: state.tokens,
                    grammar: grammar
                ) {
                    switch action {
                    case .append(let token, let nextIndex):
                        state.append(token)
                        index = nextIndex
                    case .skip(let nextIndex):
                        index = nextIndex
                    }
                }
                continue
            }

            if character == "(" {
                if state.insideDoubleBracket {
                    state.current.append(character, expandable: true)
                    index = command.index(after: index)
                    continue
                }
                if grammar.lexical.extendedGlob,
                   state.current.hasAnyUnquotedSuffix(["@", "!", "+", "*", "?"]),
                   let group = mspShellExtendedGlobGroupText(in: command, startingAt: index) {
                    state.current.append(group.text, expandable: true)
                    index = group.nextIndex
                    continue
                }
                if grammar.lexical.arithmeticCommand,
                   state.current.isEmpty,
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "(" {
                    let arithmetic = try MSPShellLexerSubstitutionScanner.arithmeticCommandText(
                        in: command,
                        startingAt: index,
                        grammar: grammar
                    )
                    state.append(.arithmeticCommand(arithmetic.expression))
                    index = arithmetic.nextIndex
                    continue
                }
                if let token = ShellLexerStructuralSyntax.groupToken(for: character) {
                    state.appendCurrentTokenIfNeeded()
                    state.append(token)
                }
                index = command.index(after: index)
                continue
            }

            if character == ")" {
                if state.insideDoubleBracket {
                    state.current.append(character, expandable: true)
                    index = command.index(after: index)
                    continue
                }
                if let token = ShellLexerStructuralSyntax.groupToken(for: character) {
                    state.appendCurrentTokenIfNeeded()
                    state.append(token)
                }
                index = command.index(after: index)
                continue
            }

            if character.isWhitespace {
                state.appendCurrentTokenIfNeeded()
                index = command.index(after: index)
                continue
            }

            if character == "|" {
                if state.insideDoubleBracket {
                    state.current.append(character, expandable: true)
                    index = command.index(after: index)
                    continue
                }
                state.appendCurrentTokenIfNeeded()
                if let action = ShellLexerStructuralSyntax.pipeAction(in: command, startingAt: index, grammar: grammar),
                   case .append(let token, let nextIndex) = action {
                    state.append(token)
                    index = nextIndex
                }
                continue
            }

            if character == "&" {
                if state.insideDoubleBracket {
                    state.current.append(character, expandable: true)
                    index = command.index(after: index)
                    continue
                }
                let next = command.index(after: index)
                if let parsed = ShellRedirectionSyntax.lexerOperator(in: command, startingAt: index, grammar: grammar) {
                    state.appendCurrentTokenIfNeeded()
                    state.appendRedirectionToken(parsed.text)
                    index = parsed.nextIndex
                    continue
                }
                if !state.current.isEmpty,
                   state.current.rawText.hasSuffix(">"),
                   next < command.endIndex,
                   command[next].isNumber {
                    state.current.append(character, expandable: true)
                    state.current.append(command[next], expandable: true)
                    index = command.index(after: next)
                    continue
                }
                state.appendCurrentTokenIfNeeded()
                if let action = try ShellLexerStructuralSyntax.ampersandAction(in: command, startingAt: index),
                   case .append(let token, let nextIndex) = action {
                    state.append(token)
                    index = nextIndex
                }
                continue
            }

            state.current.append(character, expandable: true)
            index = command.index(after: index)
        }

        if let quote {
            throw ShellExit.usage("unterminated \(quote) quote")
        }
        state.appendCurrentTokenIfNeeded()
        return state.tokens
    }

}

private struct ShellLexerQuoteStartSnapshot {
    private let partCount: Int
    private let rawTextCount: Int

    init(word: ShellWord) {
        partCount = word.parts.count
        rawTextCount = word.rawText.count
    }

    func isUnchanged(in word: ShellWord) -> Bool {
        word.parts.count == partCount && word.rawText.count == rawTextCount
    }
}
