import Foundation

enum ShellRedirectionSyntax {
    struct LexerOperator: Equatable {
        var text: String
        var nextIndex: String.Index
    }

    static let operators: [(text: String, operation: ShellRedirectionOperator)] = [
        ("&>>", .appendOutputBoth),
        ("&>", .outputBoth),
        ("<<<", .hereString),
        ("<<-", .hereDocumentStripTabs),
        ("<<", .hereDocument),
        (">>", .appendOutput),
        (">|", .clobberOutput),
        (">&", .duplicateOutput),
        ("<&", .duplicateInput),
        ("<>", .readWrite),
        (">", .output),
        ("<", .input)
    ]

    static func operators(
        compatibleWith grammar: MSPShellGrammar
    ) -> [(text: String, operation: ShellRedirectionOperator)] {
        operators.filter { candidate in
            switch candidate.operation {
            case .hereString:
                return grammar.lexical.hereString
            case .outputBoth, .appendOutputBoth:
                return grammar.lexical.outputBothRedirection
            default:
                return true
            }
        }
    }

    static func prefix(
        in value: String,
        grammar: MSPShellGrammar
    ) -> (fd: Int?, operation: ShellRedirectionOperator, operatorText: String, target: String?)? {
        let operators = operators(compatibleWith: grammar)
        if let matched = operators.first(where: { value.hasPrefix($0.text) }) {
            let target = value.count > matched.text.count
                ? String(value.dropFirst(matched.text.count))
                : nil
            return (nil, matched.operation, matched.text, target)
        }

        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty,
              let fd = Int(digits) else {
            return nil
        }
        let rest = String(value.dropFirst(digits.count))
        guard let matched = operators.first(where: { rest.hasPrefix($0.text) }),
              !matched.text.hasPrefix("&") else {
            return nil
        }
        let target = rest.count > matched.text.count
            ? String(rest.dropFirst(matched.text.count))
            : nil
        return (fd, matched.operation, "\(digits)\(matched.text)", target)
    }

    static func unexpectedTokenDisplay(
        _ text: String,
        grammar: MSPShellGrammar
    ) -> String {
        guard let parsed = prefix(in: text, grammar: grammar) else {
            return text
        }
        if let fd = parsed.fd {
            return "\(fd)"
        }
        if parsed.operatorText.hasPrefix(">") {
            return ">"
        }
        if parsed.operatorText.hasPrefix("<") {
            return "<"
        }
        return parsed.operatorText
    }

    static func lexerOperator(
        in command: String,
        startingAt start: String.Index,
        grammar: MSPShellGrammar
    ) -> LexerOperator? {
        guard start < command.endIndex else { return nil }
        switch command[start] {
        case ">":
            return outputLexerOperator(in: command, startingAt: start)
        case "<":
            return inputLexerOperator(in: command, startingAt: start, grammar: grammar)
        case "&":
            return ampersandOutputLexerOperator(in: command, startingAt: start, grammar: grammar)
        default:
            return nil
        }
    }

    private static func outputLexerOperator(
        in command: String,
        startingAt start: String.Index
    ) -> LexerOperator {
        var next = command.index(after: start)
        guard next < command.endIndex else {
            return LexerOperator(text: ">", nextIndex: next)
        }
        switch command[next] {
        case ">":
            next = command.index(after: next)
            return LexerOperator(text: ">>", nextIndex: next)
        case "&":
            next = command.index(after: next)
            return LexerOperator(text: ">&", nextIndex: next)
        case "|":
            next = command.index(after: next)
            return LexerOperator(text: ">|", nextIndex: next)
        default:
            return LexerOperator(text: ">", nextIndex: next)
        }
    }

    private static func inputLexerOperator(
        in command: String,
        startingAt start: String.Index,
        grammar: MSPShellGrammar
    ) -> LexerOperator {
        var next = command.index(after: start)
        guard next < command.endIndex else {
            return LexerOperator(text: "<", nextIndex: next)
        }
        switch command[next] {
        case "<":
            let afterSecond = command.index(after: next)
            if grammar.lexical.hereString,
               afterSecond < command.endIndex,
               command[afterSecond] == "<" {
                return LexerOperator(text: "<<<", nextIndex: command.index(after: afterSecond))
            }
            if afterSecond < command.endIndex, command[afterSecond] == "-" {
                return LexerOperator(text: "<<-", nextIndex: command.index(after: afterSecond))
            }
            return LexerOperator(text: "<<", nextIndex: afterSecond)
        case "&":
            next = command.index(after: next)
            return LexerOperator(text: "<&", nextIndex: next)
        case ">":
            next = command.index(after: next)
            return LexerOperator(text: "<>", nextIndex: next)
        default:
            return LexerOperator(text: "<", nextIndex: next)
        }
    }

    private static func ampersandOutputLexerOperator(
        in command: String,
        startingAt start: String.Index,
        grammar: MSPShellGrammar
    ) -> LexerOperator? {
        guard grammar.lexical.outputBothRedirection else { return nil }
        let next = command.index(after: start)
        guard next < command.endIndex, command[next] == ">" else {
            return nil
        }
        let afterGreater = command.index(after: next)
        if afterGreater < command.endIndex, command[afterGreater] == ">" {
            return LexerOperator(text: "&>>", nextIndex: command.index(after: afterGreater))
        }
        return LexerOperator(text: "&>", nextIndex: afterGreater)
    }
}
