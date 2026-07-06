import MSPCore

public struct MSPExternalCommandRequest: Sendable, Equatable {
    public var executableName: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String

    public init(
        executableName: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String = "/"
    ) {
        self.executableName = executableName
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public protocol MSPExternalCommandRunner: Sendable {
    func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult
}

public struct MSPExternalCommand: MSPStreamingCommand, MSPCommandLookupPathProviding {
    public var name: String
    public var summary: String?
    public var commandLookupPaths: [String]
    private let runner: any MSPExternalCommandRunner

    public init(
        name: String,
        summary: String? = nil,
        commandLookupPaths: [String] = [],
        runner: any MSPExternalCommandRunner
    ) {
        self.name = name
        self.summary = summary
        self.commandLookupPaths = commandLookupPaths
        self.runner = runner
    }

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let request = MSPExternalCommandRequest(
            executableName: invocation.name,
            arguments: invocation.arguments,
            environment: context.environment,
            workingDirectory: context.currentDirectory
        )
        return try await runner.run(request, context: context)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await run(invocation: invocation, context: context)
    }
}

public extension MSPCommandRegistry {
    func registerExternalCommand(
        _ name: String,
        summary: String? = nil,
        commandLookupPaths: [String] = [],
        runner: any MSPExternalCommandRunner
    ) throws {
        try register(
            MSPExternalCommand(
                name: name,
                summary: summary,
                commandLookupPaths: commandLookupPaths,
                runner: runner
            )
        )
    }
}
