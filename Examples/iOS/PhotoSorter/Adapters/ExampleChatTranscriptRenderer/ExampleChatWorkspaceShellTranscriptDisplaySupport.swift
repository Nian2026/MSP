import Foundation

struct ExampleChatWorkspaceShellCommandSummary: Hashable {
    var kind: String
    var target: String?
    var query: String?
}

struct ExampleChatWorkspaceShellCommandAction: Hashable {
    var type: String
    var command: String
    var name: String?
    var path: String?
    var query: String?

    var payload: [String: Any] {
        [
            "type": type,
            "command": command,
            "name": name ?? "",
            "path": path ?? "",
            "query": query ?? ""
        ]
    }
}

enum ExampleChatWorkspaceShellTranscriptDisplaySupport {
    static func shellCommandAction(for command: String) -> ExampleChatWorkspaceShellCommandAction {
        let summary = shellCommandSummary(for: command)
        let type: String
        switch summary.kind {
        case "read":
            type = "read"
        case "list_files":
            type = "list_files"
        case "search":
            type = "search"
        default:
            type = "unknown"
        }
        return ExampleChatWorkspaceShellCommandAction(
            type: type,
            command: command,
            name: summary.target,
            path: summary.target,
            query: summary.query
        )
    }

    static func shellCommandSummary(for command: String) -> ExampleChatWorkspaceShellCommandSummary {
        let tokens = shellFirstCommandTokens(command)
        guard let executable = tokens.first else {
            return ExampleChatWorkspaceShellCommandSummary(kind: "unknown")
        }
        let arguments = Array(tokens.dropFirst())
        switch executable {
        case "pwd", "cd":
            return ExampleChatWorkspaceShellCommandSummary(kind: "location", target: shellLastPathArgument(arguments))
        case "ls", "find":
            return ExampleChatWorkspaceShellCommandSummary(kind: "list_files", target: shellLastPathArgument(arguments))
        case "cat", "head", "tail", "sed":
            return ExampleChatWorkspaceShellCommandSummary(kind: "read", target: shellLastPathArgument(arguments))
        case "rg", "grep":
            let query = shellSearchQuery(arguments)
            return ExampleChatWorkspaceShellCommandSummary(
                kind: "search",
                target: shellLastPathArgument(arguments),
                query: query
            )
        case "mv":
            return ExampleChatWorkspaceShellCommandSummary(kind: "move", target: shellLastPathArgument(arguments))
        case "cp":
            return ExampleChatWorkspaceShellCommandSummary(kind: "copy", target: shellLastPathArgument(arguments))
        case "trash":
            return ExampleChatWorkspaceShellCommandSummary(kind: "trash", target: shellLastPathArgument(arguments))
        case "restore":
            return ExampleChatWorkspaceShellCommandSummary(kind: "restore", target: shellLastPathArgument(arguments))
        case "mkdir", "touch":
            return ExampleChatWorkspaceShellCommandSummary(kind: "create", target: shellLastPathArgument(arguments))
        case "wc", "du", "stat", "basename", "dirname":
            return ExampleChatWorkspaceShellCommandSummary(kind: "inspect", target: shellLastPathArgument(arguments))
        default:
            return ExampleChatWorkspaceShellCommandSummary(kind: "unknown", target: shellLastPathArgument(arguments))
        }
    }

    private static func shellFirstCommandTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var previousWasBackslash = false

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll()
        }

        for character in command {
            if previousWasBackslash {
                current.append(character)
                previousWasBackslash = false
                continue
            }
            if character == "\\" {
                previousWasBackslash = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character == ";" || character == "|" || character == "\n" || character == "&" {
                appendCurrentToken()
                break
            }
            if String(character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendCurrentToken()
                continue
            }
            current.append(character)
        }
        appendCurrentToken()
        return tokens
    }

    private static func shellLastPathArgument(_ arguments: [String]) -> String? {
        let path = arguments.reversed().first { argument in
            guard !argument.isEmpty else { return false }
            if argument == "-" { return false }
            if argument.hasPrefix("-") { return false }
            return argument.hasPrefix("/") || argument.hasPrefix(".")
        } ?? arguments.reversed().first { argument in
            !argument.isEmpty && !argument.hasPrefix("-")
        }
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellSearchQuery(_ arguments: [String]) -> String? {
        let optionArgumentsRequiringValue: Set<String> = ["-e", "-g", "--glob", "--type", "-t", "-m", "--max-count"]
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if optionArgumentsRequiringValue.contains(argument) {
                skipNext = true
                continue
            }
            if argument.hasPrefix("-") {
                continue
            }
            return argument
        }
        return nil
    }
}
