import MSPCore

public struct MSPChatCommandPack: MSPCommandPack {
    public let name = "msp-chat"

    public init() {}

    public func registerCommands(into registry: MSPCommandRegistry) throws {
        try registry.register(MSPChatCommand())
    }
}
