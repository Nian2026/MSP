import MSPCore

public struct MSPGroupsCommand: MSPCommand {
    public let name = "groups"
    public let summary: String? = "Print virtual group memberships."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspGroupsUsage())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "groups (GNU coreutils) 9.1\n")
        }
        let parsed = mspGroupsParse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard !parsed.operands.isEmpty else {
            return .success(stdout: "\(MSPPOSIXVirtualIdentity.currentUser.groupName)\n")
        }

        var stdout = ""
        var stderr = ""
        var ok = true
        for operand in parsed.operands {
            guard let user = MSPPOSIXVirtualIdentity.user(loginName: operand) else {
                stderr += "groups: \(MSPPOSIXCommandSupport.gnuQuote(operand)): no such user\n"
                ok = false
                continue
            }
            stdout += "\(operand) : \(user.groupName)\n"
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: ok ? 0 : 1)
    }
}

private struct MSPGroupsOptions {
    var operands: [String] = []
    var result: MSPCommandResult?
}

private func mspGroupsParse(_ arguments: [String]) -> MSPGroupsOptions {
    var parsed = MSPGroupsOptions()
    var parsingOptions = true
    for argument in arguments {
        if parsingOptions, argument == "--" {
            parsingOptions = false
            continue
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            let message: String
            if argument.hasPrefix("--"), argument.count > 2 {
                message = "groups: unrecognized option '\(argument)'"
            } else {
                message = "groups: invalid option -- '\(argument.dropFirst().first ?? "?")'"
            }
            parsed.result = .failure(
                stderr: "\(message)\nTry 'groups --help' for more information.\n"
            )
            return parsed
        }
        parsed.operands.append(argument)
    }
    return parsed
}

private func mspGroupsUsage() -> String {
    """
    Usage: groups [OPTION]... [USERNAME]...
    Print group memberships for each USERNAME or, if no USERNAME is specified,
    for the current virtual process.

    """
}
