import Foundation
import MSPCore

public struct MSPHeadCommand: MSPStreamingCommand {
    public let name = "head"
    public let summary: String? = "Print the first part of files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await MSPHeadTailCommand(command: name).run(arguments: invocation.arguments, context: context)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await MSPHeadTailCommand(command: name).runStreaming(arguments: invocation.arguments, context: context)
    }
}

public struct MSPTailCommand: MSPStreamingCommand {
    public let name = "tail"
    public let summary: String? = "Print the last part of files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await MSPHeadTailCommand(command: name).run(arguments: invocation.arguments, context: context)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await MSPHeadTailCommand(command: name).runStreaming(arguments: invocation.arguments, context: context)
    }
}
