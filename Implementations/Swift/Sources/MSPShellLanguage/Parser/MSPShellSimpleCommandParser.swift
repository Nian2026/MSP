import Foundation

extension ShellScriptParser.TokenParser {
    mutating func parseSimpleCommandStage() throws -> ShellStage {
        var assignments: [ShellAssignmentClause] = []
        var arrayAssignments: [ShellArrayAssignmentClause] = []
        var words: [ShellWord] = []
        var redirections: [ShellRedirectionClause] = []
        while index < tokens.count {
            try budget.consume()
            if grammar.parser.arrayAssignments,
               words.isEmpty,
               let arrayAssignment = arrayAssignmentStart(at: index) {
                arrayAssignments.append(try parseArrayAssignmentClause(from: arrayAssignment))
                continue
            }
            if ShellTokenClassifier.isSimpleCommandBoundary(tokens[index]) {
                guard !assignments.isEmpty || !arrayAssignments.isEmpty || !words.isEmpty || !redirections.isEmpty else {
                    throw mspShellParserUsage(.unexpectedControlOperator)
                }
                return simpleCommandStage(
                    assignments: assignments,
                    arrayAssignments: arrayAssignments,
                    words: words,
                    redirections: redirections
                )
            }
            switch tokens[index] {
            case .word(let word), .reservedWord(_, original: let word):
                words.append(word)
                index += 1
            case .assignmentWord(let assignment, let original):
                if grammar.parser.arrayAssignments,
                   isDeclarationBuiltinCommand(words.first),
                   assignment.value.rawText.isEmpty,
                   index + 1 < tokens.count,
                   case .groupStart = tokens[index + 1] {
                    let argument = try parseArrayAssignmentArgument(name: assignment.name, append: false)
                    words.append(argument)
                } else if words.isEmpty {
                    assignments.append(assignment)
                    index += 1
                } else {
                    words.append(original)
                    index += 1
                }
            case .redirectionOperator:
                redirections.append(try parseRedirectionClause())
            default:
                throw mspShellParserUsage(.unexpectedControlOperator)
            }
        }
        guard !assignments.isEmpty || !arrayAssignments.isEmpty || !words.isEmpty || !redirections.isEmpty else {
            throw mspShellParserUsage(.unexpectedControlOperator)
        }
        return simpleCommandStage(
            assignments: assignments,
            arrayAssignments: arrayAssignments,
            words: words,
            redirections: redirections
        )
    }

    mutating func parseArrayAssignmentStage() throws -> ShellStage {
        try budget.consume()
        guard let assignment = arrayAssignmentStart(at: index) else {
            throw mspShellParserUsage(.unexpectedGroupStart)
        }
        let clause = try parseArrayAssignmentClause(from: assignment)
        return .arrayAssignment(name: clause.name, values: clause.values, append: clause.append)
    }

    func isArrayAssignmentStart() -> Bool {
        arrayAssignmentStart(at: index) != nil
    }

    mutating func parseSubscriptAssignmentStage() throws -> ShellStage {
        try budget.consume()
        guard let assignment = subscriptAssignmentStart(at: index) else {
            throw mspShellParserUsage(.unexpectedControlOperator)
        }
        index += 1
        return .subscriptAssignment(
            name: assignment.name,
            key: assignment.key,
            value: assignment.value,
            append: assignment.append
        )
    }

    func isSubscriptAssignmentStart() -> Bool {
        subscriptAssignmentStart(at: index) != nil
    }

    private func arrayAssignmentStart(at index: Int) -> (name: String, appends: Bool)? {
        guard index + 1 < tokens.count,
              case .groupStart = tokens[index + 1] else {
            return nil
        }
        if case .assignmentWord(let assignment, let original) = tokens[index],
           assignment.value.rawText.isEmpty,
           isFullyUnquoted(original),
           mspShellVariableName(assignment.name) {
            return (assignment.name, false)
        }
        if case .word(let word) = tokens[index],
           isFullyUnquoted(word),
           word.rawText.hasSuffix("+=") {
            let name = String(word.rawText.dropLast(2))
            guard mspShellVariableName(name) else { return nil }
            return (name, true)
        }
        return nil
    }

    private func simpleCommandStage(
        assignments: [ShellAssignmentClause],
        arrayAssignments: [ShellArrayAssignmentClause],
        words: [ShellWord],
        redirections: [ShellRedirectionClause]
    ) -> ShellStage {
        if words.isEmpty, (!assignments.isEmpty || !arrayAssignments.isEmpty) {
            return .assignmentList(
                assignments: assignments,
                arrays: arrayAssignments,
                redirections: redirections
            )
        }
        return .command(ShellSimpleCommand(
            assignments: assignments,
            words: words,
            redirections: redirections
        ))
    }

    private mutating func parseArrayAssignmentClause(
        from assignment: (name: String, appends: Bool)
    ) throws -> ShellArrayAssignmentClause {
        ShellArrayAssignmentClause(
            name: assignment.name,
            values: try parseArrayAssignmentValues(),
            append: assignment.appends
        )
    }

