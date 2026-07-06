import Foundation

extension ShellScriptParser.TokenParser {
    mutating func parseCaseStage() throws -> ShellStage {
        _ = try consumeReservedWord(.caseWord)
        let subject = try consumeAnyWord(context: "case: missing word")
        try consumeAlwaysSeparators()
        _ = try consumeReservedWord(.inWord)
        try consumeAlwaysSeparators()

        var arms: [ShellCaseArm] = []
        while index < tokens.count {
            try budget.consume()
            try consumeAlwaysSeparators()
            if peekReservedWord() == .esac {
                index += 1
                return .compound(.caseOf(
                    subject: subject,
                    arms: arms,
                    redirections: try consumeTrailingRedirections()
                ))
            }

            let patterns = try consumeCasePatterns()
            try consumeAlwaysSeparators()

            let body = try collectCompoundTokens(
                until: ShellCompoundTokenStops(reservedWords: [.esac], caseTerminator: true),
                missingMessage: "case: missing esac"
            )
            let terminator: ShellCaseTerminator?
            if case .caseTerminator(let value) = body.stop {
                terminator = value
                index += 1
            } else {
                terminator = nil
            }

            arms.append(ShellCaseArm(
                patterns: patterns,
                body: try parseNestedCommandList(from: body.tokens),
                terminator: terminator ?? .breakArm
            ))

            if terminator == nil,
               peekReservedWord() == .esac {
                continue
            }
        }

        throw ShellExit.usage("case: missing esac")
    }

    mutating func consumeCasePatterns() throws -> [ShellWord] {
        var patterns: [ShellWord] = []
        var current = ShellWord()

        func append(_ word: ShellWord) {
            for part in word.parts {
                current.append(part.text, expandable: part.isExpandable, quoted: part.isQuoted)
            }
        }

        func appendLiteral(_ text: String) {
            current.append(text, expandable: false)
        }

        while index < tokens.count {
            try budget.consume()
            switch tokens[index] {
            case .word(let word), .assignmentWord(_, original: let word), .reservedWord(_, original: let word):
                append(word)
                index += 1
            case .groupEnd:
                index += 1
                patterns.append(current)
                return patterns
            case .groupStart:
                appendLiteral("(")
                index += 1
            case .pipe(_):
                patterns.append(current)
                current = ShellWord()
                index += 1
            case .redirectionOperator(_, _, let text):
                throw mspShellParserUsage(.unexpectedToken(redirectionUnexpectedTokenDisplay(text)))
            case .arithmeticCommand:
                throw mspShellParserUsage(.unexpectedToken("(("))
            case .separator, .caseTerminator(_):
                throw ShellExit.usage("case: missing )")
            }
        }
        throw ShellExit.usage("case: missing )")
    }
}
