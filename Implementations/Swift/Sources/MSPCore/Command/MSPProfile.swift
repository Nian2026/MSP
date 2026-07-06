public struct MSPProfile {
    public var name: String
    private let registerImplementation: (MSPCommandRegistry) throws -> Void

    public init(
        name: String,
        register: @escaping (MSPCommandRegistry) throws -> Void
    ) {
        self.name = name
        self.registerImplementation = register
    }

    public func registerCommands(into registry: MSPCommandRegistry) throws {
        try registerImplementation(registry)
    }
}
