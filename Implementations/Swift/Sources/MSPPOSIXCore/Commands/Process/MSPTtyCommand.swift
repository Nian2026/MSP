import MSPCore

public struct MSPTtyCommand: MSPCommand {
    public let name = "tty"
    public let summary: String? = "Print whether standard input is a terminal."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed: MSPPOSIXParsedArguments
        do {
            parsed = try MSPPOSIXCommandSpec(
                name: name,
                allowedShortOptions: ["s"],
                allowedLongOptions: ["help", "quiet", "silent", "version"]
            ).parse(invocation.arguments)
        } catch let failure as MSPCommandFailure {
            throw mspPOSIXTtyOptionFailure(failure)
        }
        if parsed.options.contains(where: { $0.matches(long: "help") }) {
            return .success(stdout: mspTtyUsage())
        }
        if parsed.options.contains(where: { $0.matches(long: "version") }) {
            return .success(stdout: "tty (GNU coreutils) 9.1\n")
        }
        guard parsed.operands.isEmpty else {
            return .failure(
                exitCode: 2,
                stderr: "tty: extra operand \(MSPPOSIXCommandSupport.gnuQuote(parsed.operands[0]))\nTry 'tty --help' for more information.\n"
            )
        }
        let silent = parsed.options.contains { $0.matches(short: "s", long: "silent") || $0.matches(long: "quiet") }
        return MSPCommandResult(stdout: silent ? "" : "not a tty\n", exitCode: 1)
    }
}

private func mspTtyUsage() -> String {
    """
    Usage: tty [OPTION]...
    Print the file name of the terminal connected to standard input.

    """
}

private func mspPOSIXTtyOptionFailure(_ failure: MSPCommandFailure) -> MSPCommandFailure {
    let prefix = "tty: unsupported option -- "
    guard failure.result.stderr.hasPrefix(prefix) else {
        return failure
    }
    let option = String(failure.result.stderr.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let message: String
    if option.count == 1 {
        message = "tty: invalid option -- '\(option)'\n"
    } else {
        message = "tty: unrecognized option '--\(option)'\n"
    }
    return MSPCommandFailure(result: .failure(
        exitCode: 2,
        stderr: message + "Try 'tty --help' for more information.\n"
    ))
}
