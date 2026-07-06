import Foundation

enum MSPShellLexerProcessSubstitutionScanner {
    static func processSubstitutionText(
        in command: String,
        startingAt operatorIndex: String.Index,
        mode: MSPShellProcessSubstitutionMode,
        grammar: MSPShellGrammar = .msp
    ) throws -> (text: String, nextIndex: String.Index) {
        let openIndex = command.index(after: operatorIndex)
        var index = command.index(after: openIndex)
        var depth = 1
        var quote: Character?
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
                    let nestedBacktick = try MSPShellLexerSubstitutionScanner.backtickSubstitutionText(
                        in: command,
                        startingAt: index
                    )
                    index = nestedBacktick.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "{" {
                    let nestedParameter = try MSPShellLexerSubstitutionScanner.bracedParameterExpansionText(
                        in: command,
                        startingAt: index,
                        grammar: grammar
                    )
                    index = nestedParameter.nextIndex
                    continue
                }
                if activeQuote == "\"",
                   character == "$",
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "(" {
                    if command.index(index, offsetBy: 2, limitedBy: command.index(before: command.endIndex)) != nil,
                       command[command.index(index, offsetBy: 2)] == "(" {
                        let nestedArithmetic = try MSPShellLexerSubstitutionScanner.arithmeticExpansionText(
                            in: command,
                            startingAt: index
                        )
                        index = nestedArithmetic.nextIndex
                    } else {
                        let nestedCommand = try MSPShellLexerSubstitutionScanner.commandSubstitutionText(
                            in: command,
                            startingAt: index,
                            grammar: grammar
                        )
                        index = nestedCommand.nextIndex
                    }
                    continue
                }
                if activeQuote == "\"",
                   grammar.recognizesProcessSubstitution(in: .nestedShellInput),
                   (character == "<" || character == ">"),
                   command.index(after: index) < command.endIndex,
                   command[command.index(after: index)] == "(" {
                    let nestedProcess = try processSubstitutionText(
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
            if character == "(" {
                if !caseState.inCasePattern {
                    depth += 1
                }
                index = command.index(after: index)
                continue
            }
            if character == ")" {
                if caseState.consumeCasePatternCloseIfNeeded() {
                    index = command.index(after: index)
                    continue
                }
                depth -= 1
                if depth == 0 {
                    let next = command.index(after: index)
                    let commandStart = command.index(after: openIndex)
                    let nestedCommand = String(command[commandStart..<index])
                    let encoded = MSPShellProcessSubstitutionToken.encoded(command: nestedCommand, mode: mode)
                    return (encoded, next)
                }
            }
            let next = command.index(after: index)
            caseState.observeCaseTerminator(character, next: next < command.endIndex ? command[next] : nil)
            index = command.index(after: index)
        }

        throw ShellExit.usage("\(mode.operatorText)(: unterminated process substitution")
    }
}
