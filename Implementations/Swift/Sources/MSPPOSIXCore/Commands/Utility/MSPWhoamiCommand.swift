import MSPCore

public struct MSPWhoamiCommand: MSPCommand {
    public let name = "whoami"
    public let summary: String? = "Print the virtual effective user name."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var operands: [String] = []
        var parsingOptions = true
        for argument in invocation.arguments {
            if parsingOptions, argument == "--" {
                parsingOptions = false
                continue
            }
            if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
                if argument == "--help" {
                    return .success(stdout: mspWhoamiUsage())
                }
                if argument == "--version" {
                    return .success(stdout: "whoami (GNU coreutils) 9.1\n")
                }
                return .failure(exitCode: 1, stderr: "whoami: unrecognized option '\(argument)'\n" + mspWhoamiHelpHint())
            }
            if parsingOptions, argument.hasPrefix("-"), argument != "-" {
                let option = argument.dropFirst().first ?? "?"
                return .failure(exitCode: 1, stderr: "whoami: invalid option -- '\(option)'\n" + mspWhoamiHelpHint())
            }
            operands.append(argument)
        }

        guard operands.isEmpty else {
            return .failure(
                exitCode: 1,
                stderr: "whoami: extra operand \(MSPPOSIXCommandSupport.gnuQuote(operands[0]))\n" + mspWhoamiHelpHint()
            )
        }
        return .success(stdout: MSPPOSIXVirtualIdentity.currentUser.name + "\n")
    }
}

private func mspWhoamiHelpHint() -> String {
    "Try 'whoami --help' for more information.\n"
}

private func mspWhoamiUsage() -> String {
    """
    Usage: whoami [OPTION]...
    Print the user name associated with the current effective user ID.

    """
}
