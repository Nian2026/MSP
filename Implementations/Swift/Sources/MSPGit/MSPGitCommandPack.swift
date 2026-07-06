import MSPCore

public struct MSPGitCommandPack: MSPCommandPack {
    public var name: String { "git" }

    private let backend: any MSPGitBackend
    private let commandLookupPaths: [String]

    public init(
        backend: any MSPGitBackend = MSPGitUnavailableBackend(),
        commandLookupPaths: [String] = ["/usr/bin/git"]
    ) {
        self.backend = backend
        self.commandLookupPaths = commandLookupPaths
    }

    public func registerCommands(into registry: MSPCommandRegistry) throws {
        try registry.register(MSPGitCommand(
            backend: backend,
            commandLookupPaths: commandLookupPaths
        ))
    }
}
