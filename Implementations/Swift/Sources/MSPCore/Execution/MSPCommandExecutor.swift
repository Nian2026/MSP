public struct MSPCommandExecutor {
    public var registry: MSPCommandRegistry

    public init(registry: MSPCommandRegistry) {
        self.registry = registry
    }

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard let command = registry.command(named: invocation.name) else {
            return .failure(
                exitCode: 127,
                stderr: "\(invocation.name): command not found\n"
            )
        }

        do {
            let hasStreamingIO = context.standardInputStream != nil
                || context.standardOutputStream != nil
                || context.standardErrorStream != nil
            if let streamingCommand = command as? any MSPStreamingCommand, hasStreamingIO {
                return try await streamingCommand.runStreaming(invocation: invocation, context: context)
            }
            return try await command.run(invocation: invocation, context: context)
        } catch let error as MSPCommandFailure {
            return error.result
        } catch {
            return .failure(stderr: "\(invocation.name): \(error)\n")
        }
    }
}

public struct MSPCommandFailure: Error, Sendable {
    public var result: MSPCommandResult

    public init(result: MSPCommandResult) {
        self.result = result
    }

    public static func usage(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(exitCode: 2, stderr: message))
    }
}
