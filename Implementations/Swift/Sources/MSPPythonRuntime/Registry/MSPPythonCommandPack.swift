import MSPCore

public struct MSPPythonCommandPack: MSPCommandPack {
    public var name: String { "python-runtime" }

    public var commandNames: [String]
    public var runtime: any MSPPythonRuntime

    public init(
        runtime: any MSPPythonRuntime,
        commandNames: [String] = ["python", "python3"]
    ) {
        self.runtime = runtime
        self.commandNames = commandNames
    }

    public func registerCommands(into registry: MSPCommandRegistry) throws {
        for commandName in commandNames {
            try registry.register(MSPPythonCommand(name: commandName, runtime: runtime))
        }
    }
}
