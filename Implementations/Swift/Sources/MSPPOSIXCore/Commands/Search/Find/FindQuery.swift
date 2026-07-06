import Foundation
import MSPCore

struct FindQuery {
    var paths: [String]
    var expression: FindExpression
    var hasExplicitAction: Bool
    var minDepth: Int?
    var maxDepth: Int?
    var newerReferencePaths: [String]
    var requiresDepthFirstTraversal: Bool

    init(arguments: [String]) throws {
        var paths: [String] = []
        var expressionStartIndex = 0
        while expressionStartIndex < arguments.count {
            let argument = arguments[expressionStartIndex]
            guard !Self.isExpressionStart(argument) else {
                break
            }
            paths.append(argument)
            expressionStartIndex += 1
        }
        if paths.isEmpty {
            paths = ["."]
        }

        var parser = FindExpressionParser(tokens: Array(arguments.dropFirst(expressionStartIndex)))
        self.paths = paths
        self.expression = try parser.parseExpression()
        self.hasExplicitAction = parser.hasExplicitAction
        self.minDepth = parser.minDepth
        self.maxDepth = parser.maxDepth
        self.newerReferencePaths = parser.newerReferencePaths
        self.requiresDepthFirstTraversal = expression.requiresDepthFirstTraversal
    }

    private static func isExpressionStart(_ argument: String) -> Bool {
        argument.hasPrefix("-") || argument == "!" || argument == "(" || argument == "\\("
            || argument == ")" || argument == "\\)"
    }

    func childEnumerationOptions(forChildDepth childDepth: Int) -> MSPDirectoryEnumerationOptions? {
        guard let requiredType = expression.requiredMatchType else {
            return nil
        }
        if requiredType == .directory {
            return MSPDirectoryEnumerationOptions(typeFilter: [.directory])
        }
        guard let maxDepth, childDepth >= maxDepth else {
            return nil
        }
        return MSPDirectoryEnumerationOptions(typeFilter: [requiredType])
    }
}

private struct FindExpressionParser {
    var tokens: [String]
    var index = 0
    var hasExplicitAction = false
    var minDepth: Int?
    var maxDepth: Int?
    var newerReferencePaths: [String] = []

    mutating func parseExpression() throws -> FindExpression {
        guard !tokens.isEmpty else {
            return .always
        }
        let expression = try parseOrExpression()
        guard index >= tokens.count else {
            throw usage("find: unsupported expression '\(tokens[index])'\n")
        }
        return expression
    }

    private mutating func parseOrExpression() throws -> FindExpression {
        var lhs = try parseAndExpression()
        while let operatorToken = matchOrOperator() {
            try requireExpression(after: operatorToken)
            let rhs = try parseAndExpression()
            lhs = .or(lhs, rhs)
        }
        return lhs
    }

    private mutating func parseAndExpression() throws -> FindExpression {
        var lhs = try parseNotExpression()
        while index < tokens.count,
              !isRightParen(tokens[index]),
              !isOrOperator(tokens[index]) {
            if let operatorToken = matchAndOperator() {
                try requireExpression(after: operatorToken)
            }
            let rhs = try parseNotExpression()
            lhs = .and(lhs, rhs)
        }
        return lhs
    }

    private mutating func parseNotExpression() throws -> FindExpression {
        if match("!") || match("-not") {
            let operatorToken = tokens[index - 1]
            try requireExpression(after: operatorToken)
            return .not(try parseNotExpression())
        }
        return try parsePrimaryExpression()
    }

