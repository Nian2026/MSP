import Foundation
import MSPCore

public struct MSPGitCommand: MSPStreamingCommand, MSPCommandLookupPathProviding {
    public let name = "git"
    public let summary: String? = "Run Git through a Git-compatible MSP backend."
    public var commandLookupPaths: [String]

    private let backend: any MSPGitBackend

    public init(
        backend: any MSPGitBackend,
        commandLookupPaths: [String] = ["/usr/bin/git"]
    ) {
        self.backend = backend
        self.commandLookupPaths = commandLookupPaths
    }

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let workspaceMapping: MSPGitWorkspaceMapping?
        if context.workspace == nil {
            workspaceMapping = nil
        } else {
            workspaceMapping = try MSPGitWorkspaceMapping(context: context)
        }
        let request = MSPGitCommandRequest(
            modelArgv: [invocation.name] + invocation.arguments,
            arguments: invocation.arguments,
            environment: context.environment,
            currentDirectory: context.currentDirectory,
            standardInput: context.standardInput,
            standardInputClosed: context.standardInputClosed,
            workspaceMapping: workspaceMapping
        )
        return try await backend.run(request, context: context)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var result = try await run(invocation: invocation, context: context)
        do {
            if let standardOutput = context.standardOutputStream,
               !result.stdoutData.isEmpty {
                try await standardOutput.write(result.stdoutData)
                result.stdoutData = Data()
            }
            if let standardError = context.standardErrorStream,
               !result.stderrData.isEmpty {
                try await standardError.write(result.stderrData)
                result.stderrData = Data()
            }
        } catch MSPCommandStreamError.brokenPipe {
            result.stdoutData = Data()
            result.stderrData = Data()
        }
        return result
    }
}
