import Foundation
import MSPShellLanguage

struct MSPShellArithmeticExpressionParser {
    var characters: [Character]
    var index = 0
    var variables: [String: String]
    var arrays: [String: MSPShellIndexedArray]
    var associativeArrays: [String: [String: String]]
    var namerefVariables: [String: String]

    init(
        expression: String,
        variables: [String: String],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:],
        namerefVariables: [String: String] = [:]
    ) {
        self.characters = Array(expression)
        self.variables = variables
        self.arrays = arrays
        self.associativeArrays = associativeArrays
        self.namerefVariables = namerefVariables
    }

    mutating func parse() throws -> Int {
        let value = try parseLogicalOr()
        skipWhitespace()
        guard index == characters.count else {
            throw MSPShellExpansionError.arithmetic("unexpected token \(characters[index])")
        }
        return value
    }

    private mutating func parseLogicalOr() throws -> Int {
        var value = try parseLogicalAnd()
        while true {
            skipWhitespace()
            guard consumeOperator("||") else { return value }
            let rhs = try parseLogicalAnd()
            value = (value != 0 || rhs != 0) ? 1 : 0
        }
    }

    private mutating func parseLogicalAnd() throws -> Int {
        var value = try parseEquality()
        while true {
            skipWhitespace()
            guard consumeOperator("&&") else { return value }
            let rhs = try parseEquality()
            value = (value != 0 && rhs != 0) ? 1 : 0
        }
    }

    private mutating func parseEquality() throws -> Int {
        var value = try parseRelational()
        while true {
            skipWhitespace()
            if consumeOperator("==") {
                value = value == (try parseRelational()) ? 1 : 0
            } else if consumeOperator("!=") {
                value = value != (try parseRelational()) ? 1 : 0
            } else {
                return value
            }
        }
    }

    private mutating func parseRelational() throws -> Int {
        var value = try parseAddition()
        while true {
            skipWhitespace()
            if consumeOperator("<=") {
                value = value <= (try parseAddition()) ? 1 : 0
            } else if consumeOperator(">=") {
                value = value >= (try parseAddition()) ? 1 : 0
            } else if consume("<") {
                value = value < (try parseAddition()) ? 1 : 0
            } else if consume(">") {
                value = value > (try parseAddition()) ? 1 : 0
            } else {
                return value
            }
        }
    }

    private mutating func parseAddition() throws -> Int {
        var value = try parseMultiplication()
        while true {
            skipWhitespace()
            if consume("+") {
                value += try parseMultiplication()
            } else if consume("-") {
                value -= try parseMultiplication()
            } else {
                return value
            }
        }
    }

    private mutating func parseMultiplication() throws -> Int {
        var value = try parseUnary()
        while true {
            skipWhitespace()
            if consume("*") {
                value *= try parseUnary()
            } else if consume("/") {
                let divisor = try parseUnary()
                guard divisor != 0 else {
                    throw MSPShellExpansionError.arithmetic("division by zero")
                }
                value /= divisor
            } else if consume("%") {
                let divisor = try parseUnary()
                guard divisor != 0 else {
                    throw MSPShellExpansionError.arithmetic("division by zero")
                }
                value %= divisor
            } else {
                return value
            }
        }
    }

    private mutating func parseUnary() throws -> Int {
        skipWhitespace()
        if consume("+") {
            return try parseUnary()
        }
        if consume("-") {
            return -(try parseUnary())
        }
        if consume("!") {
            return try parseUnary() == 0 ? 1 : 0
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Int {
        skipWhitespace()
        if consume("(") {
            let value = try parseLogicalOr()
            skipWhitespace()
            guard consume(")") else {
                throw MSPShellExpansionError.arithmetic("missing )")
            }
            return value
        }
        if peek == "$" {
            index += 1
        }
        if let character = peek, character.isNumber {
            return parseInteger()
        }
        if let character = peek,
           MSPShellExpansionScanner.isShellVariableStart(character) {
            let name = parseVariableName()
            if consume("[") {
                let key = try parseSubscriptKey(for: name)
                return arithmeticInteger(arrayOrAssociativeValue(name: name, key: key))
            }
            return arithmeticInteger(variableValue(name))
        }
        throw MSPShellExpansionError.arithmetic("expected expression")
    }

    private mutating func parseSubscriptKey(for name: String) throws -> String {
        skipWhitespace()
        let rawKey: String
        if let quote = peek, quote == "\"" || quote == "'" {
            index += 1
            let start = index
            while let character = peek, character != quote {
                index += 1
            }
            rawKey = String(characters[start..<index])
            guard consume(quote) else {
                throw MSPShellExpansionError.arithmetic("missing subscript quote")
            }
            skipWhitespace()
            guard consume("]") else {
                throw MSPShellExpansionError.arithmetic("missing ]")
            }
            return rawKey
        }

        let start = index
        var nestedDepth = 0
        while let character = peek {
            if character == "[", nestedDepth == 0 {
                nestedDepth += 1
                index += 1
                continue
            }
            if character == "]" {
                if nestedDepth == 0 {
                    rawKey = String(characters[start..<index])
                    index += 1
                    let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if associativeArrays[resolvedName(name)] != nil {
                        return variableValue(trimmed) ?? trimmed
                    }
                    if let numericKey = Int(trimmed) {
                        return String(numericKey)
                    }
                    var parser = MSPShellArithmeticExpressionParser(
                        expression: trimmed,
                        variables: variables,
                        arrays: arrays,
                        associativeArrays: associativeArrays,
                        namerefVariables: namerefVariables
                    )
                    return String(try parser.parse())
                }
                nestedDepth -= 1
            }
            index += 1
        }
        throw MSPShellExpansionError.arithmetic("missing ]")
    }

    private func arrayOrAssociativeValue(name: String, key: String) -> String? {
        let name = resolvedName(name)
        if let associativeValues = associativeArrays[name] {
            return associativeValues[key]
        }
        if let index = Int(key),
           let values = arrays[name],
           index >= 0 {
            return values[index]
        }
        return nil
    }

    private mutating func parseInteger() -> Int {
        let start = index
        while let character = peek, character.isNumber {
            index += 1
        }
        return Int(String(characters[start..<index])) ?? 0
    }

    private mutating func parseVariableName() -> String {
        let start = index
        while let character = peek,
              MSPShellExpansionScanner.isShellVariableBody(character) {
            index += 1
        }
        return String(characters[start..<index])
    }

    private func arithmeticInteger(_ value: String?) -> Int {
        Int((value ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func variableValue(_ name: String) -> String? {
        variables[resolvedName(name)]
    }

    private func resolvedName(_ name: String) -> String {
        var current = name
        var seen: Set<String> = []
        while let next = namerefVariables[current],
              MSPShellExpansionScanner.isShellVariableName(next),
              !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }

    private var peek: Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func consume(_ expected: Character) -> Bool {
        guard peek == expected else { return false }
        index += 1
        return true
    }

    private mutating func consumeOperator(_ expected: String) -> Bool {
        let expectedCharacters = Array(expected)
        guard index + expectedCharacters.count <= characters.count else { return false }
        for offset in expectedCharacters.indices {
            guard characters[index + offset] == expectedCharacters[offset] else {
                return false
            }
        }
        index += expectedCharacters.count
        return true
    }

    private mutating func skipWhitespace() {
        while let character = peek, character.isWhitespace {
            index += 1
        }
    }
}

public struct MSPShellArithmeticCommandEvaluation: Sendable, Equatable {
    public var value: Int
    public var exitCode: Int32
    public var environment: [String: String]
    public var arrays: [String: MSPShellIndexedArray]
    public var associativeArrays: [String: [String: String]]

    public init(
        value: Int,
        exitCode: Int32,
        environment: [String: String],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:]
    ) {
        self.value = value
        self.exitCode = exitCode
        self.environment = environment
        self.arrays = arrays
        self.associativeArrays = associativeArrays
    }
}

public struct MSPShellArithmeticCommandEvaluator {
    public var expression: String
    public var environment: [String: String]
    public var arrays: [String: MSPShellIndexedArray]
    public var associativeArrays: [String: [String: String]]
    public var namerefVariables: [String: String]

    public init(
        expression: String,
        environment: [String: String] = [:],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:],
        namerefVariables: [String: String] = [:]
    ) {
        self.expression = expression
        self.environment = environment
        self.arrays = arrays
        self.associativeArrays = associativeArrays
        self.namerefVariables = namerefVariables
    }

    public mutating func evaluate() throws -> MSPShellArithmeticCommandEvaluation {
        var lastValue = 0
        for rawPart in arithmeticCommandParts(expression) {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else {
                continue
            }
            lastValue = try evaluatePart(part)
        }
        return MSPShellArithmeticCommandEvaluation(
            value: lastValue,
            exitCode: lastValue == 0 ? 1 : 0,
            environment: environment,
            arrays: arrays,
            associativeArrays: associativeArrays
        )
    }

    private func arithmeticCommandParts(_ expression: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in expression {
            if character == "(" || character == "[" {
                depth += 1
                current.append(character)
            } else if character == ")" || character == "]" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private mutating func evaluatePart(_ expression: String) throws -> Int {
        if let update = try postfixArithmeticUpdate(expression, suffix: "++", delta: 1) {
            return applyPostfixArithmeticUpdate(update)
        }
        if let update = try postfixArithmeticUpdate(expression, suffix: "--", delta: -1) {
            return applyPostfixArithmeticUpdate(update)
        }
        if let update = try prefixArithmeticUpdate(expression, prefix: "++", delta: 1) {
            return applyPrefixArithmeticUpdate(update)
        }
        if let update = try prefixArithmeticUpdate(expression, prefix: "--", delta: -1) {
            return applyPrefixArithmeticUpdate(update)
        }
        if let assignment = try arithmeticAssignment(expression) {
            let rhs = try arithmeticValue(assignment.rhs)
            let current = arithmeticValue(of: assignment.lvalue)
            let next: Int
            switch assignment.operatorText {
            case "=":
                next = rhs
            case "+=":
                next = current + rhs
            case "-=":
                next = current - rhs
            case "*=":
                next = current * rhs
            case "/=":
                guard rhs != 0 else {
                    throw MSPShellExpansionError.arithmetic("division by zero")
                }
                next = current / rhs
            case "%=":
                guard rhs != 0 else {
                    throw MSPShellExpansionError.arithmetic("division by zero")
                }
                next = current % rhs
            default:
                next = rhs
            }
            setArithmeticValue(next, for: assignment.lvalue)
            return next
        }
        return try arithmeticValue(expression)
    }

    private func postfixArithmeticUpdate(
        _ expression: String,
        suffix: String,
        delta: Int
    ) throws -> (lvalue: ArithmeticLValue, delta: Int)? {
        guard expression.hasSuffix(suffix) else {
            return nil
        }
        let lvalueText = String(expression.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lvalue = try arithmeticLValue(lvalueText) else { return nil }
        return (lvalue, delta)
    }

    private func prefixArithmeticUpdate(
        _ expression: String,
        prefix: String,
        delta: Int
    ) throws -> (lvalue: ArithmeticLValue, delta: Int)? {
        guard expression.hasPrefix(prefix) else {
            return nil
        }
        let lvalueText = String(expression.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lvalue = try arithmeticLValue(lvalueText) else { return nil }
        return (lvalue, delta)
    }

    private mutating func applyPostfixArithmeticUpdate(_ update: (lvalue: ArithmeticLValue, delta: Int)) -> Int {
        let oldValue = arithmeticValue(of: update.lvalue)
        setArithmeticValue(oldValue + update.delta, for: update.lvalue)
        return oldValue
    }

    private mutating func applyPrefixArithmeticUpdate(_ update: (lvalue: ArithmeticLValue, delta: Int)) -> Int {
        let nextValue = arithmeticValue(of: update.lvalue) + update.delta
        setArithmeticValue(nextValue, for: update.lvalue)
        return nextValue
    }

    private func arithmeticAssignment(
        _ expression: String
    ) throws -> (lvalue: ArithmeticLValue, operatorText: String, rhs: String)? {
        guard let assignment = topLevelAssignmentOperator(in: expression) else {
            return nil
        }
        let lvalueText = String(expression[..<assignment.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lvalue = try arithmeticLValue(lvalueText) else { return nil }
        return (
            lvalue,
            assignment.operatorText,
            String(expression[assignment.range.upperBound...])
        )
    }

    private func topLevelAssignmentOperator(
        in expression: String
    ) -> (operatorText: String, range: Range<String.Index>)? {
        let operators = ["+=", "-=", "*=", "/=", "%=", "="]
        var index = expression.startIndex
        var depth = 0
        while index < expression.endIndex {
            let character = expression[index]
            if character == "(" || character == "[" {
                depth += 1
                index = expression.index(after: index)
                continue
            }
            if character == ")" || character == "]" {
                depth = max(0, depth - 1)
                index = expression.index(after: index)
                continue
            }
            if depth == 0 {
                for operatorText in operators where expression[index...].hasPrefix(operatorText) {
                    let end = expression.index(index, offsetBy: operatorText.count)
                    let range = index..<end
                    if operatorText == "=", isArithmeticComparisonEqual(in: expression, at: range) {
                        continue
                    }
                    return (operatorText, range)
                }
            }
            index = expression.index(after: index)
        }
        return nil
    }

    private func isArithmeticComparisonEqual(in expression: String, at range: Range<String.Index>) -> Bool {
        let previous = range.lowerBound > expression.startIndex
            ? expression[expression.index(before: range.lowerBound)]
            : nil
        let next = range.upperBound < expression.endIndex
            ? expression[range.upperBound]
            : nil
        return previous == "<" || previous == ">" || previous == "!" || previous == "=" || next == "="
    }

    private func arithmeticValue(_ expression: String) throws -> Int {
        var parser = MSPShellArithmeticExpressionParser(
            expression: expression,
            variables: environment,
            arrays: arrays,
            associativeArrays: associativeArrays,
            namerefVariables: namerefVariables
        )
        return try parser.parse()
    }

    private struct ArithmeticLValue {
        var name: String
        var key: String?
    }

    private func arithmeticLValue(_ expression: String) throws -> ArithmeticLValue? {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if MSPShellExpansionScanner.isShellVariableName(text) {
            return ArithmeticLValue(name: resolvedName(text), key: nil)
        }
        guard let openIndex = text.firstIndex(of: "["),
              text.hasSuffix("]") else {
            return nil
        }
        let name = String(text[..<openIndex])
        guard MSPShellExpansionScanner.isShellVariableName(name) else { return nil }
        let resolvedName = resolvedName(name)
        let closeIndex = text.index(before: text.endIndex)
        let rawKey = String(text[text.index(after: openIndex)..<closeIndex])
        let key = try arithmeticSubscriptKey(rawKey, for: resolvedName)
        return ArithmeticLValue(name: resolvedName, key: key)
    }

    private func arithmeticSubscriptKey(_ rawKey: String, for name: String) throws -> String {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 2,
           let first = key.first,
           let last = key.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(key.dropFirst().dropLast())
        }
        if associativeArrays[name] != nil {
            return variableValue(key) ?? key
        }
        if let numericKey = Int(key) {
            return String(numericKey)
        }
        return String(try arithmeticValue(key))
    }

    private func arithmeticValue(of lvalue: ArithmeticLValue) -> Int {
        guard let key = lvalue.key else {
            return arithmeticInteger(environment[lvalue.name])
        }
        if let associativeValues = associativeArrays[lvalue.name] {
            return arithmeticInteger(associativeValues[key])
        }
        if let index = Int(key),
           let values = arrays[lvalue.name],
           index >= 0 {
            return arithmeticInteger(values[index])
        }
        return 0
    }

    private mutating func setArithmeticValue(_ value: Int, for lvalue: ArithmeticLValue) {
        let text = String(value)
        guard let key = lvalue.key else {
            environment[lvalue.name] = text
            return
        }
        if associativeArrays[lvalue.name] != nil || Int(key) == nil {
            associativeArrays[lvalue.name, default: [:]][key] = text
            arrays.removeValue(forKey: lvalue.name)
            environment.removeValue(forKey: lvalue.name)
            return
        }
        guard let index = Int(key), index >= 0 else {
            associativeArrays[lvalue.name, default: [:]][key] = text
            arrays.removeValue(forKey: lvalue.name)
            environment.removeValue(forKey: lvalue.name)
            return
        }
        var values = arrays[lvalue.name] ?? MSPShellIndexedArray()
        values[index] = text
        arrays[lvalue.name] = values
        associativeArrays.removeValue(forKey: lvalue.name)
        environment[lvalue.name] = values.first ?? ""
    }

    private func arithmeticInteger(_ value: String?) -> Int {
        Int((value ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func variableValue(_ name: String) -> String? {
        environment[resolvedName(name)]
    }

    private func resolvedName(_ name: String) -> String {
        var current = name
        var seen: Set<String> = []
        while let next = namerefVariables[current],
              MSPShellExpansionScanner.isShellVariableName(next),
              !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }
}
