import MSPCore

public struct MSPLinkCommand: MSPCommand {
    public let name = "link"
    public let summary: String? = "Create a hard link using WorkspaceFS."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: Self.helpText)
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "link (MSP coreutils-compatible) 9.1\n")
        }
        let parsed = try MSPPOSIXCommandSpec(name: name).parse(invocation.arguments)
        if parsed.operands.count < 2 {
            let stderr: String
            if let operand = parsed.operands.first {
                stderr = "link: missing operand after \(mspPOSIXLinkQuote(operand))\nTry 'link --help' for more information.\n"
            } else {
                stderr = "link: missing operand\nTry 'link --help' for more information.\n"
            }
            return .failure(stderr: stderr)
        }
        if parsed.operands.count > 2 {
            return .failure(
                stderr: "link: extra operand \(mspPOSIXLinkQuote(parsed.operands[2]))\nTry 'link --help' for more information.\n"
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        do {
            try fileSystem.createHardLink(
                source: parsed.operands[0],
                at: parsed.operands[1],
                from: context.currentDirectory
            )
            return .success()
        } catch {
            return .failure(
                stderr: "link: cannot create link \(mspPOSIXLinkQuote(parsed.operands[1])) to \(mspPOSIXLinkQuote(parsed.operands[0])): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            )
        }
    }

    private static let helpText = """
    Usage: link FILE1 FILE2
    Create a link named FILE2 to an existing FILE1.

          --help     display this help and exit
          --version  output version information and exit

    """
}

private func mspPOSIXLinkQuote(_ value: String) -> String {
    "'\(value)'"
}
