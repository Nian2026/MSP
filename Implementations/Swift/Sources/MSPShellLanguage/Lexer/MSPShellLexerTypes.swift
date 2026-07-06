import Foundation

enum ShellCommandSubstitutionSyntax: Equatable {
    case dollarParentheses
    case backtick

    var legacy: Bool {
        self == .backtick
    }
}

struct ShellCommandSubstitution: Equatable {
    var syntax: ShellCommandSubstitutionSyntax
    var command: String
    var quoted: Bool
    var partIndex: Int
    var sourceRange: Range<Int>
    var sourceText: String

    var legacy: Bool {
        syntax.legacy
    }
}

struct ShellProcessSubstitution: Equatable {
    var mode: MSPShellProcessSubstitutionMode
    var command: String
    var quoted: Bool
    var partIndex: Int
    var markerRange: Range<Int>
    var markerText: String

    var operatorText: String {
        mode.operatorText
    }
}

struct ShellExpansionSubstitutions: Equatable {
    var commandSubstitutions: [ShellCommandSubstitution]
    var processSubstitutions: [ShellProcessSubstitution]
    var grammar: MSPShellGrammar

    static func inExpandableText(
        _ text: String,
        grammar: MSPShellGrammar
    ) throws -> ShellExpansionSubstitutions {
        try ShellExpansionSubstitutions(part: .expandable(text, quoted: false), partIndex: 0, grammar: grammar)
    }

    init(part: ShellWord.Part, partIndex: Int, grammar: MSPShellGrammar) throws {
        self.grammar = grammar
        commandSubstitutions = try part.commandSubstitutions(partIndex: partIndex, grammar: grammar)
        processSubstitutions = try part.processSubstitutions(partIndex: partIndex, grammar: grammar)
    }
}

struct ShellWord: Equatable {
    enum Part: Equatable {
        case literal(String, quoted: Bool)
        case expandable(String, quoted: Bool)

        var text: String {
            switch self {
            case .literal(let text, _), .expandable(let text, _):
                return text
            }
        }

        var isExpandable: Bool {
            if case .expandable = self { return true }
            return false
        }

        var isQuoted: Bool {
            switch self {
            case .literal(_, let quoted), .expandable(_, let quoted):
                return quoted
            }
        }
    }

    private(set) var parts: [Part] = []
    private(set) var isPresent = false

    var rawText: String {
        parts.map(\.text).joined()
    }

    var isEmpty: Bool {
        !isPresent
    }

    var hasExplicitEmptyQuotedFragment: Bool {
        parts.contains { part in
            part.text.isEmpty && part.isQuoted
        }
    }

    mutating func append(_ text: String, expandable: Bool, quoted: Bool = false) {
        isPresent = true
        guard !text.isEmpty else { return }
        if let last = parts.last,
           last.isExpandable == expandable,
           last.isQuoted == quoted {
            parts.removeLast()
            let merged = last.text + text
            parts.append(expandable ? .expandable(merged, quoted: quoted) : .literal(merged, quoted: quoted))
        } else {
            parts.append(expandable ? .expandable(text, quoted: quoted) : .literal(text, quoted: quoted))
        }
    }

    mutating func append(_ character: Character, expandable: Bool, quoted: Bool = false) {
        append(String(character), expandable: expandable, quoted: quoted)
    }

    mutating func markPresent() {
        isPresent = true
    }

    mutating func markQuoted() {
        isPresent = true
    }

    mutating func appendEmptyQuotedFragment() {
        isPresent = true
        parts.append(.literal("", quoted: true))
    }

    func hasUnquotedPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        var remaining = prefix[...]
        for part in parts {
            guard !remaining.isEmpty else { return true }
            guard !part.isQuoted else { return false }
            let text = part.text
            guard remaining.hasPrefix(text) || text.hasPrefix(remaining) else {
                return false
            }
            if remaining.count <= text.count {
                return true
            }
            remaining = remaining.dropFirst(text.count)
        }
        return remaining.isEmpty
    }

    func hasAnyUnquotedPrefix(_ prefixes: [String]) -> Bool {
        prefixes.contains { hasUnquotedPrefix($0) }
    }

    func hasAnyUnquotedSuffix(_ suffixes: [String]) -> Bool {
        suffixes.contains { hasUnquotedSuffix($0) }
    }

    func hasUnquotedSuffix(_ suffix: String) -> Bool {
        guard !suffix.isEmpty else { return true }
        var remaining = suffix[...]
        for part in parts.reversed() {
            guard !remaining.isEmpty else { return true }
            guard !part.isQuoted else { return false }
            let text = part.text
            guard remaining.hasSuffix(text) || text.hasSuffix(remaining) else {
                return false
            }
            if remaining.count <= text.count {
                return true
            }
            remaining = remaining.dropLast(text.count)
        }
        return remaining.isEmpty
    }

    func droppingUnquotedPrefix(_ prefix: String) -> ShellWord? {
        guard hasUnquotedPrefix(prefix) else { return nil }
        var remainingToDrop = prefix.count
        var output = ShellWord()
        output.isPresent = isPresent

        for part in parts {
            if remainingToDrop <= 0 {
                output.append(part.text, expandable: part.isExpandable, quoted: part.isQuoted)
                continue
            }
            guard !part.isQuoted else { return nil }
            if remainingToDrop >= part.text.count {
                remainingToDrop -= part.text.count
                continue
            }
            let keepStart = part.text.index(part.text.startIndex, offsetBy: remainingToDrop)
            output.append(String(part.text[keepStart...]), expandable: part.isExpandable, quoted: part.isQuoted)
            remainingToDrop = 0
        }

        guard remainingToDrop == 0 else { return nil }
        return output
    }

    func processSubstitutions(grammar: MSPShellGrammar) throws -> [ShellProcessSubstitution] {
        var substitutions: [ShellProcessSubstitution] = []
        for (partIndex, part) in parts.enumerated() where part.isExpandable {
            substitutions.append(contentsOf: try part.processSubstitutions(partIndex: partIndex, grammar: grammar))
        }
        return substitutions
    }

    func commandSubstitutions(grammar: MSPShellGrammar = .msp) throws -> [ShellCommandSubstitution] {
        var substitutions: [ShellCommandSubstitution] = []
        for (partIndex, part) in parts.enumerated() where part.isExpandable {
            substitutions.append(contentsOf: try part.commandSubstitutions(partIndex: partIndex, grammar: grammar))
        }
        return substitutions
    }
}

