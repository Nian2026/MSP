import MSPShell

enum ShellVirtualExecutableCommandPath {
    static let defaultEnvironmentPath = "/usr/local/bin:/usr/bin:/bin"

    private static let shellOnlyCommandNames: Set<String> = [
        ".",
        ":",
        "[[",
        "alias",
        "break",
        "builtin",
        "cd",
        "command",
        "continue",
        "declare",
        "eval",
        "exec",
        "exit",
        "export",
        "local",
        "mapfile",
        "read",
        "readarray",
        "readonly",
        "return",
        "set",
        "shift",
        "shopt",
        "source",
        "trap",
        "type",
        "typeset",
        "umask",
        "unalias",
        "unset"
    ]

    private static let pathIndependentCommandNames: Set<String> = [
        ".",
        ":",
        "[",
        "[[",
        "alias",
        "break",
        "builtin",
        "cd",
        "command",
        "continue",
        "declare",
        "echo",
        "eval",
        "exec",
        "exit",
        "export",
        "false",
        "local",
        "mapfile",
        "printf",
        "pwd",
        "read",
        "readarray",
        "readonly",
        "return",
        "set",
        "shift",
        "shopt",
        "source",
        "test",
        "trap",
        "true",
        "type",
        "typeset",
        "umask",
        "unalias",
        "unset"
    ]

    private static let knownExternalCommandPaths: [String: [String]] = [
        "sh": ["/usr/bin/sh", "/bin/sh"]
    ]

    static func commandName(
        for commandPath: String,
        registryCommandNames: [String],
        commandLookupPaths: [String: [String]]
    ) -> String? {
        guard commandPath.contains("/") else {
            return nil
        }
        let normalizedPath = normalizedAbsolutePath(commandPath)
        guard normalizedPath.hasPrefix("/") else {
            return nil
        }

        for name in registryCommandNames.sorted() {
            let paths = commandLookupPaths[name] ?? []
            guard !paths.isEmpty else {
                continue
            }
            let normalizedPaths = paths.map(normalizedAbsolutePath)
            if normalizedPaths.contains(normalizedPath) {
                return name
            }
        }

        for name in registryCommandNames.sorted() where !shellOnlyCommandNames.contains(name) {
            if commandLookupPaths[name]?.isEmpty == false {
                continue
            }
            if ["/usr/bin/\(name)", "/bin/\(name)"].contains(normalizedPath) {
                return name
            }
        }
        return nil
    }

    static func commandCanRunWithPathSearch(
        commandName: String,
        resolvedExplicitVirtualExecutablePath: Bool,
        availableCommandNames: [String],
        commandLookupPaths: [String: [String]],
        environmentPath: String?
    ) -> Bool {
        if resolvedExplicitVirtualExecutablePath || commandName.contains("/") {
            return true
        }
        if pathIndependentCommandNames.contains(commandName) {
            return true
        }
        guard availableCommandNames.contains(commandName) else {
            return false
        }
        let executablePaths = executablePaths(
            for: commandName,
            commandLookupPaths: commandLookupPaths
        )
        guard !executablePaths.isEmpty else {
            return false
        }
        let executablePathSet = Set(executablePaths.map(normalizedAbsolutePath))
        return pathEntries(environmentPath ?? defaultEnvironmentPath).contains { directory in
            let candidate = directory == "/" ? "/\(commandName)" : "\(directory)/\(commandName)"
            return executablePathSet.contains(normalizedAbsolutePath(candidate))
        }
    }

    private static func executablePaths(
        for commandName: String,
        commandLookupPaths: [String: [String]]
    ) -> [String] {
        if let paths = commandLookupPaths[commandName], !paths.isEmpty {
            return paths
        }
        if let paths = knownExternalCommandPaths[commandName] {
            return paths
        }
        return ["/usr/bin/\(commandName)", "/bin/\(commandName)"]
    }

    private static func pathEntries(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return []
        }
        return path
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { entry in
                entry.isEmpty ? "." : normalizedAbsolutePath(String(entry))
            }
    }

    private static func normalizedAbsolutePath(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return path
        }
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case "", ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(String(component))
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

enum ShellCommandDispatch {
    case functionDefinition(MSPParsedFunctionDefinition)
    case execBuiltin
    case returnBuiltin
    case loopControlBuiltin
    case exitBuiltin
    case evalBuiltin
    case shiftBuiltin
    case setBuiltin
    case shoptBuiltin
    case declarationBuiltin
    case variableAttributeBuiltin
    case aliasBuiltin
    case trapBuiltin
    case umaskBuiltin
    case unsetBuiltin
    case localBuiltin
    case readBuiltin
    case mapfileBuiltin
    case sourceBuiltin
    case shellLauncher(name: String)
    case structuredCompound(MSPParsedStructuredCompoundCommand)
    case arithmetic(String)
    case assignmentOnly
    case shellFunction(definition: MSPParsedFunctionDefinition, diagnosticSourceName: String?)
    case doubleBracketRegex
    case pathScript
    case registryCommand
}

struct ShellCommandDispatcher {
    var shellFunctions: [String: MSPParsedFunctionDefinition]
    var shellFunctionSourceNames: [String: String]
    var shellLauncherName: (String) -> String?

    func dispatch(_ parsed: MSPParsedCommandLine) -> ShellCommandDispatch {
        if let functionDefinition = parsed.functionDefinition {
            return .functionDefinition(functionDefinition)
        }

        switch parsed.commandName {
        case "exec":
            return .execBuiltin
        case "return":
            return .returnBuiltin
        case "break", "continue":
            return .loopControlBuiltin
        case "exit":
            return .exitBuiltin
        case "eval":
            return .evalBuiltin
        case "shift":
            return .shiftBuiltin
        case "set":
            return .setBuiltin
        case "shopt":
            return .shoptBuiltin
        case "declare", "typeset":
            return .declarationBuiltin
        case "export", "readonly":
            return .variableAttributeBuiltin
        case "alias", "unalias":
            return .aliasBuiltin
        case "trap":
            return .trapBuiltin
        case "umask":
            return .umaskBuiltin
        case "unset":
            return .unsetBuiltin
        case "local":
            return .localBuiltin
        case "read":
            return .readBuiltin
        case "mapfile", "readarray":
            return .mapfileBuiltin
        case ".", "source":
            return .sourceBuiltin
        default:
            break
        }

        if let launcher = shellLauncherName(parsed.commandName) {
            return .shellLauncher(name: launcher)
        }
        if let compoundCommand = parsed.structuredCompoundCommand {
            return .structuredCompound(compoundCommand)
        }
        if let arithmeticExpression = parsed.arithmeticExpression {
            return .arithmetic(arithmeticExpression)
        }
        if parsed.isAssignmentOnly {
            return .assignmentOnly
        }
        if let functionDefinition = shellFunctions[parsed.commandName] {
            return .shellFunction(
                definition: functionDefinition,
                diagnosticSourceName: shellFunctionSourceNames[parsed.commandName]
            )
        }
        if parsed.commandName == "[[", parsed.arguments.contains("=~") {
            return .doubleBracketRegex
        }
        if parsed.commandName.contains("/") {
            return .pathScript
        }
        return .registryCommand
    }
}