    private mutating func parseArrayAssignmentArgument(name: String, append: Bool) throws -> ShellWord {
        let values = try parseArrayAssignmentValues()
        var word = ShellWord()
        word.append(mspShellArrayAssignmentArgumentPrefix, expandable: false, quoted: true)
        word.append(mspShellArrayAssignmentFieldSeparator, expandable: false, quoted: true)
        word.append(append ? "1" : "0", expandable: false, quoted: true)
        word.append(mspShellArrayAssignmentFieldSeparator, expandable: false, quoted: true)
        word.append(name, expandable: false, quoted: true)
        for value in values {
            word.append(mspShellArrayAssignmentFieldSeparator, expandable: false, quoted: true)
            for part in value.parts {
                word.append(part.text, expandable: part.isExpandable, quoted: true)
            }
        }
        return word
    }

    private mutating func parseArrayAssignmentValues() throws -> [ShellWord] {
        index += 1
        guard index < tokens.count, case .groupStart = tokens[index] else {
            throw mspShellParserUsage(.unexpectedGroupStart)
        }
        index += 1
        var values: [ShellWord] = []
        while index < tokens.count {
            try budget.consume()
            switch tokens[index] {
            case .word(let word), .assignmentWord(_, original: let word), .reservedWord(_, original: let word):
                values.append(word)
                index += 1
            case .redirectionOperator:
                throw ShellExit.usage("syntax error near unexpected shell redirection")
            case .separator:
                index += 1
            case .groupEnd:
                index += 1
                return values
            case .arithmeticCommand, .pipe(_), .caseTerminator(_), .groupStart:
                throw mspShellParserUsage(.unexpectedGroupStart)
            }
        }
        throw mspShellParserUsage(.unexpectedGroupStart)
    }

    private func isDeclarationBuiltinCommand(_ word: ShellWord?) -> Bool {
        guard let word, isFullyUnquoted(word) else { return false }
        switch word.rawText {
        case "declare", "typeset", "local", "readonly", "export":
            return true
        default:
            return false
        }
    }

    private func subscriptAssignmentStart(at index: Int) -> (name: String, key: ShellWord, value: ShellWord, append: Bool)? {
        guard index < tokens.count,
              case .word(let word) = tokens[index] else {
            return nil
        }
        let raw = word.rawText
        guard let openOffset = firstUnquotedCharacter("[", in: word),
              let closeOffset = firstUnquotedCharacter("]", in: word, startingAt: openOffset + 1),
              closeOffset + 1 <= raw.count else {
            return nil
        }

        let name = String(raw.prefix(openOffset))
        guard mspShellVariableName(name),
              word.hasUnquotedPrefix(name + "[") else {
            return nil
        }

        let append: Bool
        let valueStartOffset: Int
        if unquotedCharacter(at: closeOffset + 1, in: word) == "+",
           unquotedCharacter(at: closeOffset + 2, in: word) == "=" {
            append = true
            valueStartOffset = closeOffset + 3
        } else if unquotedCharacter(at: closeOffset + 1, in: word) == "=" {
            append = false
            valueStartOffset = closeOffset + 2
        } else {
            return nil
        }

        let key = slice(word, from: openOffset + 1, to: closeOffset)
        let value = slice(word, from: valueStartOffset, to: raw.count)
        return (name: name, key: key, value: value, append: append)
    }

    private func firstUnquotedCharacter(_ target: Character, in word: ShellWord, startingAt startOffset: Int = 0) -> Int? {
        var offset = 0
        for part in word.parts {
            for character in part.text {
                if offset >= startOffset, !part.isQuoted, character == target {
                    return offset
                }
                offset += 1
            }
        }
        return nil
    }

    private func unquotedCharacter(at targetOffset: Int, in word: ShellWord) -> Character? {
        guard targetOffset >= 0 else { return nil }
        var offset = 0
        for part in word.parts {
            for character in part.text {
                if offset == targetOffset {
                    return part.isQuoted ? nil : character
                }
                offset += 1
            }
        }
        return nil
    }

    private func slice(_ word: ShellWord, from startOffset: Int, to endOffset: Int) -> ShellWord {
        var output = ShellWord()
        var offset = 0
        for part in word.parts {
            let partStart = offset
            let partEnd = partStart + part.text.count
            defer { offset = partEnd }

            let overlapStart = max(startOffset, partStart)
            let overlapEnd = min(endOffset, partEnd)
            guard overlapStart < overlapEnd else { continue }

            let localStart = part.text.index(part.text.startIndex, offsetBy: overlapStart - partStart)
            let localEnd = part.text.index(part.text.startIndex, offsetBy: overlapEnd - partStart)
            output.append(String(part.text[localStart..<localEnd]), expandable: part.isExpandable, quoted: part.isQuoted)
        }
        if output.isEmpty {
            output.markPresent()
        }
        return output
    }
}
