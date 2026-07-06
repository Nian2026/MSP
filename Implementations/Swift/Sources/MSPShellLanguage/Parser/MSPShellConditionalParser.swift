import Foundation

extension ShellScriptParser.TokenParser {
    mutating func parseDoubleBracketConditionalStage() throws -> ShellStage {
        _ = try consumeWord("[[")
        var words: [ShellWord] = []
        while index < tokens.count {
            try budget.consume()
            guard let word = wordLike(at: index) else {
                throw ShellExit.usage("[[: missing ]]")
            }
            index += 1
            if isUnquotedWord(word, "]]") {
                return .compound(.conditional(
                    words: words,
                    redirections: try consumeTrailingRedirections()
                ))
            }
            words.append(word)
        }
        throw ShellExit.usage("[[: missing ]]")
    }

    mutating func parseIfStage() throws -> ShellStage {
        _ = try consumeReservedWord(.ifWord)
        let firstCondition = try consumeTokens(untilTopLevelReservedWords: [.then], missingMessage: "if: missing then")
        _ = try consumeReservedWord(.then)
        var branches: [ShellIfBranch] = []
        var bodyTokens = try consumeTokens(untilTopLevelReservedWords: [.elif, .elseWord, .fi], missingMessage: "if: missing fi")
        branches.append(ShellIfBranch(
            condition: try parseNestedCommandList(from: firstCondition),
            body: try parseNestedCommandList(from: bodyTokens)
        ))

        while peekReservedWord() == .elif {
            try budget.consume()
            index += 1
            let conditionTokens = try consumeTokens(untilTopLevelReservedWords: [.then], missingMessage: "elif: missing then")
            _ = try consumeReservedWord(.then)
            bodyTokens = try consumeTokens(untilTopLevelReservedWords: [.elif, .elseWord, .fi], missingMessage: "if: missing fi")
            branches.append(ShellIfBranch(
                condition: try parseNestedCommandList(from: conditionTokens),
                body: try parseNestedCommandList(from: bodyTokens)
            ))
        }

        var elseBody = ShellCommandList()
        if peekReservedWord() == .elseWord {
            index += 1
            let elseTokens = try consumeTokens(untilTopLevelReservedWords: [.fi], missingMessage: "if: missing fi")
            elseBody = try parseNestedCommandList(from: elseTokens)
        }
        _ = try consumeReservedWord(.fi)
        return .compound(.ifThen(
            branches: branches,
            elseBody: elseBody,
            redirections: try consumeTrailingRedirections()
        ))
    }
}
