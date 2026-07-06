import Foundation

extension ShellScriptParser.TokenParser {
    mutating func parseWhileStage() throws -> ShellStage {
        _ = try consumeReservedWord(.whileWord)
        let conditionTokens = try consumeTokens(untilTopLevelReservedWords: [.doWord], missingMessage: "while: missing do")
        _ = try consumeReservedWord(.doWord)

        let bodyTokens = try consumeTokens(untilTopLevelReservedWords: [.done], missingMessage: "while: missing done")
        _ = try consumeReservedWord(.done)
        let body = try parseNestedCommandList(from: bodyTokens)

        if let spec = try whileReadSpec(from: conditionTokens) {
            return .compound(.whileRead(
                spec: spec,
                body: body,
                redirections: try consumeTrailingRedirections()
            ))
        }
        return .compound(.whileLoop(
            condition: try parseNestedCommandList(from: conditionTokens),
            body: body,
            redirections: try consumeTrailingRedirections()
        ))
    }

    mutating func parseUntilStage() throws -> ShellStage {
        _ = try consumeReservedWord(.until)
        let conditionTokens = try consumeTokens(untilTopLevelReservedWords: [.doWord], missingMessage: "until: missing do")
        _ = try consumeReservedWord(.doWord)

        let bodyTokens = try consumeTokens(untilTopLevelReservedWords: [.done], missingMessage: "until: missing done")
        _ = try consumeReservedWord(.done)

        return .compound(.untilLoop(
            condition: try parseNestedCommandList(from: conditionTokens),
            body: try parseNestedCommandList(from: bodyTokens),
            redirections: try consumeTrailingRedirections()
        ))
    }

    func whileReadSpec(from rawTokens: [ShellToken]) throws -> ShellReadSpec? {
        let tokens = trimmedAlwaysSeparators(rawTokens)
        var cursor = 0
        var assignments: [ShellAssignmentClause] = []
        while cursor < tokens.count,
              let assignment = leadingWhileReadAssignment(tokens[cursor]) {
            try budget.consume()
            assignments.append(assignment)
            cursor += 1
        }
        guard cursor < tokens.count,
              let readWord = wordLike(tokens[cursor]),
              isUnquotedRawWord(readWord, "read") else {
            return nil
        }
        cursor += 1
        var delimiter: String?
        var parsingOptions = true
        while cursor < tokens.count,
              let word = wordLike(tokens[cursor]) {
            try budget.consume()
            let raw = word.rawText
            guard parsingOptions, raw.hasPrefix("-"), raw != "-" else {
                break
            }
            if raw == "--" {
                parsingOptions = false
                cursor += 1
                continue
            }
            var characters = Array(raw.dropFirst())
            while let option = characters.first {
                try budget.consume()
                characters.removeFirst()
                switch option {
                case "r":
                    continue
                case "d":
                    if characters.isEmpty {
                        cursor += 1
                        guard cursor < tokens.count,
                              let delimiterWord = wordLike(tokens[cursor]) else {
                            return nil
                        }
                        delimiter = delimiterWord.rawText
                    } else {
                        delimiter = String(characters)
                        characters.removeAll()
                    }
                default:
                    return nil
                }
            }
            cursor += 1
        }

        var names: [String] = []
        while cursor < tokens.count {
            guard let variableWord = wordLike(tokens[cursor]) else {
                return nil
            }
            let variable = variableWord.rawText
            guard isShellVariableName(variable) else {
                return nil
            }
            names.append(variable)
            cursor += 1
        }
        if names.isEmpty {
            names = ["REPLY"]
        }
        return ShellReadSpec(assignments: assignments, names: names, delimiter: delimiter)
    }

    private func leadingWhileReadAssignment(_ token: ShellToken) -> ShellAssignmentClause? {
        switch token {
        case .assignmentWord(let assignment, _):
            return assignment
        case .word(let word):
            return ShellAssignmentSyntax.assignment(in: word)
        default:
            return nil
        }
    }

    private func isUnquotedRawWord(_ word: ShellWord, _ value: String) -> Bool {
        word.rawText == value && word.parts.allSatisfy { !$0.isQuoted }
    }

    private func wordLike(_ token: ShellToken) -> ShellWord? {
        ShellTokenClassifier.wordLike(token)
    }

