import Foundation
import MSPCore

public struct MSPSleepCommand: MSPCommand {
    public let name = "sleep"
    public let summary: String? = "Delay for a specified amount of time."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspSleepUsage())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "sleep (GNU coreutils) 9.1\n")
        }
        guard !invocation.arguments.isEmpty else {
            return .failure(exitCode: 1, stderr: "sleep: missing operand\n" + mspSleepHelpDiagnostic())
        }
        let scannedArguments = mspSleepScanArguments(invocation.arguments)
        if let result = scannedArguments.result {
            return result
        }
        let operands = scannedArguments.operands

        var seconds = 0.0
        var stderr = ""
        var ok = true
        for operand in operands {
            guard let parsed = mspSleepParseInterval(operand) else {
                stderr += "sleep: invalid time interval \(MSPPOSIXCommandSupport.gnuQuote(operand))\n"
                ok = false
                continue
            }
            seconds += parsed
        }

        guard ok else {
            return .failure(exitCode: 1, stderr: stderr + mspSleepHelpDiagnostic())
        }

        try await mspSleep(seconds: seconds)
        return .success()
    }
}

private func mspSleepScanArguments(_ arguments: [String]) -> (operands: [String], result: MSPCommandResult?) {
    var operands: [String] = []
    var scansOptions = true
    for argument in arguments {
        if scansOptions, argument == "--" {
            scansOptions = false
            continue
        }
        if scansOptions, argument.hasPrefix("--"), argument.count > 2 {
            return (
                [],
                .failure(
                    exitCode: 1,
                    stderr: "sleep: unrecognized option '\(argument)'\n" + mspSleepHelpDiagnostic()
                )
            )
        }
        if scansOptions, argument.hasPrefix("-"), argument != "-" {
            return (
                [],
                .failure(
                    exitCode: 1,
                    stderr: "sleep: invalid option -- '\(argument.dropFirst().first!)'\n" + mspSleepHelpDiagnostic()
                )
            )
        }
        operands.append(argument)
    }
    return (operands, nil)
}

private func mspSleepParseInterval(_ rawValue: String) -> Double? {
    guard let parsed = mspSleepParseNumericPrefix(rawValue) else {
        return nil
    }
    guard parsed.value >= 0 else {
        return nil
    }
    guard parsed.suffix.count <= 1 else {
        return nil
    }

    let multiplier: Double
    switch parsed.suffix {
    case "", "s":
        multiplier = 1
    case "m":
        multiplier = 60
    case "h":
        multiplier = 60 * 60
    case "d":
        multiplier = 60 * 60 * 24
    default:
        return nil
    }
    return parsed.value * multiplier
}

private func mspSleepParseNumericPrefix(_ rawValue: String) -> (value: Double, suffix: String)? {
    guard !rawValue.isEmpty else {
        return nil
    }
    let lowercased = rawValue.lowercased()
    for spelling in ["infinity", "inf"] {
        if lowercased == spelling || lowercased == "+" + spelling {
            return (.infinity, "")
        }
    }

    var endIndex = rawValue.endIndex
    while endIndex > rawValue.startIndex {
        let prefix = String(rawValue[..<endIndex])
        if let value = Double(prefix) {
            return (value, String(rawValue[endIndex...]))
        }
        endIndex = rawValue.index(before: endIndex)
    }
    return nil
}

private func mspSleep(seconds: Double) async throws {
    guard seconds > 0 else {
        return
    }
    guard seconds.isFinite else {
        while true {
            try await Task.sleep(nanoseconds: mspSleepMaximumChunkNanoseconds)
        }
    }

    var remaining = seconds
    while remaining > 0 {
        let chunkSeconds = min(remaining, mspSleepMaximumChunkSeconds)
        let nanoseconds = max(1, UInt64((chunkSeconds * 1_000_000_000).rounded(.up)))
        try await Task.sleep(nanoseconds: nanoseconds)
        remaining -= chunkSeconds
    }
}

private let mspSleepMaximumChunkSeconds = 60.0
private let mspSleepMaximumChunkNanoseconds: UInt64 = 60_000_000_000

private func mspSleepHelpDiagnostic() -> String {
    "Try 'sleep --help' for more information.\n"
}

private func mspSleepUsage() -> String {
    """
    Usage: sleep NUMBER[SUFFIX]...
      or:  sleep OPTION
    Pause for the requested virtual-safe duration. SUFFIX may be s, m, h, or d.

    """
}
