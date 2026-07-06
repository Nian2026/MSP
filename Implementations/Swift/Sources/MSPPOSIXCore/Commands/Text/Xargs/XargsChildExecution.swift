import Foundation
import MSPCore

extension MSPXargsCommand {
    func runCommands(
        _ commands: [[String]],
        context: MSPCommandContext,
        verbose: Bool,
        maxCharacters: Int,
        clearsChildStandardInput: Bool
    ) async -> MSPCommandResult {
        var stdout = ""
        var stderr = ""
        var aggregateExitCode: Int32 = 0
        var modelContentItems: [MSPCommandModelContentItem] = []

        for commandWords in commands {
            guard !commandWords.isEmpty else {
                continue
            }
            let rendered = commandWords.map(mspPOSIXShellQuote).joined(separator: " ")
            guard rendered.utf8.count <= maxCharacters else {
                return .failure(exitCode: 1, stdout: stdout, stderr: stderr + "xargs: command line too long\n")
            }
            if verbose {
                stderr += rendered + "\n"
            }
            let result = await mspPOSIXXargsRunChildCommand(
                commandWords,
                rendered: rendered,
                context: context,
                clearsChildStandardInput: clearsChildStandardInput
            )
            stdout += result.stdout
            stderr += result.stderr
            modelContentItems.append(contentsOf: result.modelContentItems)
            aggregateExitCode = mspPOSIXXargsExitCode(
                current: aggregateExitCode,
                childExitCode: result.exitCode
            )
            if result.exitCode == 255 {
                break
            }
        }

        return MSPCommandResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: aggregateExitCode,
            modelContentItems: modelContentItems
        )
    }
}

func mspPOSIXXargsRunChildCommand(
    _ commandWords: [String],
    rendered: String,
    context: MSPCommandContext,
    standardOutputStream: (any MSPCommandOutputStream)? = nil,
    standardErrorStream: (any MSPCommandOutputStream)? = nil,
    clearsChildStandardInput: Bool = true
) async -> MSPCommandResult {
    guard let commandName = commandWords.first else {
        return .success()
    }
    var childContext = context
    if clearsChildStandardInput {
        childContext.standardInput = Data()
        childContext.standardInputClosed = false
        childContext.standardInputStream = nil
    }
    childContext.standardOutputStream = standardOutputStream
    childContext.standardErrorStream = standardErrorStream

    if let subcommandRunner = context.subcommandRunner {
        return await subcommandRunner(
            MSPCommandInvocation(
                name: commandName,
                arguments: Array(commandWords.dropFirst()),
                rawInput: rendered
            ),
            childContext
        )
    }
    if let commandLineRunner = context.commandLineRunner {
        return await commandLineRunner(rendered, childContext)
    }
    return .failure(exitCode: 125, stderr: "shell: command execution is not available\n")
}

func mspPOSIXXargsExitCode(current: Int32, childExitCode: Int32) -> Int32 {
    if current == 124 || current == 126 || current == 127 {
        return current
    }
    if childExitCode == 0 {
        return current
    }
    if childExitCode == 255 {
        return 124
    }
    if childExitCode == 126 || childExitCode == 127 {
        return childExitCode
    }
    return 123
}
