import Foundation
import MSPCore

public struct MSPBcCommand: MSPStreamingCommand {
    public let name = "bc"
    public let summary: String? = "Evaluate integer arithmetic expressions."

    private let spec = MSPPOSIXCommandSpec(
        name: "bc",
        allowedShortOptions: ["l"],
        allowedLongOptions: ["mathlib"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") || invocation.arguments.contains("-h") {
            return .success(stdout: mspBcHelp())
        }
        if invocation.arguments.contains("--version") || invocation.arguments.contains("-v") {
            return .success(stdout: "bc 1.07.1\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: parsed.operands,
            context: context,
            command: name
        )
        guard input.diagnostics.isEmpty else {
            return .failure(stderr: input.diagnostics.joined(separator: "\n") + "\n")
        }

        let text = String(decoding: input.inputs.reduce(into: Data()) { data, input in
            data.append(input.data)
        }, as: UTF8.self)
        var results: [String] = []
        var state = MSPBcState()
        for (lineOffset, line) in mspPOSIXLines(text).enumerated() {
            let lineNumber = lineOffset + 1
            let lineResult = try mspBcProcessLine(line, lineNumber: lineNumber, state: &state)
            results.append(contentsOf: lineResult.outputs)
            if let error = lineResult.error {
                return MSPCommandResult(stdout: mspPOSIXJoinedLines(results), stderr: error)
            }
        }
        return .success(stdout: mspPOSIXJoinedLines(results))
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") || invocation.arguments.contains("-h") {
            return .success(stdout: mspBcHelp())
        }
        if invocation.arguments.contains("--version") || invocation.arguments.contains("-v") {
            return .success(stdout: "bc 1.07.1\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        guard parsed.operands.isEmpty,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        var state = MSPBcState()
        var buffer = Data()
        var lineNumber = 0
        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<(newlineIndex + 1))
                    lineNumber += 1
                    if let failure = try await streamBcLine(
                        lineData,
                        lineNumber: lineNumber,
                        state: &state,
                        standardOutput: standardOutput
                    ) {
                        return failure
                    }
                }
            }
            if !buffer.isEmpty {
                lineNumber += 1
                if let failure = try await streamBcLine(
                    buffer,
                    lineNumber: lineNumber,
                    state: &state,
                    standardOutput: standardOutput
                ) {
                    return failure
                }
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func streamBcLine(
        _ lineData: Data,
        lineNumber: Int,
        state: inout MSPBcState,
        standardOutput: any MSPCommandOutputStream
    ) async throws -> MSPCommandResult? {
        let line = String(decoding: lineData, as: UTF8.self)
        let result = try mspBcProcessLine(line, lineNumber: lineNumber, state: &state)
        for output in result.outputs {
            try await standardOutput.write(Data((output + "\n").utf8))
        }
        if let error = result.error {
            return MSPCommandResult(stderr: error)
        }
        return nil
    }
}

private func mspBcHelp() -> String {
    """
    usage: bc [options] [file ...]
      -h  --help         print this usage and exit
      -l  --mathlib      use the predefined math routines
      -v  --version      print version information and exit

    """
}

private struct MSPBcState {
    var scale: Int?
    var inputBase = 10
    var outputBase = 10
}

private struct MSPBcLineResult {
    var outputs: [String] = []
    var error: String?
}

private func mspBcProcessLine(
    _ line: String,
    lineNumber: Int,
    state: inout MSPBcState
) throws -> MSPBcLineResult {
    var result = MSPBcLineResult()
    let statements = line.split(separator: ";", omittingEmptySubsequences: false)
    for statement in statements {
        let expression = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            continue
        }
        if mspBcApplyScaleAssignment(expression, state: &state) {
            continue
        }
        if mspBcApplyBaseAssignment(expression, state: &state) {
            continue
        }
        let normalizedExpression = mspBcNormalizeNumericTokens(expression, inputBase: state.inputBase)
        if let scaled = mspBcEvaluateScaledExpression(normalizedExpression, scale: state.scale) {
            result.outputs.append(scaled)
            continue
        }
        do {
            var parser = MSPPOSIXArithmeticExpressionParser(
                expression: normalizedExpression,
                variables: [:],
                arrayVariables: [:],
                associativeArrayVariables: [:]
            )
            let value = try parser.parse()
            result.outputs.append(mspBcFormatInteger(value, outputBase: state.outputBase))
        } catch let failure as MSPCommandFailure {
            guard mspBcShouldReportSyntaxError(failure) else {
                throw failure
            }
            result.error = "(standard_in) \(mspBcSyntaxLineNumber(for: expression, lineNumber: lineNumber)): syntax error\n"
            return result
        }
    }
    return result
}

private func mspBcApplyScaleAssignment(_ expression: String, state: inout MSPBcState) -> Bool {
    let parts = expression.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "scale",
          let scale = mspBcParseInteger(parts[1].trimmingCharacters(in: .whitespacesAndNewlines), inputBase: state.inputBase),
          scale >= 0 else {
        return false
    }
    state.scale = scale
    return true
}

