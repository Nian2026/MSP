import Foundation

extension ShellScriptParser {
    struct TokenParser {
        var tokens: [ShellToken]
        var index = 0
        let grammar: MSPShellGrammar
        let budget: ParserBudget
        let depth: Int

        mutating func parsePipelines() throws -> [ShellPipeline] {
            try parseCommandList().pipelines
        }

        mutating func parseCommandList() throws -> ShellCommandList {
            var commandList = ShellCommandList()
            var nextSeparator: ShellListSeparator?

            while index < tokens.count {
                try budget.consume()
                switch ShellTokenClassifier.commandListRole(tokens[index]) {
                case .alwaysSeparator(let separator):
                    try rejectSeparatorBeforeExpectedCommand(separator, after: nextSeparator)
                    index += 1
                    continue
                case .listOperator:
                    throw mspShellParserUsage(.unexpectedControlOperator)
                case .caseTerminator(_):
                    throw mspShellParserUsage(.unexpectedControlOperator)
                case .groupEnd:
                    throw mspShellParserUsage(.unexpectedGroupEnd)
                case .pipelineSeparator:
                    throw mspShellParserUsage(.missingCommandAfterPipe)
                case .commandStart:
                    break
                }

                var negated = false
                if peekReservedWord() == .bang {
                    index += 1
                    negated = true
                }
                let parsedPipeline = try parsePipelineCommands()
                let commands = parsedPipeline.commands
                guard !commands.isEmpty else {
                    throw mspShellParserUsage(.missingCommandAtNewline)
                }
                commandList.append(
                    ShellPipeline(
                        negated: negated,
                        commands: commands,
                        pipeOperators: parsedPipeline.operators
                    ),
                    separator: nextSeparator
                )
                nextSeparator = nil

                if let separator = try consumeListSeparatorAfterPipeline() {
                    nextSeparator = separator
                }
            }

            try rejectDanglingListOperator(nextSeparator)
            return commandList
        }

        private func rejectDanglingListOperator(_ separator: ShellListSeparator?) throws {
            switch separator {
            case .and?, .or?:
                throw mspShellParserUsage(.danglingListOperator)
            case .semicolon?, .newline?, nil:
                return
            }
        }

        private func rejectSeparatorBeforeExpectedCommand(
            _ separator: ShellListSeparator,
            after previousSeparator: ShellListSeparator?
        ) throws {
            switch (previousSeparator, separator) {
            case (.and?, .semicolon), (.or?, .semicolon):
                throw mspShellParserUsage(.unexpectedToken(";"))
            default:
                return
            }
        }

        private mutating func consumeListSeparatorAfterPipeline() throws -> ShellListSeparator? {
            guard index < tokens.count else { return nil }
            switch ShellTokenClassifier.commandListRole(tokens[index]) {
            case .alwaysSeparator(let separator), .listOperator(let separator):
                index += 1
                return separator
            case .pipelineSeparator:
                throw mspShellParserUsage(.missingCommandAfterPipe)
            case .caseTerminator(_):
                throw mspShellParserUsage(.unexpectedControlOperator)
            case .groupEnd:
                throw mspShellParserUsage(.unexpectedGroupEnd)
            case .commandStart:
                if case .groupStart = tokens[index] {
                    throw mspShellParserUsage(.unexpectedGroupStart)
                }
                let token = commandStartTokenDisplay(tokens[index])
                throw mspShellParserUsage(.unexpectedToken(token))
            }
        }

        private func commandStartTokenDisplay(_ token: ShellToken) -> String {
            switch token {
            case .word(let word):
                return word.rawText
            case .assignmentWord(_, original: let word):
                return word.rawText
            case .reservedWord(_, original: let word):
                return word.rawText
            case .arithmeticCommand:
                return "(("
            case .redirectionOperator(_, _, let text):
                return redirectionUnexpectedTokenDisplay(text)
            case .pipe(let pipeOperator):
                return pipeOperator.tokenText
            case .separator(let separator):
                return separator.tokenText
            case .caseTerminator(let terminator):
                return terminator.tokenText
            case .groupStart:
                return "("
            case .groupEnd:
                return ")"
            }
        }

        private mutating func parsePipelineCommands() throws -> (
            commands: [ShellCommandNode],
            operators: [ShellPipeOperator]
        ) {
            var commands: [ShellCommandNode] = []
            var operators: [ShellPipeOperator] = []
            while index < tokens.count {
                try budget.consume()
                commands.append(ShellCommandNode(stage: try parseStage()))
                guard index < tokens.count else { break }
                if case .pipe(let pipeOperator) = tokens[index] {
                    index += 1
                    try rejectMissingCommandAfterPipe()
                    operators.append(pipeOperator)
                    continue
                }
                break
            }
            return (commands, operators)
        }

        private func rejectMissingCommandAfterPipe() throws {
            guard index < tokens.count else {
                throw mspShellParserUsage(.missingCommandAfterPipe)
            }
            switch ShellTokenClassifier.commandListRole(tokens[index]) {
            case .commandStart:
                return
            case .alwaysSeparator, .listOperator, .pipelineSeparator, .caseTerminator, .groupEnd:
                throw mspShellParserUsage(.missingCommandAfterPipe)
            }
        }