    private mutating func parsePrimaryExpression() throws -> FindExpression {
        if matchLeftParen() {
            if index < tokens.count, isRightParen(tokens[index]) {
                throw usage("find: invalid expression; empty parentheses are not allowed.\n")
            }
            let expression = try parseOrExpression()
            guard matchRightParen() else {
                throw usage("find: missing )\n")
            }
            return expression
        }

        guard index < tokens.count else {
            throw usage("find: missing expression\n")
        }
        let token = tokens[index]
        guard !isRightParen(token) else {
            throw usage("find: unexpected )\n")
        }
        index += 1

        switch token {
        case "-name":
            return .predicate(.name(pattern: try requireValue("-name"), caseInsensitive: false))
        case "-iname":
            return .predicate(.name(pattern: try requireValue("-iname"), caseInsensitive: true))
        case "-path":
            return .predicate(.path(pattern: try requireValue("-path"), caseInsensitive: false))
        case "-ipath":
            return .predicate(.path(pattern: try requireValue("-ipath"), caseInsensitive: true))
        case "-regex":
            return .predicate(.regex(pattern: try requireValue("-regex"), caseInsensitive: false))
        case "-iregex":
            return .predicate(.regex(pattern: try requireValue("-iregex"), caseInsensitive: true))
        case "-type":
            let value = try requireValue("-type")
            guard value.count == 1, let type = value.first, ["f", "d", "l"].contains(type) else {
                throw usage("find: Unknown argument to -type: \(value)\n")
            }
            return .predicate(.type(type))
        case "-true":
            return .always
        case "-false":
            return .not(.always)
        case "-empty":
            return .predicate(.empty)
        case "-readable":
            return .predicate(.readable)
        case "-writable":
            return .predicate(.writable)
        case "-executable":
            return .predicate(.executable)
        case "-newer":
            let referencePath = try requireValue("-newer")
            newerReferencePaths.append(referencePath)
            return .predicate(.newer(referencePath: referencePath))
        case "-mtime":
            return .predicate(.modifiedTime(try parseTimeComparison(
                try requireValue("-mtime"),
                option: "-mtime",
                unit: .days
            )))
        case "-mmin":
            return .predicate(.modifiedTime(try parseTimeComparison(
                try requireValue("-mmin"),
                option: "-mmin",
                unit: .minutes
            )))
        case "-size":
            return .predicate(.size(try parseSizeComparison(try requireValue("-size"))))
        case "-perm":
            return .predicate(.permission(try parsePermissionPredicate(try requireValue("-perm"))))
        case "-prune":
            return .predicate(.prune)
        case "-mindepth":
            minDepth = try nonNegativeIntegerValue(try requireValue("-mindepth"), option: "-mindepth")
            return .always
        case "-maxdepth":
            maxDepth = try nonNegativeIntegerValue(try requireValue("-maxdepth"), option: "-maxdepth")
            return .always
        case "-xdev", "-mount":
            return .always
        case "-print":
            hasExplicitAction = true
            return .action(.print(separator: "\n"))
        case "-print0":
            hasExplicitAction = true
            return .action(.print(separator: "\0"))
        case "-printf":
            hasExplicitAction = true
            return .action(.printf(try requireValue("-printf")))
        case "-delete":
            hasExplicitAction = true
            return .action(.delete)
        case "-exec":
            let template = try consumeExecTemplate()
            hasExplicitAction = true
            return .action(.exec(template.words, batch: template.batch))
        case "-quit":
            hasExplicitAction = true
            return .action(.quit)
        default:
            throw usage("find: unsupported expression '\(token)'\n")
        }
    }

