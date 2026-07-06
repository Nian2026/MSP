import MSPCore

public struct MSPUnlinkCommand: MSPCommand {
    public let name = "unlink"
    public let summary: String? = "Unlink one workspace file."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: Self.helpText)
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "unlink (MSP coreutils-compatible) 9.1\n")
        }
        let parsed = parse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard let operand = parsed.operands.first else {
            return mspCore100MissingOperand(name)
        }
        guard parsed.operands.count == 1 else {
            return .failure(
                exitCode: 1,
                stderr: "unlink: extra operand \(mspCore100CurlyQuote(parsed.operands[1]))\n\(mspCore100GNUHelpHint(name))"
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        do {
            let info = try fileSystem.stat(operand, from: context.currentDirectory)
            guard info.type != .directory else {
                return .failure(
                    stderr: "unlink: cannot unlink '\(mspCore100DisplayPath(operand))': Is a directory\n"
                )
            }
            try fileSystem.remove(info.virtualPath, from: "/", recursive: false)
            return .success()
        } catch {
            return .failure(
                stderr: "unlink: cannot unlink '\(mspCore100DisplayPath(operand))': \(mspCore100Reason(error))\n"
            )
        }
    }

    private static let helpText = """
    Usage: unlink FILE
    Call the unlink function to remove the specified FILE.

          --help     display this help and exit
          --version  output version information and exit

    """

    private func parse(_ arguments: [String]) -> UnlinkParseResult {
        var operands: [String] = []
        var parsingOptions = true
        for argument in arguments {
            if !parsingOptions {
                operands.append(argument)
                continue
            }
            if argument == "--" {
                parsingOptions = false
                continue
            }
            if argument.hasPrefix("--"), argument.count > 2 {
                let option = argument.dropFirst(2).first ?? "?"
                return UnlinkParseResult(operands: operands, result: mspCore100InvalidOption(name, option: option))
            }
            if argument.hasPrefix("-"), argument != "-" {
                let option = argument.dropFirst().first ?? "?"
                return UnlinkParseResult(operands: operands, result: mspCore100InvalidOption(name, option: option))
            }
            operands.append(argument)
        }
        return UnlinkParseResult(operands: operands, result: nil)
    }
}

private struct UnlinkParseResult {
    var operands: [String]
    var result: MSPCommandResult?
}
