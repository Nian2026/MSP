import MSPCore

public extension MSPProfile {
    static func python(
        runtime: any MSPPythonRuntime,
        commandNames: [String] = ["python", "python3"]
    ) -> MSPProfile {
        MSPProfile(name: "python-runtime") { registry in
            try MSPPythonCommandPack(
                runtime: runtime,
                commandNames: commandNames
            ).registerCommands(into: registry)
        }
    }
}