private func mspBcApplyBaseAssignment(_ expression: String, state: inout MSPBcState) -> Bool {
    let parts = expression.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        return false
    }

    let variable = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard variable == "ibase" || variable == "obase",
          let value = mspBcParseInteger(parts[1].trimmingCharacters(in: .whitespacesAndNewlines), inputBase: state.inputBase) else {
        return false
    }

    if variable == "ibase" {
        state.inputBase = min(max(value, 2), 16)
    } else {
        state.outputBase = min(max(value, 2), 36)
    }
    return true
}

private func mspBcEvaluateScaledExpression(_ expression: String, scale: Int?) -> String? {
    guard let scale else {
        return nil
    }
    let compact = expression.filter { !$0.isWhitespace }
    guard let match = compact.range(
        of: #"^-?[0-9]+[+\-*/]-?[0-9]+$"#,
        options: .regularExpression
    ), match == compact.startIndex..<compact.endIndex else {
        return nil
    }

    let operatorIndex = compact.dropFirst().firstIndex { character in
        character == "+" || character == "-" || character == "*" || character == "/"
    } ?? compact.startIndex
    let lhsText = String(compact[..<operatorIndex])
    let rhsText = String(compact[compact.index(after: operatorIndex)...])
    guard let lhs = Int(lhsText), let rhs = Int(rhsText), rhs != 0 else {
        return nil
    }

    switch compact[operatorIndex] {
    case "+":
        return String(lhs + rhs)
    case "-":
        return String(lhs - rhs)
    case "*":
        return String(lhs * rhs)
    case "/":
        return mspBcScaledIntegerDivision(lhs, rhs, scale: scale)
    default:
        return nil
    }
}

private func mspBcScaledIntegerDivision(_ lhs: Int, _ rhs: Int, scale: Int) -> String {
    let negative = (lhs < 0) != (rhs < 0)
    let numerator = abs(lhs)
    let denominator = abs(rhs)
    let integerPart = numerator / denominator
    var remainder = numerator % denominator
    guard scale > 0 else {
        return "\(negative && integerPart != 0 ? "-" : "")\(integerPart)"
    }

    var fractional = ""
    for _ in 0..<scale {
        remainder *= 10
        fractional.append(String(remainder / denominator))
        remainder %= denominator
    }

    let sign = negative ? "-" : ""
    if integerPart == 0 {
        return "\(sign).\(fractional)"
    }
    return "\(sign)\(integerPart).\(fractional)"
}

private func mspBcNormalizeNumericTokens(_ expression: String, inputBase: Int) -> String {
    var output = ""
    var token = ""

    func flushToken() {
        guard !token.isEmpty else {
            return
        }
        if let value = mspBcParseInteger(token, inputBase: inputBase) {
            output += String(value)
        } else {
            output += token
        }
        token.removeAll()
    }

    for character in expression {
        if mspBcDigitValue(character) != nil {
            token.append(character)
        } else {
            flushToken()
            output.append(character)
        }
    }
    flushToken()
    return output
}

private func mspBcParseInteger<S: StringProtocol>(_ text: S, inputBase: Int) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    var sign = 1
    var index = trimmed.startIndex
    if trimmed[index] == "-" {
        sign = -1
        index = trimmed.index(after: index)
    } else if trimmed[index] == "+" {
        index = trimmed.index(after: index)
    }
    guard index < trimmed.endIndex else {
        return nil
    }

    var value = 0
    while index < trimmed.endIndex {
        guard let digit = mspBcDigitValue(trimmed[index]) else {
            return nil
        }
        value = value * inputBase + digit
        index = trimmed.index(after: index)
    }
    return sign * value
}

private func mspBcDigitValue(_ character: Character) -> Int? {
    guard let scalar = character.unicodeScalars.first,
          character.unicodeScalars.count == 1 else {
        return nil
    }
    if scalar.value >= 48, scalar.value <= 57 {
        return Int(scalar.value - 48)
    }
    if scalar.value >= 65, scalar.value <= 70 {
        return Int(scalar.value - 65 + 10)
    }
    return nil
}

private func mspBcFormatInteger(_ value: Int, outputBase: Int) -> String {
    guard outputBase != 10 else {
        return String(value)
    }
    let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let negative = value < 0
    var remaining = abs(value)
    var output: [Character] = []
    repeat {
        output.append(digits[remaining % outputBase])
        remaining /= outputBase
    } while remaining > 0
    return (negative ? "-" : "") + String(output.reversed())
}

private func mspBcShouldReportSyntaxError(_ failure: MSPCommandFailure) -> Bool {
    let stderr = failure.result.stderr
    return stderr.contains("expected expression")
        || stderr.contains("unexpected token")
        || stderr.contains("missing )")
}

private func mspBcSyntaxLineNumber(for expression: String, lineNumber: Int) -> Int {
    guard let last = expression.last,
          "+-*/%(".contains(last) else {
        return lineNumber
    }
    return lineNumber + 1
}
