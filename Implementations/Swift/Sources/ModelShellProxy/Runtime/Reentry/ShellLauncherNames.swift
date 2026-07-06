import Foundation

enum RuntimeScriptLauncher: Equatable {
    case shell(String)
    case command(name: String, arguments: [String])
}

enum RuntimeShellLauncherNames {
    static func shellLauncherName(for commandName: String) -> String? {
        switch commandName {
        case "sh", "/bin/sh", "/usr/bin/sh", "/usr/local/bin/sh":
            return "sh"
        case "bash", "/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash":
            return "bash"
        case "zsh", "/bin/zsh", "/usr/bin/zsh", "/usr/local/bin/zsh":
            return "zsh"
        default:
            return nil
        }
    }

    static func scriptLauncher(for script: String) -> RuntimeScriptLauncher? {
        guard script.hasPrefix("#!") else {
            return .shell("sh")
        }
        guard let firstLine = script.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else {
            return .shell("sh")
        }
        let interpreterLine = firstLine.dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interpreterLine.isEmpty else {
            return .shell("sh")
        }
        let parts = interpreterLine.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard let executable = parts.first else {
            return .shell("sh")
        }
        if let launcher = shellLauncherName(for: executable) {
            return .shell(launcher)
        }
        if let commandName = pythonCommandName(for: executable) {
            return .command(name: commandName, arguments: Array(parts.dropFirst()))
        }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        if executableName == "env" {
            var envArguments = Array(parts.dropFirst())
            if envArguments.first == "-S" {
                envArguments.removeFirst()
            }
            guard let commandIndex = envArguments.firstIndex(where: { !$0.hasPrefix("-") }) else {
                return nil
            }
            let candidate = envArguments[commandIndex]
            if let launcher = shellLauncherName(for: candidate) {
                return .shell(launcher)
            }
            if let commandName = pythonCommandName(for: candidate) {
                return .command(
                    name: commandName,
                    arguments: Array(envArguments[(commandIndex + 1)...])
                )
            }
        }
        return nil
    }

    static func scriptShellLauncherName(for script: String) -> String? {
        if case .shell(let launcher) = scriptLauncher(for: script) {
            return launcher
        }
        return nil
    }

    private static func pythonCommandName(for executable: String) -> String? {
        switch executable {
        case "python", "/bin/python", "/usr/bin/python", "/usr/local/bin/python":
            return "python"
        case "python3", "/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3":
            return "python3"
        default:
            return nil
        }
    }
}