    func trimmedAlwaysSeparators(_ rawTokens: [ShellToken]) -> [ShellToken] {
        var tokens = rawTokens
        while tokens.first.map(isAlwaysSeparator) == true {
            tokens.removeFirst()
        }
        while tokens.last.map(isAlwaysSeparator) == true {
            tokens.removeLast()
        }
        return tokens
    }

    func isAlwaysSeparator(_ token: ShellToken) -> Bool {
        if case .separator(let separator) = token {
            return separator.isCommandTerminator
        }
        return false
    }

    mutating func parseForEachStage() throws -> ShellStage {
        _ = try consumeReservedWord(.forWord)
        try consumeAlwaysSeparators()
        if grammar.parser.cStyleFor,
           index < tokens.count,
           case .arithmeticCommand(let headerExpression) = tokens[index] {
            index += 1
            let header = try splitCStyleForHeader(headerExpression)
            try consumeAlwaysSeparators()
            _ = try consumeReservedWord(.doWord)

            let body = try collectCompoundTokens(
                until: ShellCompoundTokenStops(reservedWords: [.done]),
                missingMessage: "for: missing done"
            )
            guard body.stop == .reservedWord(.done) else {
                throw ShellExit.usage("for: missing done")
            }
            _ = try consumeReservedWord(.done)

            return .compound(.cStyleFor(
                initExpression: header.initExpression,
                conditionExpression: header.conditionExpression,
                updateExpression: header.updateExpression,
                body: try parseNestedCommandList(from: body.tokens),
                redirections: try consumeTrailingRedirections()
            ))
        }
        let variableWord = try consumeAnyWord(context: "for: missing variable")
        let variable = variableWord.rawText
        guard isShellVariableName(variable) else {
            throw ShellExit.usage("for: invalid variable name \(variable)")
        }
        var values: [ShellWord] = []
        let valueMode: ShellForValues
        if peekReservedWord() == .inWord {
            index += 1
            while index < tokens.count {
                try budget.consume()
                if case .separator(let separator) = tokens[index],
                   separator.isCommandTerminator {
                    break
                }
                if reservedWord(at: index) == .doWord {
                    break
                }
                if case .redirectionOperator(_, _, let text) = tokens[index] {
                    throw mspShellParserUsage(.unexpectedToken(redirectionUnexpectedTokenDisplay(text)))
                }
                guard let word = wordLike(at: index) else {
                    throw mspShellParserUsage(.scopedUnexpectedControlOperator("for"))
                }
                values.append(word)
                index += 1
            }
            valueMode = .explicit(values)
        } else {
            valueMode = .positionalParameters
        }

        try consumeAlwaysSeparators()
        _ = try consumeReservedWord(.doWord)

        let body = try collectCompoundTokens(
            until: ShellCompoundTokenStops(reservedWords: [.done]),
            missingMessage: "for: missing done"
        )
        guard body.stop == .reservedWord(.done) else {
            throw ShellExit.usage("for: missing done")
        }
        _ = try consumeReservedWord(.done)

        return .compound(.forEach(
            variable: variable,
            values: valueMode,
            body: try parseNestedCommandList(from: body.tokens),
            redirections: try consumeTrailingRedirections()
        ))
    }

    struct ShellCStyleForHeader {
        var initExpression: String
        var conditionExpression: String
        var updateExpression: String
    }

    func splitCStyleForHeader(_ expression: String) throws -> ShellCStyleForHeader {
        var parts = [""]
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in expression {
            if escaped {
                parts[parts.count - 1].append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                parts[parts.count - 1].append(character)
                escaped = true
                continue
            }
            if let activeQuote = quote {
                parts[parts.count - 1].append(character)
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                quote = character
                parts[parts.count - 1].append(character)
                continue
            }
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                parts[parts.count - 1].append(character)
                continue
            }
            if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
                parts[parts.count - 1].append(character)
                continue
            }
            if character == ";", depth == 0 {
                parts.append("")
                continue
            }
            parts[parts.count - 1].append(character)
        }
        while parts.count < 3 {
            parts.append("")
        }
        guard parts.count == 3 else {
            throw ShellExit.usage("for: too many `;' in arithmetic for header")
        }
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ShellCStyleForHeader(
            initExpression: trim(parts[0]),
            conditionExpression: trim(parts[1]),
            updateExpression: trim(parts[2])
        )
    }
}
