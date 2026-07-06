import Foundation
import MSPCore

public struct MSPFactorCommand: MSPCommand {
    public let name = "factor"
    public let summary: String? = "Print prime factors of unsigned integers."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspFactorUsage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "factor (GNU coreutils) 9.1\n")
        }
        let parsed = try MSPPOSIXCommandSpec(name: name)
            .parse(invocation.arguments, treatNegativeNumbersAsOperands: true)
        let tokens: [String]
        if parsed.operands.isEmpty {
            let input = try MSPPOSIXCommandSupport.standardInputData(from: context)
            tokens = String(decoding: input, as: UTF8.self)
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map(String.init)
        } else {
            tokens = parsed.operands
        }

        var stdout = ""
        var stderr = ""
        var ok = true
        for token in tokens {
            guard let value = UInt64(token) else {
                stderr += "factor: \(MSPPOSIXCommandSupport.gnuQuote(token)) is not a valid positive integer\n"
                ok = false
                continue
            }
            let factors = mspFactorPrimeFactors(value)
            stdout += "\(value):"
            if !factors.isEmpty {
                stdout += " " + factors.map(String.init).joined(separator: " ")
            }
            stdout += "\n"
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: ok ? 0 : 1)
    }
}

private let mspFactorUsage = """
Usage: factor [NUMBER]...
Print the prime factors of each specified integer NUMBER.

"""

private func mspFactorPrimeFactors(_ value: UInt64) -> [UInt64] {
    guard value > 1 else {
        return []
    }
    var remaining = value
    var factors: [UInt64] = []
    while remaining.isMultiple(of: 2) {
        factors.append(2)
        remaining /= 2
    }
    var divisor: UInt64 = 3
    while divisor <= remaining / divisor {
        while remaining.isMultiple(of: divisor) {
            factors.append(divisor)
            remaining /= divisor
        }
        divisor += 2
    }
    if remaining > 1 {
        factors.append(remaining)
    }
    return factors
}
