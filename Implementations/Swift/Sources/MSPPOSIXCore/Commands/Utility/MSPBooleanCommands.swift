import MSPCore

public struct MSPTrueCommand: MSPCommand {
    public let name = "true"
    public let summary: String? = "Return a successful exit status."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: mspPOSIXBooleanHelpText(command: name))
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "true (MSP coreutils-compatible) 9.1\n")
        }
        return MSPCommandResult(exitCode: 0)
    }
}

public struct MSPFalseCommand: MSPCommand {
    public let name = "false"
    public let summary: String? = "Return an unsuccessful exit status."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: mspPOSIXBooleanHelpText(command: name))
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "false (MSP coreutils-compatible) 9.1\n")
        }
        return MSPCommandResult(exitCode: 1)
    }
}

private func mspPOSIXBooleanHelpText(command: String) -> String {
    """
    Usage: \(command) [ignored command line arguments]
      or:  \(command) OPTION
    Exit with a status code indicating \(command).

          --help     display this help and exit
          --version  output version information and exit

    """
}
