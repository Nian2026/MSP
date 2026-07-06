import Foundation

enum MSPPOSIXAwkExpressionParser {
    typealias ExpressionNode = MSPPOSIXAwkRunner.ExpressionNode
    typealias LValueNode = MSPPOSIXAwkRunner.LValueNode

    static func parse(_ expression: String) -> ExpressionNode {
        let trimmed = MSPPOSIXAwkSyntax.strippingOuterParens(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        if let parsed = TokenPrecedenceParser.parse(trimmed) {
            return parsed
        }
        if let getline = parseGetlineExpression(trimmed) {
            return getline
        }
        if let mutation = parseMutation(trimmed) {
            return mutation
        }
        if let assignment = parseAssignment(trimmed) {
            return assignment
        }
        if let call = MSPPOSIXAwkSyntax.parseFunctionCall(trimmed) {
            return .functionCall(name: call.name, arguments: parseArgumentList(call.arguments))
        }
        return .raw(trimmed)
    }

    static func parseGetlineExpression(_ expression: String) -> ExpressionNode? {
        let trimmed = MSPPOSIXAwkSyntax.strippingOuterParens(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        if let range = MSPPOSIXAwkSyntax.findTopLevelOperator("<", in: trimmed) {
            let left = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !left.isEmpty,
                  MSPPOSIXAwkSyntax.keywordAt(left.startIndex, in: left, is: "getline") else {
                return nil
            }
            let target = String(left.dropFirst("getline".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let pathExpression = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return .fileGetline(
                target: target.isEmpty ? nil : parseLValue(target),
                pathExpression: parse(pathExpression)
            )
        }
        if let range = MSPPOSIXAwkSyntax.findTopLevelOperator("|", in: trimmed) {
            let right = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !right.isEmpty,
                  MSPPOSIXAwkSyntax.keywordAt(right.startIndex, in: right, is: "getline") else {
                return nil
            }
            let commandExpression = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(right.dropFirst("getline".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .pipeGetline(
                commandExpression: parse(commandExpression),
                target: target.isEmpty ? nil : parseLValue(target)
            )
        }
        return nil
    }

    static func parseLValue(_ target: String) -> LValueNode {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "$0" {
            return .field(0)
        }
        if trimmed.hasPrefix("$"), let fieldNumber = Int(trimmed.dropFirst()) {
            return .field(fieldNumber)
        }
        if let subscriptRange = MSPPOSIXAwkSyntax.topLevelSubscript(in: trimmed) {
            let name = String(trimmed[..<subscriptRange.nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let keyExpression = String(trimmed[subscriptRange.keyRange])
            return .arrayElement(name: name, keyExpression: parse(keyExpression))
        }
        return .variable(trimmed)
    }

    static func parseArgumentList(_ arguments: String) -> [ExpressionNode] {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return MSPPOSIXAwkSyntax.splitTopLevel(trimmed, separator: ",").map(parse)
    }

    private static func parseMutation(_ expression: String) -> ExpressionNode? {
        guard !expression.hasPrefix("!") else {
            return nil
        }
        if expression.hasPrefix("++") {
            return mutationNode(target: String(expression.dropFirst(2)), operation: .preIncrement)
        }
        if expression.hasPrefix("--") {
            return mutationNode(target: String(expression.dropFirst(2)), operation: .preDecrement)
        }
        if expression.hasSuffix("++") {
            return mutationNode(target: String(expression.dropLast(2)), operation: .postIncrement)
        }
        if expression.hasSuffix("--") {
            return mutationNode(target: String(expression.dropLast(2)), operation: .postDecrement)
        }
        return nil
    }

    private static func mutationNode(
        target: String,
        operation: ExpressionNode.MutationOperator
    ) -> ExpressionNode? {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return nil }
        return .mutation(target: parseLValue(trimmedTarget), operator: operation)
    }

    private static func parseAssignment(_ expression: String) -> ExpressionNode? {
        for (operatorText, operation) in compoundAssignmentOperators {
            if let range = MSPPOSIXAwkSyntax.findTopLevelOperator(operatorText, in: expression) {
                return assignmentNode(range: range, operation: operation, expression: expression)
            }
        }
        guard let range = MSPPOSIXAwkSyntax.findTopLevelAssignment(in: expression) else {
            return nil
        }
        return assignmentNode(range: range, operation: .assign, expression: expression)
    }

    private static func assignmentNode(
        range: Range<String.Index>,
        operation: ExpressionNode.AssignmentOperator,
        expression: String
    ) -> ExpressionNode? {
        let target = String(expression[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(expression[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return .assignment(target: parseLValue(target), operator: operation, value: parse(value))
    }

    private static let compoundAssignmentOperators: [(String, ExpressionNode.AssignmentOperator)] = [
        ("+=", .addAssign),
        ("-=", .subAssign),
        ("*=", .mulAssign),
        ("/=", .divAssign),
        ("%=", .modAssign),
        ("^=", .powAssign)
    ]

    private enum ExpressionToken: Equatable {
        case primary(String)
        case lparen
        case rparen
        case pipe
        case assignment(ExpressionNode.AssignmentOperator)
        case binary(ExpressionNode.BinaryOperator)
        case increment
        case decrement
    }

    private struct TokenPrecedenceParser {
        private var tokens: [ExpressionToken]
        private var position = 0

        static func parse(_ source: String) -> ExpressionNode? {
            guard !source.isEmpty else { return nil }
            var tokenizer = ExpressionTokenizer(source: source)
            guard let tokens = tokenizer.tokenize(), !tokens.isEmpty else {
                return nil
            }
            var parser = TokenPrecedenceParser(tokens: tokens)
            guard let expression = parser.parseExpression(), parser.isAtEnd else {
                return nil
            }
            return expression
        }

        private var isAtEnd: Bool {
            position >= tokens.count
        }

        private func peek() -> ExpressionToken? {
            isAtEnd ? nil : tokens[position]
        }

        private mutating func advance() {
            if !isAtEnd {
                position += 1
            }
        }

        private mutating func parseExpression() -> ExpressionNode? {
            parsePipeGetline()
        }

        private mutating func parsePipeGetline() -> ExpressionNode? {
            guard let command = parseAssignment() else { return nil }
            guard case .some(.pipe) = peek() else { return command }
            advance()
            guard consumePrimaryKeyword("getline") else { return nil }
            let target = consumeOptionalPrimaryLValue()
            return .pipeGetline(commandExpression: command, target: target)
        }

        private mutating func parseAssignment() -> ExpressionNode? {
            guard let lhs = parseBinary(minimumPrecedence: 1) else { return nil }
            guard case .some(.assignment(let operation)) = peek() else {
                return lhs
            }
            advance()
            guard let rhs = parseAssignment() else { return nil }
            return .assignment(
                target: MSPPOSIXAwkExpressionParser.parseLValue(lhs.sourceText),
                operator: operation,
                value: rhs
            )
        }

        private mutating func parseBinary(minimumPrecedence: Int) -> ExpressionNode? {
            guard var lhs = parsePrimary() else { return nil }
            while case .some(.binary(let operation)) = peek(), operation.precedence >= minimumPrecedence {
                advance()
                let nextPrecedence = operation.isRightAssociative ? operation.precedence : operation.precedence + 1
                guard let rhs = parseBinary(minimumPrecedence: nextPrecedence) else {
                    return nil
                }
                lhs = .binary(operator: operation, left: lhs, right: rhs)
            }
            return lhs
        }

        private mutating func parsePrimary() -> ExpressionNode? {
            if case .some(.increment) = peek() {
                advance()
                guard let target = parsePrimary() else { return nil }
                return .mutation(target: MSPPOSIXAwkExpressionParser.parseLValue(target.sourceText), operator: .preIncrement)
            }
            if case .some(.decrement) = peek() {
                advance()
                guard let target = parsePrimary() else { return nil }
                return .mutation(target: MSPPOSIXAwkExpressionParser.parseLValue(target.sourceText), operator: .preDecrement)
            }
            if case .some(.lparen) = peek() {
                advance()
                guard let expression = parseExpression(), case .some(.rparen) = peek() else {
                    return nil
                }
                advance()
                return expression
            }
            guard case .some(.primary(let source)) = peek() else {
                return nil
            }
            if source == "getline", let getline = parseFileGetline() {
                return getline
            }
            advance()
            var node = primaryNode(for: source)
            if case .some(.increment) = peek() {
                advance()
                node = .mutation(target: MSPPOSIXAwkExpressionParser.parseLValue(node.sourceText), operator: .postIncrement)
            } else if case .some(.decrement) = peek() {
                advance()
                node = .mutation(target: MSPPOSIXAwkExpressionParser.parseLValue(node.sourceText), operator: .postDecrement)
            }
            return node
        }

        private mutating func parseFileGetline() -> ExpressionNode? {
            let start = position
            guard consumePrimaryKeyword("getline") else { return nil }
            var target: LValueNode?
            if case .some(.primary(let targetText)) = peek(), isLessThan(at: position + 1) {
                target = MSPPOSIXAwkExpressionParser.parseLValue(targetText)
                advance()
            }
            guard case .some(.binary(.lessThan)) = peek() else {
                position = start
                return nil
            }
            advance()
            guard let pathExpression = parseAssignment() else {
                position = start
                return nil
            }
            return .fileGetline(target: target, pathExpression: pathExpression)
        }

        private func primaryNode(for source: String) -> ExpressionNode {
            if let call = MSPPOSIXAwkSyntax.parseFunctionCall(source) {
                return .functionCall(name: call.name, arguments: MSPPOSIXAwkExpressionParser.parseArgumentList(call.arguments))
            }
            return .raw(source)
        }

        private mutating func consumePrimaryKeyword(_ keyword: String) -> Bool {
            guard case .some(.primary(let source)) = peek(), source == keyword else {
                return false
            }
            advance()
            return true
        }

        private mutating func consumeOptionalPrimaryLValue() -> LValueNode? {
            guard case .some(.primary(let source)) = peek() else {
                return nil
            }
            advance()
            return MSPPOSIXAwkExpressionParser.parseLValue(source)
        }

        private func isLessThan(at index: Int) -> Bool {
            guard index < tokens.count, case .binary(.lessThan) = tokens[index] else {
                return false
            }
            return true
        }
    }

    private struct ExpressionTokenizer {
        private let source: String
        private var index: String.Index
        private var previousNonWhitespace: Character?

        init(source: String) {
            self.source = source
            self.index = source.startIndex
        }

        mutating func tokenize() -> [ExpressionToken]? {
            var tokens: [ExpressionToken] = []
            while index < source.endIndex {
                skipWhitespace()
                guard index < source.endIndex else { break }
                if let primary = readPrimary() {
                    tokens.append(.primary(primary))
                    previousNonWhitespace = primary.last
                    continue
                }
                if let (token, marker) = readOperator() {
                    tokens.append(token)
                    previousNonWhitespace = marker
                    continue
                }
                return nil
            }
            return tokens
        }

        private mutating func skipWhitespace() {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
        }

        private mutating func readPrimary() -> String? {
            let character = source[index]
            if character == "\"" || character == "'" {
                return readQuotedString()
            }
            if character == "/", MSPPOSIXAwkSyntax.isRegexStart(previousNonWhitespace) {
                return readRegexLiteral()
            }
            if character == "$" {
                return readFieldReference()
            }
            if character.isNumber || (character == "." && peek()?.isNumber == true) {
                return readNumber()
            }
            if character == "_" || character.isLetter {
                return readIdentifierLike()
            }
            return nil
        }

        private mutating func readQuotedString() -> String {
            let start = index
            let quote = source[index]
            index = source.index(after: index)
            while index < source.endIndex {
                let character = source[index]
                index = source.index(after: index)
                if character == "\\" {
                    if index < source.endIndex {
                        index = source.index(after: index)
                    }
                    continue
                }
                if character == quote {
                    break
                }
            }
            return String(source[start..<index])
        }

        private mutating func readRegexLiteral() -> String {
            let start = index
            index = source.index(after: index)
            while index < source.endIndex {
                let character = source[index]
                index = source.index(after: index)
                if character == "\\" {
                    if index < source.endIndex {
                        index = source.index(after: index)
                    }
                    continue
                }
                if character == "/" {
                    break
                }
            }
            return String(source[start..<index])
        }

        private mutating func readFieldReference() -> String {
            let start = index
            index = source.index(after: index)
            if index < source.endIndex, source[index] == "(",
               let close = try? MSPPOSIXAwkSyntax.matchingParen(in: source, open: index) {
                index = source.index(after: close)
                return String(source[start..<index])
            }
            while index < source.endIndex, MSPPOSIXAwkSyntax.isIdentifierBody(source[index]) {
                index = source.index(after: index)
            }
            return String(source[start..<index])
        }

        private mutating func readNumber() -> String {
            let start = index
            while index < source.endIndex, source[index].isNumber {
                index = source.index(after: index)
            }
            if index < source.endIndex, source[index] == ".", peek()?.isNumber == true {
                index = source.index(after: index)
                while index < source.endIndex, source[index].isNumber {
                    index = source.index(after: index)
                }
            }
            if index < source.endIndex, source[index] == "e" || source[index] == "E" {
                let exponentStart = index
                index = source.index(after: index)
                if index < source.endIndex, source[index] == "+" || source[index] == "-" {
                    index = source.index(after: index)
                }
                let digitStart = index
                while index < source.endIndex, source[index].isNumber {
                    index = source.index(after: index)
                }
                if digitStart == index {
                    index = exponentStart
                }
            }
            return String(source[start..<index])
        }

        private mutating func readIdentifierLike() -> String {
            let start = index
            while index < source.endIndex, MSPPOSIXAwkSyntax.isIdentifierBody(source[index]) {
                index = source.index(after: index)
            }
            while index < source.endIndex, source[index] == "(" || source[index] == "[" {
                let open = index
                let closeCharacter: Character = source[index] == "(" ? ")" : "]"
                guard let close = try? MSPPOSIXAwkSyntax.matchingPair(
                    in: source,
                    open: open,
                    openCharacter: source[open],
                    closeCharacter: closeCharacter
                ) else {
                    break
                }
                index = source.index(after: close)
            }
            return String(source[start..<index])
        }

        private func peek() -> Character? {
            let next = source.index(after: index)
            return next < source.endIndex ? source[next] : nil
        }

        private mutating func readOperator() -> (ExpressionToken, Character)? {
            for (text, token, marker) in operatorTokens {
                guard source[index...].hasPrefix(text) else { continue }
                index = source.index(index, offsetBy: text.count)
                return (token, marker)
            }
            return nil
        }

        private var operatorTokens: [(String, ExpressionToken, Character)] {
            [
                ("++", .increment, "+"),
                ("--", .decrement, "-"),
                ("+=", .assignment(.addAssign), "="),
                ("-=", .assignment(.subAssign), "="),
                ("*=", .assignment(.mulAssign), "="),
                ("/=", .assignment(.divAssign), "="),
                ("%=", .assignment(.modAssign), "="),
                ("^=", .assignment(.powAssign), "="),
                ("==", .binary(.equal), "="),
                ("!=", .binary(.notEqual), "="),
                (">=", .binary(.greaterThanOrEqual), "="),
                ("<=", .binary(.lessThanOrEqual), "="),
                ("!~", .binary(.notMatch), "~"),
                ("&&", .binary(.and), "&"),
                ("||", .binary(.or), "|"),
                ("=", .assignment(.assign), "="),
                ("+", .binary(.add), "+"),
                ("-", .binary(.subtract), "-"),
                ("*", .binary(.multiply), "*"),
                ("/", .binary(.divide), "/"),
                ("%", .binary(.modulo), "%"),
                ("^", .binary(.power), "^"),
                (">", .binary(.greaterThan), ">"),
                ("<", .binary(.lessThan), "<"),
                ("~", .binary(.match), "~"),
                ("|", .pipe, "|"),
                ("(", .lparen, "("),
                (")", .rparen, ")")
            ]
        }
    }
}
