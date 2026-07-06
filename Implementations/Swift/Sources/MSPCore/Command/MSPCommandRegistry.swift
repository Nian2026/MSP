public enum MSPCommandRegistryError: Error, Equatable, CustomStringConvertible {
    case duplicateCommand(String)

    public var description: String {
        switch self {
        case .duplicateCommand(let name):
            return "command already registered: \(name)"
        }
    }
}

public final class MSPCommandRegistry: @unchecked Sendable {
    private var commands: [String: any MSPCommand]

    public init(commands: [any MSPCommand] = []) throws {
        self.commands = [:]
        for command in commands {
            try register(command)
        }
    }

    public func register(_ command: any MSPCommand) throws {
        if commands[command.name] != nil {
            throw MSPCommandRegistryError.duplicateCommand(command.name)
        }
        commands[command.name] = command
    }

    public func command(named name: String) -> (any MSPCommand)? {
        commands[name]
    }

    public var commandNames: [String] {
        commands.keys.sorted()
    }

    public var commandLookupPaths: [String: [String]] {
        var paths: [String: [String]] = [:]
        for (name, command) in commands {
            guard let provider = command as? any MSPCommandLookupPathProviding else {
                continue
            }
            let commandPaths = provider.commandLookupPaths
            guard !commandPaths.isEmpty else {
                continue
            }
            paths[name] = commandPaths
        }
        return paths
    }
}

public protocol MSPCommandPack {
    var name: String { get }

    func registerCommands(into registry: MSPCommandRegistry) throws
}
