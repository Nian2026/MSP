import Foundation
import MSPCore

public struct MSPNprocCommand: MSPCommand {
    public let name = "nproc"
    public let summary: String? = "Print the virtual Linux processor count."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspNprocUsage())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "nproc (GNU coreutils) 9.1\n")
        }
        let parsed = mspNprocParse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard parsed.operands.isEmpty else {
            return .failure(
                stderr: "nproc: extra operand \(MSPPOSIXCommandSupport.gnuQuote(parsed.operands[0]))\nTry 'nproc --help' for more information.\n"
            )
        }
        let base = MSPPOSIXVirtualIdentity.processorCount
        let count = parsed.ignore < base ? base - parsed.ignore : 1
        return .success(stdout: "\(count)\n")
    }
}

private struct MSPNprocOptions {
    var ignore: UInt = 0
    var operands: [String] = []
    var result: MSPCommandResult?
}

private func mspNprocParse(_ arguments: [String]) -> MSPNprocOptions {
    var parsed = MSPNprocOptions()
    var index = 0
    var parsingOptions = true
    while index < arguments.count {
        let argument = arguments[index]
        if parsingOptions, argument == "--" {
            parsingOptions = false
            index += 1
            continue
        }
        if parsingOptions, argument == "--all" {
            index += 1
            continue
        }
        if parsingOptions, argument == "--ignore" {
            guard index + 1 < arguments.count, let value = UInt(arguments[index + 1]) else {
                parsed.result = .failure(stderr: "nproc: invalid number: \(MSPPOSIXCommandSupport.gnuQuote(index + 1 < arguments.count ? arguments[index + 1] : ""))\n")
                return parsed
            }
            parsed.ignore = value
            index += 2
            continue
        }
        if parsingOptions, argument.hasPrefix("--ignore=") {
            let raw = String(argument.dropFirst("--ignore=".count))
            guard let value = UInt(raw) else {
                parsed.result = .failure(stderr: "nproc: invalid number: \(MSPPOSIXCommandSupport.gnuQuote(raw))\n")
                return parsed
            }
            parsed.ignore = value
            index += 1
            continue
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            let message = argument.hasPrefix("--")
                ? "nproc: unrecognized option '\(argument)'"
                : "nproc: invalid option -- '\(argument.dropFirst().first ?? "?")'"
            parsed.result = .failure(stderr: "\(message)\nTry 'nproc --help' for more information.\n")
            return parsed
        }
        parsed.operands.append(argument)
        index += 1
    }
    return parsed
}

private func mspNprocUsage() -> String {
    """
    Usage: nproc [OPTION]...
    Print the number of processing units available to the current virtual process.

    """
}
