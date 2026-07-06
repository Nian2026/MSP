import Foundation
import MSPCore

public struct MSPDdCommand: MSPStreamingCommand {
    public let name = "dd"
    public let summary: String? = "Copy and convert byte streams."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspDdHelp())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "dd (GNU coreutils) 9.1\n")
        }
        let options = try parseMSPDdOptions(invocation.arguments)
        let input = try MSPDdInput.make(options: options, context: context, commandName: name)
        let output = try MSPDdOutput.makeBuffered(options: options, context: context, commandName: name)
        do {
            return try await MSPDdCopyEngine().copy(options: options, input: input, output: output)
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspDdHelp())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "dd (GNU coreutils) 9.1\n")
        }
        let options = try parseMSPDdOptions(invocation.arguments)
        let input = try MSPDdInput.make(options: options, context: context, commandName: name)
        let output: MSPDdOutput
        if options.outputPath == nil, let standardOutput = context.standardOutputStream {
            output = .stream(MSPDdStreamOutput(standardOutput))
        } else {
            output = try MSPDdOutput.makeBuffered(options: options, context: context, commandName: name)
        }
        do {
            return try await MSPDdCopyEngine().copy(options: options, input: input, output: output)
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
    }
}
