import Foundation
import MSPCore

public struct MSPExprCommand: MSPCommand {
    public let name = "expr"
    public let summary: String? = "Evaluate expressions."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspExprUsage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "expr (GNU coreutils) 9.1\n")
        }
        do {
            var parser = MSPExprParser(arguments: invocation.arguments)
            let value = try parser.parse()
            let stdout = value.outputText + "\n"
            return MSPCommandResult(stdout: stdout, exitCode: value.isNull ? 1 : 0)
        } catch let error as MSPExprDiagnostic {
            return MSPCommandResult(stderr: "expr: \(error.message)\n", exitCode: 2)
        }
    }
}

private let mspExprUsage = """
Usage: expr EXPRESSION
Evaluate EXPRESSION and print the result.

"""

private enum MSPExprValue: Equatable {
    case integer(Int64)
    case string(String)

    var outputText: String {
        switch self {
        case .integer(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }

    var isNull: Bool {
        switch self {
        case .integer(let value):
            return value == 0
        case .string(let value):
            guard !value.isEmpty else {
                return true
            }
            var text = value
            if text.first == "-" {
                text.removeFirst()
            }
            return !text.isEmpty && text.allSatisfy { $0 == "0" }
        }
    }

    var integerValue: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .string(let value):
            return MSPExprParser.integer(from: value)
        }
    }

