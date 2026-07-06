import MSPCore

func runFindSubcommand(
    _ commandWords: [String],
    commandContext: MSPCommandContext
) async -> MSPCommandResult {
    guard let name = commandWords.first else {
        return .failure(exitCode: 2, stderr: "find: empty -exec command\n")
    }
    return await commandContext.runSubcommand(
        name: name,
        arguments: Array(commandWords.dropFirst()),
        rawInput: commandWords.joined(separator: " ")
    )
}