        private mutating func parseStage() throws -> ShellStage {
            try budget.consume()
            if peekReservedWord() == .ifWord {
                return try parseIfStage()
            }
            if peekReservedWord() == .whileWord {
                return try parseWhileStage()
            }
            if peekReservedWord() == .until {
                return try parseUntilStage()
            }
            if peekReservedWord() == .forWord {
                return try parseForEachStage()
            }
            if peekReservedWord() == .caseWord {
                return try parseCaseStage()
            }
            if grammar.parser.doubleBracketConditional,
               let word = peekWord(),
               isUnquotedWord(word, "[[") {
                return try parseDoubleBracketConditionalStage()
            }
            if peekReservedWord() == .leftBrace {
                return try parseBraceGroupStage()
            }
            if peekReservedWord() == .function {
                return try parseFunctionDefinitionStage()
            }
            if isFunctionDefinitionStart() {
                return try parseFunctionDefinitionStage()
            }
            if grammar.parser.arrayAssignments, isArrayAssignmentStart() {
                return try parseArrayAssignmentStage()
            }
            if grammar.parser.subscriptAssignments, isSubscriptAssignmentStart() {
                return try parseSubscriptAssignmentStage()
            }
            if grammar.parser.arithmeticCommand,
               index < tokens.count,
               case .arithmeticCommand(let expression) = tokens[index] {
                index += 1
                let redirections = try consumeTrailingRedirections()
                return .arithmeticCommand(expression: expression, redirections: redirections)
            }
            if index < tokens.count, case .groupStart = tokens[index] {
                return try parseSubshellStage()
            }
            if let reserved = peekReservedWord() {
                throw mspShellParserUsage(.unexpectedReservedWord(reserved.rawValue))
            }

            return try parseSimpleCommandStage()
        }

        func peekWord() -> ShellWord? {
            wordLike(at: index)
        }

        func peekReservedWord() -> ShellReservedWord? {
            reservedWord(at: index)
        }

        mutating func consumeWord(_ expected: String) throws -> ShellWord {
            let word = try consumeAnyWord(context: "\(expected): missing word")
            guard isUnquotedWord(word, expected) else {
                throw mspShellParserUsage(.expected(expected))
            }
            return word
        }

        mutating func consumeReservedWord(_ expected: ShellReservedWord) throws -> ShellWord {
            try budget.consume()
            guard index < tokens.count,
                  case .reservedWord(let reserved, original: let word) = tokens[index],
                  reserved == expected else {
                throw mspShellParserUsage(.expected(expected.rawValue))
            }
            index += 1
            return word
        }

        mutating func consumeAnyWord(context: String) throws -> ShellWord {
            try budget.consume()
            guard let word = wordLike(at: index) else {
                throw ShellExit.usage(context)
            }
            index += 1
            return word
        }

        mutating func consumeFunctionName(context: String) throws -> ShellWord {
            try budget.consume()
            guard index < tokens.count,
                  case .word(let word) = tokens[index],
                  isShellFunctionName(word.rawText),
                  isFullyUnquoted(word) else {
                throw ShellExit.usage(context)
            }
            index += 1
            return word
        }

        mutating func consumeAlwaysSeparators() throws {
            while index < tokens.count {
                try budget.consume()
                guard case .separator(let separator) = tokens[index],
                      separator.isCommandTerminator else { return }
                index += 1
            }
        }

        mutating func consumeFunctionDefinitionNewlines() throws {
            while index < tokens.count {
                try budget.consume()
                guard case .separator(.newline) = tokens[index] else { return }
                index += 1
            }
        }

        mutating func consumeTrailingRedirections() throws -> [ShellRedirectionClause] {
            var redirections: [ShellRedirectionClause] = []
            while index < tokens.count {
                try budget.consume()
                guard case .redirectionOperator = tokens[index] else {
                    break
                }
                redirections.append(try parseRedirectionClause())
            }
            return redirections
        }

        mutating func parseRedirectionClause() throws -> ShellRedirectionClause {
            guard case .redirectionOperator(let fd, let operation, let text) = tokens[index] else {
                throw mspShellParserUsage(.unexpectedControlOperator)
            }
            index += 1
            guard index < tokens.count,
                  let target = wordLike(at: index) else {
                throw mspShellParserUsage(.missingRedirectionTarget(text))
            }
            index += 1
            return ShellRedirectionClause(
                fd: fd,
                operation: operation,
                target: target
            )
        }

        func redirectionUnexpectedTokenDisplay(_ text: String) -> String {
            ShellRedirectionSyntax.unexpectedTokenDisplay(text, grammar: grammar)
        }

        func wordLike(at tokenIndex: Int) -> ShellWord? {
            ShellTokenClassifier.wordLike(in: tokens, at: tokenIndex)
        }

        func reservedWord(at tokenIndex: Int) -> ShellReservedWord? {
            ShellTokenClassifier.reservedWord(in: tokens, at: tokenIndex)
        }

        func isUnquotedWord(_ word: ShellWord, _ value: String) -> Bool {
            ShellTokenClassifier.isUnquotedWord(word, value)
        }

        func isFullyUnquoted(_ word: ShellWord) -> Bool {
            ShellTokenClassifier.isFullyUnquoted(word)
        }

        func isShellVariableName(_ value: String) -> Bool {
            mspShellVariableName(value)
        }

        func parseNestedPipelines(from tokens: [ShellToken]) throws -> [ShellPipeline] {
            try ShellScriptParser.pipelines(from: tokens, grammar: grammar, budget: budget, depth: depth + 1)
        }

        func parseNestedCommandList(from tokens: [ShellToken]) throws -> ShellCommandList {
            try ShellScriptParser.commandList(from: tokens, grammar: grammar, budget: budget, depth: depth + 1)
        }
    }
}