    var stringValue: String {
        switch self {
        case .integer(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }
}

private struct MSPExprDiagnostic: Error {
    var message: String
}

private struct MSPExprParser {
    private let arguments: [String]
    private var index = 0
    private var previousToken: String?

    init(arguments: [String]) {
        self.arguments = arguments
    }

    mutating func parse() throws -> MSPExprValue {
        guard !arguments.isEmpty else {
            throw MSPExprDiagnostic(message: "missing operand")
        }
        let value = try parseOr()
        if let token = peek() {
            throw MSPExprDiagnostic(message: "syntax error: unexpected argument \(MSPPOSIXCommandSupport.gnuQuote(token))")
        }
        return value
    }

    private mutating func parseOr() throws -> MSPExprValue {
        var left = try parseAnd()
        while consume("|") {
            let right = try parseAnd()
            left = left.isNull ? (right.isNull ? .integer(0) : right) : left
        }
        return left
    }

    private mutating func parseAnd() throws -> MSPExprValue {
        var left = try parseComparison()
        while consume("&") {
            let right = try parseComparison()
            left = left.isNull || right.isNull ? .integer(0) : left
        }
        return left
    }

    private mutating func parseComparison() throws -> MSPExprValue {
        var left = try parseAdditive()
        while let op = consumeAny(["<", "<=", "=", "==", "!=", ">=", ">"]) {
            let right = try parseAdditive()
            let comparison: Int
            if let lhs = left.integerValue, let rhs = right.integerValue {
                comparison = lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
            } else {
                comparison = left.stringValue.compare(right.stringValue).rawValue
            }
            switch op {
            case "<":
                left = .integer(comparison < 0 ? 1 : 0)
            case "<=":
                left = .integer(comparison <= 0 ? 1 : 0)
            case "=", "==":
                left = .integer(comparison == 0 ? 1 : 0)
            case "!=":
                left = .integer(comparison != 0 ? 1 : 0)
            case ">=":
                left = .integer(comparison >= 0 ? 1 : 0)
            default:
                left = .integer(comparison > 0 ? 1 : 0)
            }
        }
        return left
    }

    private mutating func parseAdditive() throws -> MSPExprValue {
        var left = try parseMultiplicative()
        while let op = consumeAny(["+", "-"]) {
            let right = try parseMultiplicative()
            guard let lhs = left.integerValue, let rhs = right.integerValue else {
                throw MSPExprDiagnostic(message: "non-integer argument")
            }
            left = .integer(op == "+" ? lhs + rhs : lhs - rhs)
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> MSPExprValue {
        var left = try parseMatch()
        while let op = consumeAny(["*", "/", "%"]) {
            let right = try parseMatch()
            guard let lhs = left.integerValue, let rhs = right.integerValue else {
                throw MSPExprDiagnostic(message: "non-integer argument")
            }
            if (op == "/" || op == "%"), rhs == 0 {
                throw MSPExprDiagnostic(message: "division by zero")
            }
            switch op {
            case "*":
                left = .integer(lhs * rhs)
            case "/":
                left = .integer(lhs / rhs)
            default:
                left = .integer(lhs % rhs)
            }
        }
        return left
    }

    private mutating func parseMatch() throws -> MSPExprValue {
        var left = try parsePrefix()
        while consume(":") {
            let pattern = try parsePrefix()
            left = MSPExprParser.match(left.stringValue, pattern: pattern.stringValue)
        }
        return left
    }

    private mutating func parsePrefix() throws -> MSPExprValue {
        if consume("+") {
            return .string(try requireToken())
        }
        if consume("length") {
            let value = try parsePrefix().stringValue
            return .integer(Int64(value.unicodeScalars.count))
        }
        if consume("match") {
            let string = try parsePrefix().stringValue
            let pattern = try parsePrefix().stringValue
            return MSPExprParser.match(string, pattern: pattern)
        }
        if consume("index") {
            let string = try parsePrefix().stringValue
            let needles = Set(try parsePrefix().stringValue.unicodeScalars)
            let scalars = Array(string.unicodeScalars)
            for offset in scalars.indices where needles.contains(scalars[offset]) {
                return .integer(Int64(offset + 1))
            }
            return .integer(0)
        }
        if consume("substr") {
            let string = try parsePrefix().stringValue
            let start = try parsePrefix().integerValue
            let length = try parsePrefix().integerValue
            guard let start, let length, start > 0, length > 0 else {
                return .string("")
            }
            let scalars = Array(string.unicodeScalars)
            let lower = min(Int(start - 1), scalars.count)
            let upper = min(lower + Int(length), scalars.count)
            return .string(String(String.UnicodeScalarView(scalars[lower..<upper])))
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> MSPExprValue {
        if consume("(") {
            let value = try parseOr()
            guard consume(")") else {
                let token = peek() ?? previousToken ?? "("
                throw MSPExprDiagnostic(message: "syntax error: expecting ')' after \(MSPPOSIXCommandSupport.gnuQuote(token))")
            }
            return value
        }
        if consume(")") {
            throw MSPExprDiagnostic(message: "syntax error: unexpected ')'")
        }
        let token = try requireToken()
        if let integer = MSPExprParser.integer(from: token) {
            return .integer(integer)
        }
        return .string(token)
    }

    private func peek() -> String? {
        index < arguments.count ? arguments[index] : nil
    }

    private mutating func consume(_ token: String) -> Bool {
        guard peek() == token else {
            return false
        }
        previousToken = token
        index += 1
        return true
    }

    private mutating func consumeAny(_ tokens: [String]) -> String? {
        guard let token = peek(), tokens.contains(token) else {
            return nil
        }
        previousToken = token
        index += 1
        return token
    }

    private mutating func requireToken() throws -> String {
        guard let token = peek() else {
            throw MSPExprDiagnostic(
                message: "syntax error: missing argument after \(MSPPOSIXCommandSupport.gnuQuote(previousToken ?? ""))"
            )
        }
        previousToken = token
        index += 1
        return token
    }

    static func integer(from text: String) -> Int64? {
        guard !text.isEmpty else {
            return nil
        }
        var body = text
        if body.first == "-" {
            body.removeFirst()
            guard !body.isEmpty else {
                return nil
            }
        }
        guard body.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int64(text)
    }

    static func match(_ string: String, pattern: String) -> MSPExprValue {
        let nsPattern = "^(?:" + posixBasicPatternForFoundation(pattern) + ")"
        guard let regex = try? NSRegularExpression(pattern: nsPattern) else {
            return .integer(0)
        }
        let nsString = string as NSString
        let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: nsString.length))
        guard let match else {
            return regex.numberOfCaptureGroups > 0 ? .string("") : .integer(0)
        }
        if regex.numberOfCaptureGroups > 0 {
            let range = match.range(at: 1)
            return range.location == NSNotFound ? .string("") : .string(nsString.substring(with: range))
        }
        let matched = nsString.substring(with: match.range)
        return .integer(Int64(matched.unicodeScalars.count))
    }

    private static func posixBasicPatternForFoundation(_ pattern: String) -> String {
        var output = ""
        var iterator = pattern.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                if next == "(" || next == ")" {
                    output.append(next)
                } else {
                    output.append("\\")
                    output.append(next)
                }
            } else {
                output.append(character)
            }
        }
        return output
    }
}
