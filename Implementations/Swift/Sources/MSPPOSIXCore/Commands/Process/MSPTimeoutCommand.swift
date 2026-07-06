import Foundation
import MSPCore

public struct MSPTimeoutCommand: MSPCommand {
    public let name = "timeout"
    public let summary: String? = "Run a command with a time limit."

    private let spec = MSPPOSIXCommandSpec(
        name: "timeout",
        allowedShortOptions: ["v"],
        allowedLongOptions: ["foreground", "help", "preserve-status", "verbose", "version"],
        shortOptionsRequiringValue: ["k", "s"],
        longOptionsRequiringValue: ["kill-after", "signal"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed: MSPPOSIXParsedArguments
        do {
            parsed = try spec.parse(
                invocation.arguments,
                stopAtFirstOperand: true,
                treatNegativeNumbersAsOperands: true
            )
        } catch let failure as MSPCommandFailure {
            return .failure(
                exitCode: 125,
                stderr: mspTimeoutOptionDiagnostic(from: failure.result.stderr)
            )
        }
        if parsed.options.contains(where: { $0.matches(long: "help") }) {
            return .success(stdout: mspTimeoutUsage())
        }
        if parsed.options.contains(where: { $0.matches(long: "version") }) {
            return .success(stdout: "timeout (GNU coreutils) 9.1\n")
        }
        let verbose = parsed.options.contains { $0.matches(short: "v", long: "verbose") }
        guard let durationText = parsed.operands.first else {
            return .failure(exitCode: 125, stderr: mspTimeoutHelpDiagnostic())
        }
        guard let timeout = mspPOSIXParseTimeoutDuration(durationText), timeout >= 0 else {
            return .failure(
                exitCode: 125,
                stderr: "timeout: invalid time interval \(mspTimeoutGNUQuoted(durationText))\n"
                    + mspTimeoutHelpDiagnostic()
            )
        }
        let commandWords = Array(parsed.operands.dropFirst())
        guard let target = commandWords.first else {
            return .failure(exitCode: 125, stderr: mspTimeoutHelpDiagnostic())
        }
        if !context.availableCommandNames.isEmpty,
           !context.availableCommandNames.contains(target) {
            return .failure(
                exitCode: 127,
                stderr: "timeout: failed to run command \(mspTimeoutGNUQuoted(target)): No such file or directory\n"
            )
        }

        let runCommand = {
            await context.runSubcommand(
                name: target,
                arguments: Array(commandWords.dropFirst()),
                rawInput: commandWords.map(mspPOSIXShellQuote).joined(separator: " "),
                standardInput: context.standardInput
            )
        }
        guard timeout > 0 else {
            return await runCommand()
        }

        let nanoseconds = UInt64(min(timeout, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        let race = MSPTimeoutRace()
        let commandTask = Task {
            await runCommand()
        }

        return await withCheckedContinuation { continuation in
            Task {
                let result = await commandTask.value
                if await race.finish() {
                    continuation.resume(returning: result)
                }
            }
            Task {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                commandTask.cancel()
                if await race.finish() {
                    let stderr = verbose
                        ? "timeout: sending signal TERM to command \(mspTimeoutGNUQuoted(target))\n"
                        : ""
                    continuation.resume(returning: .failure(exitCode: 124, stderr: stderr))
                }
            }
        }
    }
}

private actor MSPTimeoutRace {
    private var finished = false

    func finish() -> Bool {
        guard !finished else {
            return false
        }
        finished = true
        return true
    }
}

private func mspPOSIXParseTimeoutDuration(_ raw: String) -> TimeInterval? {
    guard let parsed = mspTimeoutParseNumericPrefix(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    guard parsed.value >= 0, parsed.suffix.count <= 1 else {
        return nil
    }
    switch parsed.suffix {
    case "", "s":
        return parsed.value
    case "m":
        return parsed.value * 60
    case "h":
        return parsed.value * 60 * 60
    case "d":
        return parsed.value * 60 * 60 * 24
    default:
        return nil
    }
}

private func mspTimeoutParseNumericPrefix(_ rawValue: String) -> (value: Double, suffix: String)? {
    guard !rawValue.isEmpty else {
        return nil
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

private func mspTimeoutHelpDiagnostic() -> String {
    "Try 'timeout --help' for more information.\n"
}

private func mspTimeoutOptionDiagnostic(from parserDiagnostic: String) -> String {
    let diagnostic = parserDiagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
    let unsupportedPrefix = "timeout: unsupported option -- "
    if diagnostic.hasPrefix(unsupportedPrefix) {
        let option = String(diagnostic.dropFirst(unsupportedPrefix.count))
        return "timeout: unrecognized option '--\(option)'\n" + mspTimeoutHelpDiagnostic()
    }
    guard !diagnostic.isEmpty else {
        return mspTimeoutHelpDiagnostic()
    }
    return diagnostic + "\n" + mspTimeoutHelpDiagnostic()
}

private func mspTimeoutGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private func mspTimeoutUsage() -> String {
    """
    Usage: timeout [OPTION] DURATION COMMAND [ARG]...
    Run a virtual MSP command with a time limit.

    """
}
