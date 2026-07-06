import Foundation

extension ShellScriptParser.TokenParser {
    mutating func parseBraceGroupStage() throws -> ShellStage {
        _ = try consumeReservedWord(.leftBrace)
        let bodyTokens = try consumeTokens(
            untilTopLevelReservedWords: [.rightBrace],
            missingMessage: "syntax error: missing }"
        )
        _ = try consumeReservedWord(.rightBrace)
        return .compound(.group(
            body: try parseNestedCommandList(from: bodyTokens),
            redirections: try consumeTrailingRedirections()
        ))
    }

    mutating func parseFunctionDefinitionStage() throws -> ShellStage {
        try budget.consume()
        let nameWord: ShellWord
        if peekReservedWord() == .function {
            index += 1
            nameWord = try consumeFunctionName(context: "function: missing function name")
            if index + 1 < tokens.count,
               case .groupStart = tokens[index],
               case .groupEnd = tokens[index + 1] {
                index += 1
                index += 1
            }
        } else {
            nameWord = try consumeFunctionName(context: "syntax error near unexpected (")
            guard index < tokens.count, case .groupStart = tokens[index] else {
                throw mspShellParserUsage(.unexpectedGroupStart)
            }
            index += 1
            guard index < tokens.count, case .groupEnd = tokens[index] else {
                throw mspShellParserUsage(.unexpectedGroupEnd)
            }
            index += 1
        }
        try consumeFunctionDefinitionNewlines()
        let body = try parseFunctionDefinitionBody()
        return .functionDefinition(ShellFunctionDefinition(
            name: nameWord.rawText,
            body: body,
            redirections: try consumeTrailingRedirections()
        ))
    }

    mutating func parseFunctionDefinitionBody() throws -> ShellFunctionBody {
        if peekReservedWord() == .leftBrace {
            _ = try consumeReservedWord(.leftBrace)
            let bodyTokens = try consumeTokens(
                untilTopLevelReservedWords: [.rightBrace],
                missingMessage: "syntax error: missing }"
            )
            _ = try consumeReservedWord(.rightBrace)
            return .braceGroup(try parseNestedCommandList(from: bodyTokens))
        }

        if index < tokens.count, case .groupStart = tokens[index] {
            index += 1
            let body = try collectCompoundTokens(
                until: ShellCompoundTokenStops(groupEnd: true),
                missingMessage: "syntax error: missing )"
            )
            guard body.stop == .groupEnd else {
                throw ShellExit.usage("syntax error: missing )")
            }
            index += 1
            return .subshell(try parseNestedCommandList(from: body.tokens))
        }

        _ = try consumeReservedWord(.leftBrace)
        throw mspShellParserUsage(.expected("function body"))
    }

    mutating func parseSubshellStage() throws -> ShellStage {
        try budget.consume()
        guard index < tokens.count, case .groupStart = tokens[index] else {
            throw mspShellParserUsage(.unexpectedGroupStart)
        }
        index += 1
        let body = try collectCompoundTokens(
            until: ShellCompoundTokenStops(groupEnd: true),
            missingMessage: "syntax error: missing )"
        )
        guard body.stop == .groupEnd else {
            throw ShellExit.usage("syntax error: missing )")
        }
        index += 1
        return .compound(.subshell(
            body: try parseNestedCommandList(from: body.tokens),
            redirections: try consumeTrailingRedirections()
        ))
    }

    func isFunctionDefinitionStart() -> Bool {
        isFunctionDefinitionStart(at: index)
    }

    func isFunctionDefinitionStart(at startIndex: Int) -> Bool {
        ShellTokenClassifier.isFunctionDefinitionStart(in: tokens, at: startIndex, grammar: grammar)
    }

    func isShellFunctionName(_ value: String) -> Bool {
        ShellTokenClassifier.isFunctionName(value)
    }

    mutating func consumeTokens(
        untilTopLevelWords terminators: Set<String>,
        missingMessage: String
    ) throws -> [ShellToken] {
        let body = try collectCompoundTokens(
            until: ShellCompoundTokenStops(words: terminators),
            missingMessage: missingMessage
        )
        if case .word = body.stop {
            return body.tokens
        }
        throw ShellExit.usage(missingMessage)
    }

    mutating func consumeTokens(
        untilTopLevelReservedWords terminators: Set<ShellReservedWord>,
        missingMessage: String
    ) throws -> [ShellToken] {
        let body = try collectCompoundTokens(
            until: ShellCompoundTokenStops(reservedWords: terminators),
            missingMessage: missingMessage
        )
        if case .reservedWord = body.stop {
            return body.tokens
        }
        throw ShellExit.usage(missingMessage)
    }

    mutating func collectCompoundTokens(
        until stops: ShellCompoundTokenStops,
        missingMessage: String
    ) throws -> (tokens: [ShellToken], stop: ShellCompoundTokenStop) {
        var scanner = ShellCompoundTokenScanner(tokens: tokens, index: index, grammar: grammar)
        let result = try scanner.collect(until: stops, missingMessage: missingMessage) {
            try budget.consume()
        }
        index = result.index
        return (result.tokens, result.stop)
    }
}
