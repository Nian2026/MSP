import MSPCore

public typealias MSPCommandHandler = @Sendable (
    MSPCommandContext,
    [String]
) async throws -> MSPCommandResult

public struct MSPClosureCommand: MSPCommand {
    public var name: String
    public var summary: String?
    private let handler: MSPCommandHandler

    public init(
        name: String,
        summary: String? = nil,
        handler: @escaping MSPCommandHandler
    ) {
        self.name = name
        self.summary = summary
        self.handler = handler
    }

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await handler(context, invocation.arguments)
    }
}

public extension MSPCommandRegistry {
    func register(
        _ name: String,
        summary: String? = nil,
        handler: @escaping MSPCommandHandler
    ) throws {
        try register(MSPClosureCommand(name: name, summary: summary, handler: handler))
    }
}
