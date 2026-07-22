import MSPCore

public struct MSPPythonModuleCommandPack: MSPCommandPack {
    public var name: String
    public var commandName: String
    public var moduleName: String
    public var summary: String?
    public var commandLookupPaths: [String]
    public var runtime: any MSPPythonRuntime

    public init(
        commandName: String,
        moduleName: String,
        runtime: any MSPPythonRuntime,
        summary: String? = nil,
        commandLookupPaths: [String] = []
    ) {
        self.name = "python-module-\(commandName)"
        self.commandName = commandName
        self.moduleName = moduleName
        self.summary = summary
        self.commandLookupPaths = commandLookupPaths
        self.runtime = runtime
    }

    public func registerCommands(into registry: MSPCommandRegistry) throws {
        try registry.register(MSPPythonModuleCommand(
            name: commandName,
            moduleName: moduleName,
            summary: summary,
            commandLookupPaths: commandLookupPaths,
            runtime: runtime
        ))
    }
}

private struct MSPPythonModuleCommand: MSPStreamingCommand, MSPCommandLookupPathProviding {
    var name: String
    var moduleName: String
    var summary: String?
    var commandLookupPaths: [String]
    var runtime: any MSPPythonRuntime

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        await runtime.runPython(
            request: request(invocation: invocation, context: context),
            context: context
        )
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        await runtime.runPythonStreaming(
            request: request(invocation: invocation, context: context),
            context: context
        )
    }

    private func request(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) -> MSPPythonExecutionRequest {
        MSPPythonExecutionRequest(
            invocation: MSPPythonInvocation(
                commandName: invocation.name,
                arguments: invocation.arguments,
                rawInput: invocation.rawInput
            ),
            entrypoint: .module(
                name: moduleName,
                arguments: invocation.arguments
            ),
            virtualCurrentDirectory: context.currentDirectory
        )
    }
}
