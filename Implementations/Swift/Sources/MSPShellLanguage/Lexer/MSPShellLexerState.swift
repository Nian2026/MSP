import Foundation

struct ShellLexerState {
    var grammar: MSPShellGrammar
    private(set) var tokens: [ShellToken] = []
    var current = ShellWord()
    private(set) var insideDoubleBracket = false

    mutating func appendCurrentTokenIfNeeded() {
        guard !current.isEmpty else { return }
        let rawText = current.rawText
        if let assignment = ShellAssignmentSyntax.assignment(in: current) {
            tokens.append(.assignmentWord(assignment, original: current))
        } else if let reserved = ShellReservedWord.parse(current, grammar: grammar) {
            tokens.append(.reservedWord(reserved, original: current))
        } else {
            tokens.append(.word(current))
        }
        if grammar.lexical.doubleBracketConditional, rawText == "[[" {
            insideDoubleBracket = true
        } else if grammar.lexical.doubleBracketConditional, rawText == "]]" {
            insideDoubleBracket = false
        }
        current = ShellWord()
    }

    mutating func append(_ token: ShellToken) {
        tokens.append(token)
    }

    mutating func appendRedirectionToken(_ text: String) {
        guard let parsed = ShellRedirectionSyntax.prefix(in: text, grammar: grammar),
              parsed.target == nil,
              parsed.operatorText == text else {
            appendWordToken(text)
            return
        }
        tokens.append(.redirectionOperator(
            fd: parsed.fd,
            operation: parsed.operation,
            text: parsed.operatorText
        ))
    }

    mutating func flushCommandWordBeforeRedirection() -> String {
        let rawText = current.rawText
        let isIONumber = !current.isEmpty
            && rawText.allSatisfy(\.isNumber)
            && current.parts.allSatisfy { !$0.isQuoted }
        if isIONumber {
            current = ShellWord()
            return rawText
        }
        appendCurrentTokenIfNeeded()
        return ""
    }

    private mutating func appendWordToken(_ text: String) {
        var word = ShellWord()
        word.append(text, expandable: false)
        tokens.append(.word(word))
    }
}

func mspShellExtendedGlobGroupText(
    in command: String,
    startingAt openIndex: String.Index
) -> (text: String, nextIndex: String.Index)? {
    guard openIndex < command.endIndex, command[openIndex] == "(" else {
        return nil
    }
    var quote: Character?
    var depth = 0
    var index = openIndex
    while index < command.endIndex {
        let character = command[index]
        if let activeQuote = quote {
            if character == "\\" && activeQuote == "\"" {
                let next = command.index(after: index)
                index = next < command.endIndex ? command.index(after: next) : next
                continue
            }
            if character == activeQuote {
                quote = nil
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
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 {
                let next = command.index(after: index)
                return (String(command[openIndex..<next]), next)
            }
        }
        index = command.index(after: index)
    }
    return nil
}
