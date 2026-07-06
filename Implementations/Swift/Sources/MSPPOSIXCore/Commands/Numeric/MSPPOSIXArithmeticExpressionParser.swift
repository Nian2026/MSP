import Foundation

struct MSPPOSIXArithmeticExpressionParser {
    var characters: [Character]
    var index = 0
    var variables: [String: String]
    var arrayVariables: [String: [String]]
    var associativeArrayVariables: [String: [String: String]]

    init(
        expression: String,
        variables: [String: String],
        arrayVariables: [String: [String]] = [:],
        associativeArrayVariables: [String: [String: String]] = [:]
    ) {
        characters = Array(expression)
        self.variables = variables
        self.arrayVariables = arrayVariables
        self.associativeArrayVariables = associativeArrayVariables
    }

    mutating func parse() throws -> Int {
        let value = try parseLogicalOr()
        skipWhitespace()
        guard index == characters.count else {
            throw MSPPOSIXArithmeticError.usage("arithmetic expansion: unexpected token \(characters[index])")
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
                    throw MSPPOSIXArithmeticError.usage("arithmetic expansion: division by zero")
                }
                value /= divisor
            } else if consume("%") {
                let divisor = try parseUnary()
                guard divisor != 0 else {
                    throw MSPPOSIXArithmeticError.usage("arithmetic expansion: division by zero")
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
                throw MSPPOSIXArithmeticError.usage("arithmetic expansion: missing )")
            }
            return value
        }
        if peek == "$" {
            index += 1
        }
        if let character = peek, character.isNumber {
            return parseInteger()
        }
        if let character = peek, character == "_" || character.isLetter {
            let name = parseVariableName()
            if consume("[") {
                let key = try parseSubscriptKey(for: name)
                return arithmeticInteger(arrayOrAssociativeValue(name: name, key: key))
            }
            return arithmeticInteger(variables[name])
        }
        throw MSPPOSIXArithmeticError.usage("arithmetic expansion: expected expression")
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
                throw MSPPOSIXArithmeticError.usage("arithmetic expansion: missing subscript quote")
            }
            skipWhitespace()
            guard consume("]") else {
                throw MSPPOSIXArithmeticError.usage("arithmetic expansion: missing ]")
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
                    if associativeArrayVariables[name] != nil {
                        return variables[trimmed] ?? trimmed
                    }
                    if let numericKey = Int(trimmed) {
                        return String(numericKey)
                    }
                    var parser = MSPPOSIXArithmeticExpressionParser(
                        expression: trimmed,
                        variables: variables,
                        arrayVariables: arrayVariables,
                        associativeArrayVariables: associativeArrayVariables
                    )
                    return String(try parser.parse())
                }
                nestedDepth -= 1
            }
            index += 1
        }
        throw MSPPOSIXArithmeticError.usage("arithmetic expansion: missing ]")
    }

    private func arrayOrAssociativeValue(name: String, key: String) -> String? {
        if let associativeValues = associativeArrayVariables[name] {
            return associativeValues[key]
        }
        if let index = Int(key),
           let values = arrayVariables[name],
           index >= 0,
           index < values.count {
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
        while let character = peek, character == "_" || character.isLetter || character.isNumber {
            index += 1
        }
        return String(characters[start..<index])
    }

    private func arithmeticInteger(_ value: String?) -> Int {
        Int((value ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
            guard characters[index + offset] == expectedCharacters[offset] else { return false }
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
