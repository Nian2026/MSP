import MSPCore

public struct MSPPrintenvCommand: MSPCommand {
    public let name = "printenv"
    public let summary: String? = "Print all or selected environment variables."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = mspPrintenvParse(invocation.arguments)
        if let result = parsed.result {
            return result
        }

        let separator = parsed.nullTerminated ? "\0" : "\n"
        guard !parsed.operands.isEmpty else {
            let lines = context.environment.keys.sorted().map { "\($0)=\(context.environment[$0] ?? "")" }
            return .success(stdout: lines.isEmpty ? "" : lines.joined(separator: separator) + separator)
        }

        var values: [String] = []
        var matches = 0
        for operand in parsed.operands {
            guard !operand.contains("="), let value = context.environment[operand] else {
                continue
            }
            values.append(value)
            matches += 1
        }
        return MSPCommandResult(
            stdout: values.isEmpty ? "" : values.joined(separator: separator) + separator,
            exitCode: matches == parsed.operands.count ? 0 : 1
        )
    }
}

private struct MSPPrintenvOptions {
    var nullTerminated = false
    var operands: [String] = []
    var result: MSPCommandResult?
}

private func mspPrintenvParse(_ arguments: [String]) -> MSPPrintenvOptions {
    var parsed = MSPPrintenvOptions()
    var parsingOptions = true
    for argument in arguments {
        if parsingOptions, argument == "--" {
            parsingOptions = false
            continue
        }
        if parsingOptions, argument == "--null" {
            parsed.nullTerminated = true
            continue
        }
        if parsingOptions, argument == "--help" {
            parsed.result = .success(stdout: mspPrintenvHelpText())
            return parsed
        }
        if parsingOptions, argument == "--version" {
            parsed.result = .success(stdout: "printenv (MSP coreutils-compatible) 9.1\n")
            return parsed
        }
        if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
            parsed.result = .failure(
                exitCode: 2,
                stderr: "printenv: unrecognized option '\(argument)'\nTry 'printenv --help' for more information.\n"
            )
            return parsed
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            for option in argument.dropFirst() {
                guard option == "0" else {
                    parsed.result = .failure(
                        exitCode: 2,
                        stderr: "printenv: invalid option -- '\(option)'\nTry 'printenv --help' for more information.\n"
                    )
                    return parsed
                }
                parsed.nullTerminated = true
            }
            continue
        }
        parsed.operands.append(argument)
    }
    return parsed
}

private func mspPrintenvHelpText() -> String {
    """
    Usage: printenv [OPTION]... [VARIABLE]...
    Print the values of the specified environment VARIABLE(s).

      -0, --null     end each output line with NUL, not newline
          --help     display this help and exit
          --version  output version information and exit

    """
}