extension ShellWord.Part {
    func commandSubstitutions(
        partIndex: Int,
        grammar: MSPShellGrammar = .msp
    ) throws -> [ShellCommandSubstitution] {
        guard isExpandable else { return [] }
        return try commandSubstitutions(in: text, partIndex: partIndex, baseOffset: 0, grammar: grammar)
    }

    private func commandSubstitutions(
        in text: String,
        partIndex: Int,
        baseOffset: Int,
        grammar: MSPShellGrammar
    ) throws -> [ShellCommandSubstitution] {
        var substitutions: [ShellCommandSubstitution] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`" {
                let substitution = try MSPShellSubstitutionScanner.backtickSubstitutionCommand(
                    in: text,
                    startingAt: index
                )
                substitutions.append(ShellCommandSubstitution(
                    syntax: .backtick,
                    command: substitution.command,
                    quoted: isQuoted,
                    partIndex: partIndex,
                    sourceRange: offsetRange(in: text, from: index, to: substitution.nextIndex, baseOffset: baseOffset),
                    sourceText: String(text[index..<substitution.nextIndex])
                ))
                index = substitution.nextIndex
                continue
            }

            guard text[index] == "$" else {
                index = text.index(after: index)
                continue
            }
            let openIndex = text.index(after: index)
            guard openIndex < text.endIndex, text[openIndex] == "(" else {
                index = openIndex
                continue
            }

            let bodyStart = text.index(after: openIndex)
            if bodyStart < text.endIndex, text[bodyStart] == "(" {
                let nextIndex = try MSPShellSubstitutionScanner.arithmeticExpansionEndIndex(
                    in: text,
                    startingAt: index,
                    grammar: grammar
                )
                let closeSecondIndex = text.index(before: nextIndex)
                let closeFirstIndex = text.index(before: closeSecondIndex)
                let expressionStart = text.index(after: bodyStart)
                if expressionStart < closeFirstIndex {
                    let nestedText = String(text[expressionStart..<closeFirstIndex])
                    let nestedBaseOffset = baseOffset + text.distance(from: text.startIndex, to: expressionStart)
                    substitutions.append(contentsOf: try commandSubstitutions(
                        in: nestedText,
                        partIndex: partIndex,
                        baseOffset: nestedBaseOffset,
                        grammar: grammar
                    ))
                }
                index = nextIndex
                continue
            }

            let nextIndex = try MSPShellSubstitutionScanner.commandSubstitutionEndIndex(
                in: text,
                startingAt: index,
                grammar: grammar
            )
            let commandEnd = text.index(before: nextIndex)
            substitutions.append(ShellCommandSubstitution(
                syntax: .dollarParentheses,
                command: String(text[bodyStart..<commandEnd]),
                quoted: isQuoted,
                partIndex: partIndex,
                sourceRange: offsetRange(in: text, from: index, to: nextIndex, baseOffset: baseOffset),
                sourceText: String(text[index..<nextIndex])
            ))
            index = nextIndex
        }
        return substitutions
    }

    private func offsetRange(
        in text: String,
        from lower: String.Index,
        to upper: String.Index,
        baseOffset: Int
    ) -> Range<Int> {
        let lowerOffset = baseOffset + text.distance(from: text.startIndex, to: lower)
        let upperOffset = baseOffset + text.distance(from: text.startIndex, to: upper)
        return lowerOffset..<upperOffset
    }

    func processSubstitutions(
        partIndex: Int,
        grammar: MSPShellGrammar
    ) throws -> [ShellProcessSubstitution] {
        guard isExpandable, grammar.recognizesProcessSubstitution(in: .expandedText) else { return [] }

        var substitutions: [ShellProcessSubstitution] = []
        let text = self.text
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index...].hasPrefix(MSPShellProcessSubstitutionToken.prefix) else {
                index = text.index(after: index)
                continue
            }
            guard let token = try MSPShellProcessSubstitutionToken.decodedMarker(
                in: text,
                startingAt: index
            ) else {
                index = text.index(after: index)
                continue
            }

            let lowerOffset = text.distance(from: text.startIndex, to: index)
            let upperOffset = text.distance(from: text.startIndex, to: token.nextIndex)
            substitutions.append(ShellProcessSubstitution(
                mode: token.mode,
                command: token.command,
                quoted: isQuoted,
                partIndex: partIndex,
                markerRange: lowerOffset..<upperOffset,
                markerText: String(text[index..<token.nextIndex])
            ))
            index = token.nextIndex
        }
        return substitutions
    }
}

enum ShellReservedWord: String, Equatable {
    case ifWord = "if"
    case then = "then"
    case elseWord = "else"
    case elif = "elif"
    case fi = "fi"
    case forWord = "for"
    case whileWord = "while"
    case until = "until"
    case doWord = "do"
    case done = "done"
    case caseWord = "case"
    case esac = "esac"
    case inWord = "in"
    case function = "function"
    case leftBrace = "{"
    case rightBrace = "}"
    case bang = "!"

    static func parse(_ word: ShellWord, grammar: MSPShellGrammar) -> ShellReservedWord? {
        guard word.parts.allSatisfy({ !$0.isQuoted }) else { return nil }
        guard let reserved = ShellReservedWord(rawValue: word.rawText) else { return nil }
        if reserved == .function, !grammar.lexical.functionReservedWord {
            return nil
        }
        return reserved
    }
}

enum ShellToken: Equatable {
    case word(ShellWord)
    case assignmentWord(ShellAssignmentClause, original: ShellWord)
    case reservedWord(ShellReservedWord, original: ShellWord)
    case arithmeticCommand(String)
    case redirectionOperator(fd: Int?, operation: ShellRedirectionOperator, text: String)
    case pipe(ShellPipeOperator)
    case separator(ShellListSeparator)
    case caseTerminator(ShellCaseTerminator)
    case groupStart
    case groupEnd
}

enum ShellLexerStructuralAction: Equatable {
    case append(ShellToken, nextIndex: String.Index)
    case skip(nextIndex: String.Index)
}

enum ShellLexerStructuralSyntax {
    static func separatorAction(
        in command: String,
        startingAt index: String.Index,
        existingTokens: [ShellToken],
        grammar: MSPShellGrammar
    ) -> ShellLexerStructuralAction? {
        guard index < command.endIndex else { return nil }
        switch command[index] {
        case ";":
            let next = command.index(after: index)
            if next < command.endIndex, command[next] == ";" {
                let afterSecondSemicolon = command.index(after: next)
                if grammar.lexical.caseFallthroughTerminators,
                   afterSecondSemicolon < command.endIndex,
                   command[afterSecondSemicolon] == "&" {
                    return .append(.caseTerminator(.continueMatching), nextIndex: command.index(after: afterSecondSemicolon))
                }
                return .append(.caseTerminator(.breakArm), nextIndex: afterSecondSemicolon)
            }
            if grammar.lexical.caseFallthroughTerminators,
               next < command.endIndex,
               command[next] == "&" {
                return .append(.caseTerminator(.fallThrough), nextIndex: command.index(after: next))
            }
            return .append(.separator(.semicolon), nextIndex: next)
        case "\n":
            let next = command.index(after: index)
            if case .some(.pipe(_)) = existingTokens.last {
                return .skip(nextIndex: next)
            }
            return .append(.separator(.newline), nextIndex: next)
        default:
            return nil
        }
    }

    static func groupToken(for character: Character) -> ShellToken? {
        switch character {
        case "(":
            return .groupStart
        case ")":
            return .groupEnd
        default:
            return nil
        }
    }

    static func pipeAction(
        in command: String,
        startingAt index: String.Index,
        grammar: MSPShellGrammar
    ) -> ShellLexerStructuralAction? {
        guard index < command.endIndex, command[index] == "|" else {
            return nil
        }
        let next = command.index(after: index)
        if next < command.endIndex, command[next] == "|" {
            return .append(.separator(.or), nextIndex: command.index(after: next))
        }
        if grammar.lexical.pipeStdoutAndStderr,
           next < command.endIndex,
           command[next] == "&" {
            return .append(.pipe(.stdoutAndStderr), nextIndex: command.index(after: next))
        }
        return .append(.pipe(.stdout), nextIndex: next)
    }

    static func ampersandAction(
        in command: String,
        startingAt index: String.Index
    ) throws -> ShellLexerStructuralAction? {
        guard index < command.endIndex, command[index] == "&" else {
            return nil
        }
        let next = command.index(after: index)
        if next < command.endIndex, command[next] == "&" {
            return .append(.separator(.and), nextIndex: command.index(after: next))
        }
        throw ShellExit.usage("&: background execution is not supported")
    }
}