    private mutating func requireValue(_ option: String) throws -> String {
        guard index < tokens.count else {
            throw usage("find: missing argument to '\(option)'\n")
        }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func consumeExecTemplate() throws -> (words: [String], batch: Bool) {
        let startIndex = index
        while index < tokens.count, tokens[index] != ";", tokens[index] != "+" {
            index += 1
        }
        guard index < tokens.count else {
            throw usage("find: missing argument to `-exec'\n")
        }
        let terminator = tokens[index]
        let template = Array(tokens[startIndex..<index])
        index += 1
        guard !template.isEmpty else {
            throw usage("find: empty -exec command\n")
        }
        if terminator == "+" {
            guard template.last == "{}" else {
                throw usage("find: in -exec ... {} +, {} must appear by itself immediately before +\n")
            }
            let placeholderCount = template.filter { $0 == "{}" }.count
            guard placeholderCount == 1 else {
                throw usage("find: in -exec ... {} +, only one {} argument is supported\n")
            }
        }
        return (template, terminator == "+")
    }

    private mutating func match(_ token: String) -> Bool {
        guard index < tokens.count, tokens[index] == token else {
            return false
        }
        index += 1
        return true
    }

    private mutating func matchLeftParen() -> Bool {
        guard index < tokens.count, isLeftParen(tokens[index]) else {
            return false
        }
        index += 1
        return true
    }

    private mutating func matchRightParen() -> Bool {
        guard index < tokens.count, isRightParen(tokens[index]) else {
            return false
        }
        index += 1
        return true
    }

    private mutating func matchAndOperator() -> String? {
        guard index < tokens.count, isAndOperator(tokens[index]) else {
            return nil
        }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func matchOrOperator() -> String? {
        guard index < tokens.count, isOrOperator(tokens[index]) else {
            return nil
        }
        defer { index += 1 }
        return tokens[index]
    }

    private func requireExpression(after operatorToken: String) throws {
        guard index < tokens.count,
              !isRightParen(tokens[index]),
              !isAndOperator(tokens[index]),
              !isOrOperator(tokens[index]) else {
            if operatorToken == "!" {
                throw usage("find: expected an expression after '!'\n")
            }
            throw usage("find: missing expression after \(operatorToken)\n")
        }
    }

    private func isLeftParen(_ token: String) -> Bool {
        token == "(" || token == "\\("
    }

    private func isRightParen(_ token: String) -> Bool {
        token == ")" || token == "\\)"
    }

    private func isAndOperator(_ token: String) -> Bool {
        token == "-a" || token == "-and"
    }

    private func isOrOperator(_ token: String) -> Bool {
        token == "-o" || token == "-or"
    }

    private func nonNegativeIntegerValue(_ value: String, option: String) throws -> Int {
        guard let intValue = Int(value), intValue >= 0 else {
            throw usage("find: Expected a positive decimal integer argument to \(option), but got \(mspPOSIXFindQuote(value))\n")
        }
        return intValue
    }

    private func parseSizeComparison(_ rawValue: String) throws -> FindSizeComparison {
        let parsed = try parseNumericValueWithSuffix(
            rawValue,
            option: "-size",
            suffixParser: parseSizeUnitSuffix
        )
        return FindSizeComparison(value: parsed.value, unit: parsed.unit)
    }

    private func parseTimeComparison(
        _ rawValue: String,
        option: String,
        unit: FindTimeUnit
    ) throws -> FindTimeComparison {
        FindTimeComparison(
            value: try parseNumericValue(rawValue, option: option),
            unit: unit
        )
    }

    private func parseNumericValue(
        _ rawValue: String,
        option: String
    ) throws -> FindNumericPredicateValue {
        let parsed = try parseNumericValueWithSuffix(
            rawValue,
            option: option,
            suffixParser: { suffix in
                guard suffix.isEmpty else {
                    throw usage("find: unsupported \(option) suffix \(suffix)\n")
                }
            }
        )
        return parsed.value
    }

    private func parseNumericValueWithSuffix<Unit>(
        _ rawValue: String,
        option: String,
        suffixParser: (String) throws -> Unit
    ) throws -> (value: FindNumericPredicateValue, unit: Unit) {
        guard !rawValue.isEmpty else {
            throw usage("find: \(option) requires a value\n")
        }

        let relation: FindPredicateRelation
        let numberStart: String.Index
        switch rawValue.first {
        case "+":
            relation = .greaterThan
            numberStart = rawValue.index(after: rawValue.startIndex)
        case "-":
            relation = .lessThan
            numberStart = rawValue.index(after: rawValue.startIndex)
        default:
            relation = .equal
            numberStart = rawValue.startIndex
        }

        var numberEnd = numberStart
        while numberEnd < rawValue.endIndex, rawValue[numberEnd].isNumber {
            numberEnd = rawValue.index(after: numberEnd)
        }
        guard numberStart < numberEnd,
              let count = Int64(String(rawValue[numberStart..<numberEnd])) else {
            throw usage("find: invalid \(option) value \(rawValue)\n")
        }
        let suffix = String(rawValue[numberEnd...])
        return (
            FindNumericPredicateValue(relation: relation, count: count),
            try suffixParser(suffix)
        )
    }

    private func parseSizeUnitSuffix(_ suffix: String) throws -> FindSizeUnit {
        switch suffix {
        case "", "b":
            return .blocks
        case "c":
            return .bytes
        case "k":
            return .kibibytes
        case "M":
            return .mebibytes
        case "G":
            return .gibibytes
        default:
            throw usage("find: unsupported -size suffix \(suffix)\n")
        }
    }

    private func parsePermissionPredicate(_ rawValue: String) throws -> FindPermissionPredicate {
        guard !rawValue.isEmpty else {
            throw usage("find: -perm requires a mode\n")
        }
        let match: FindPermissionMatch
        let modeText: Substring
        switch rawValue.first {
        case "-":
            match = .all
            modeText = rawValue.dropFirst()
        case "/":
            match = .any
            modeText = rawValue.dropFirst()
        default:
            match = .exact
            modeText = rawValue[...]
        }
        guard !modeText.isEmpty,
              modeText.allSatisfy({ $0 >= "0" && $0 <= "7" }),
              let mode = UInt16(String(modeText), radix: 8) else {
            throw usage("find: invalid -perm mode \(rawValue)\n")
        }
        return FindPermissionPredicate(mode: mode, match: match)
    }

    private func usage(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(exitCode: 1, stderr: message))
    }
}
