import MSPCore

public struct MSPChatCommand: MSPCommand {
    public let name = "chat"
    public let summary: String? = "Read and project MSP .chat packages."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let help = MSPChatCommandHelp.result(for: invocation.arguments) {
            return help
        }

        guard let subcommand = invocation.arguments.first else {
            throw MSPCommandFailure.usage(Self.usage)
        }

        switch subcommand {
        case "read":
            return try await MSPChatReadCommand().run(
                arguments: Array(invocation.arguments.dropFirst()),
                context: context
            )
        default:
            throw MSPCommandFailure.usage(Self.usage)
        }
    }

    private static let usage = "chat: usage: chat read <path> [--scope full|recent] [--cursor <cursor>] [--turn-limit <n>] [--include-outputs|--no-outputs] [--max-output-chars-per-item <n>]\n"
}

private enum MSPChatCommandHelp {
    static func result(for arguments: [String]) -> MSPCommandResult? {
        guard !arguments.isEmpty else {
            return nil
        }

        if arguments.first == "help" {
            let topic = Array(arguments.dropFirst()).joined(separator: " ")
            return helpResult(for: topic)
        }

        if arguments.contains("--help") || arguments.contains("-h") {
            let topic = arguments.first == "read" ? "read" : ""
            return helpResult(for: topic)
        }

        return nil
    }

    private static func helpResult(for topic: String) -> MSPCommandResult {
        switch topic {
        case "":
            return .success(stdout: rootHelp + "\n")
        case "read":
            return .success(stdout: readHelp + "\n")
        default:
            return .failure(exitCode: 2, stderr: "chat help: unknown topic \(topic)\n\n\(rootHelp)\n")
        }
    }

    private static let rootHelp = """
    chat

    Usage:
      chat read <path> [options]

    Help:
      chat help read
    """

    private static let readHelp = """
    chat read

    Usage:
      chat read <path> [options]

    Options:
      --scope full|recent
      --cursor <cursor>
      --turn-limit <n>
      --include-outputs
      --no-outputs
      --max-output-chars-per-item <n>
      --json

    Description:
      Read a saved MSP .chat conversation package.
      Use --scope recent with --turn-limit for quick orientation.
      Use --scope full when the complete conversation is needed.
      Use --cursor <cursor> to continue when the output provides a next cursor.
      Use --no-outputs when long tool output would add noise.
      Use --json only when a program needs a structured projection.

    Examples:
      chat read "/Conversations/answer.chat" --scope recent --turn-limit 5
      chat read "/Conversations/answer.chat" --scope full --no-outputs
      chat read "/Conversations/answer.chat" --cursor full-after:turn_01HXYZ
    """
}
