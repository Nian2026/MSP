import Foundation
import MSPCore

public struct MSPNoopCommand: MSPCommand {
    public var name: String { ":" }
    public var summary: String? { "Return success without output." }

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success()
    }
}

public struct MSPCdCommand: MSPCommand {
    public var name: String { "cd" }
    public var summary: String? { "Change the current workspace directory." }

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var operands = invocation.arguments
        if operands.first == "--" {
            operands.removeFirst()
        }
        guard operands.count <= 1 else {
            return .failure(stderr: "cd: too many arguments\n")
        }

        let target: String
        var printsTarget = false
        if let operand = operands.first {
            if operand == "-" {
                guard let previousDirectory = context.environment["OLDPWD"], !previousDirectory.isEmpty else {
                    return .failure(stderr: "cd: OLDPWD not set\n")
                }
                target = previousDirectory
                printsTarget = true
            } else {
                target = operand
            }
        } else {
            target = context.environment["HOME"] ?? "/"
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        do {
            let resolved = try fileSystem.resolve(target, from: context.currentDirectory)
            let canonicalPath = try MSPPOSIXCommandSupport.canonicalVirtualPath(
                target,
                command: name,
                mode: .existingOnly,
                fileSystem: fileSystem,
                currentDirectory: context.currentDirectory
            )
            let info = try fileSystem.stat(canonicalPath, from: "/")
            guard info.isDirectory else {
                return .failure(stderr: mspPOSIXBashShellDiagnosticStderr(
                    "cd: \(MSPPOSIXCommandSupport.displayPath(target)): Not a directory\n",
                    invocation: invocation
                ))
            }
            return .success(
                stdout: printsTarget ? resolved.virtualPath + "\n" : "",
                stateChange: MSPCommandRuntimeStateChange(currentDirectory: resolved.virtualPath)
            )
        } catch let failure as MSPCommandFailure {
            return .failure(stderr: mspPOSIXBashShellDiagnosticStderr(
                failure.result.stderr,
                invocation: invocation
            ))
        } catch {
            let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
            return .failure(stderr: mspPOSIXBashShellDiagnosticStderr(
                "cd: \(MSPPOSIXCommandSupport.displayPath(target)): \(reason)\n",
                invocation: invocation
            ))
        }
    }
}

public struct MSPWhichCommand: MSPCommand {
    public var name: String { "which" }
    public var summary: String? { "Locate registered command names on the shell path." }

    private let spec = MSPPOSIXCommandSpec(
        name: "which",
        allowedShortOptions: ["a"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed: MSPPOSIXParsedArguments
        do {
            parsed = try spec.parse(invocation.arguments)
        } catch let failure as MSPCommandFailure {
            throw mspPOSIXWhichOptionFailure(failure)
        }
        guard !parsed.operands.isEmpty else {
            return MSPCommandResult(exitCode: 1)
        }
        let showAll = parsed.options.contains { $0.matches(short: "a") }
        var rows: [String] = []
        var missing = false
        for operand in parsed.operands {
            let matches = mspPOSIXWhichRows(
                for: operand,
                showAll: showAll,
                context: context
            )
            if matches.isEmpty {
                missing = true
            } else {
                rows.append(contentsOf: matches)
            }
        }
        return MSPCommandResult(
            stdout: rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n",
            exitCode: missing ? 1 : 0
        )
    }
}

private func mspPOSIXWhichRows(
    for operand: String,
    showAll: Bool,
    context: MSPCommandContext
) -> [String] {
    if operand.contains("/") {
        return mspPOSIXWhichSlashOperand(operand, context: context) ? [operand] : []
    }

    let path = context.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    let entries = mspPOSIXWhichPathEntries(path)
    var rows: [String] = []
    for entry in entries {
        let directory = entry.isEmpty ? "." : entry
        let candidate = directory == "/" ? "/\(operand)" : "\(directory)/\(operand)"
        if mspPOSIXWhichCandidateExists(candidate, executable: operand, context: context) {
            rows.append(candidate)
            if !showAll {
                break
            }
        }
    }
    return rows
}

private func mspPOSIXWhichPathEntries(_ path: String) -> [String] {
    if path.isEmpty {
        return []
    }
    return path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
}

private func mspPOSIXWhichSlashOperand(_ operand: String, context: MSPCommandContext) -> Bool {
    if mspPOSIXWhichWorkspaceExecutable(operand, context: context) {
        return true
    }
    let visible = Set(context.availableCommandNames)
    guard let executable = operand.split(separator: "/").last.map(String.init),
          visible.contains(executable) else {
        return false
    }
    return mspPOSIXKnownPaths(for: executable, context: context).contains(operand)
}

private func mspPOSIXWhichCandidateExists(
    _ candidate: String,
    executable: String,
    context: MSPCommandContext
) -> Bool {
    if mspPOSIXWhichWorkspaceExecutable(candidate, context: context) {
        return true
    }
    return mspPOSIXKnownPaths(for: executable, context: context).contains(candidate)
}

private func mspPOSIXKnownPaths(for executable: String, context: MSPCommandContext) -> [String] {
    if let paths = context.commandLookupPaths[executable] {
        return paths
    }
    if let knownPaths = mspPOSIXKnownExternalCommandPaths[executable] {
        return knownPaths
    }
    if mspPOSIXShellKeywordNames.contains(executable) || mspPOSIXShellBuiltinNames.contains(executable) {
        return []
    }
    return context.availableCommandNames.contains(executable)
        ? ["/usr/bin/\(executable)", "/bin/\(executable)"]
        : []
}

private func mspPOSIXWhichWorkspaceExecutable(_ path: String, context: MSPCommandContext) -> Bool {
    guard let fileSystem = context.workspace?.fileSystem else {
        return false
    }
    do {
        let info = try fileSystem.stat(path, from: context.currentDirectory)
        guard info.type == .regularFile else {
            return false
        }
        return (info.permissions ?? 0) & 0o111 != 0
    } catch {
        return false
    }
}

public struct MSPTypeCommand: MSPCommand {
    public var name: String { "type" }
    public var summary: String? { "Describe how command names would be interpreted." }

    private let spec = MSPPOSIXCommandSpec(
        name: "type",
        allowedShortOptions: ["a", "f", "p", "P", "t"],
        allowedLongOptions: ["help"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed: MSPPOSIXParsedArguments
        do {
            parsed = try spec.parse(mspPOSIXNormalizeTypeArguments(invocation.arguments))
        } catch let failure as MSPCommandFailure {
            throw mspPOSIXTypeOptionFailure(failure)
        }
        if parsed.options.contains(where: { $0.matches(long: "help") }) {
            return .success(stdout: mspPOSIXTypeHelp)
        }
        guard !parsed.operands.isEmpty else {
            return .success()
        }
        let showAll = parsed.options.contains { $0.matches(short: "a") }
        let forcePathOnly = parsed.options.contains { $0.matches(short: "P") }
        let pathOnly = forcePathOnly || parsed.options.contains { $0.matches(short: "p") }
        let softPathOnly = pathOnly && !forcePathOnly
        let typeOnly = parsed.options.contains { $0.matches(short: "t") }
        let visible = Set(context.availableCommandNames)
        let lookupPaths = context.commandLookupPaths
        var stdoutRows: [String] = []
        var stderrRows: [String] = []
        var missing = false

        for operand in parsed.operands {
            let output: MSPPOSIXCommandLookupOutput
            if pathOnly {
                output = .path
            } else if typeOnly {
                output = .kind
            } else {
                output = .description
            }
            let matches = mspPOSIXLookupRows(
                for: operand,
                availableCommandNames: visible,
                commandLookupPaths: lookupPaths,
                environmentPath: context.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
                includeBuiltins: !pathOnly,
                showAll: showAll,
                output: output
            )
            if matches.isEmpty {
                if softPathOnly,
                   !mspPOSIXLookupRows(
                    for: operand,
                    availableCommandNames: visible,
                    commandLookupPaths: lookupPaths,
                    environmentPath: context.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
                    includeBuiltins: true,
                    showAll: false,
                    output: .kind
                   ).isEmpty {
                    continue
                }
                missing = true
                if !typeOnly && !pathOnly {
                    stderrRows.append("type: \(operand): not found")
                }
            } else {
                stdoutRows.append(contentsOf: matches)
            }
        }

        return MSPCommandResult(
            stdout: stdoutRows.isEmpty ? "" : stdoutRows.joined(separator: "\n") + "\n",
            stderr: stderrRows.isEmpty ? "" : stderrRows.joined(separator: "\n") + "\n",
            exitCode: missing ? 1 : 0
        )
    }
}

private func mspPOSIXNormalizeTypeArguments(_ arguments: [String]) -> [String] {
    var normalized = arguments
    for index in normalized.indices {
        guard normalized[index].hasPrefix("-") else {
            break
        }
        switch normalized[index] {
        case "-type", "--type":
            normalized[index] = "-t"
        case "-path", "--path":
            normalized[index] = "-p"
        case "-all", "--all":
            normalized[index] = "-a"
        default:
            continue
        }
    }
    return normalized
}

private let mspPOSIXTypeHelp = """
type: type [-afptP] name [name ...]
    Display information about command type.

    For each NAME, indicate how it would be interpreted if used as a
    command name.

    Options:
      -a\tdisplay all locations containing an executable named NAME
      -f\tsuppress shell function lookup
      -P\tforce a PATH search for each NAME
      -p\treturn the disk file name that would be executed
      -t\toutput a single word describing the command type

    Exit Status:
    Returns success if all of the NAMEs are found; fails if any are not found.
"""

enum MSPPOSIXCommandLookupOutput {
    case commandLookup
    case path
    case kind
    case description
}

private enum MSPPOSIXCommandLookupKind {
    case keyword
    case builtin
    case file
}

private struct MSPPOSIXCommandLookupEntry {
    var kind: MSPPOSIXCommandLookupKind
    var path: String?
}

func mspPOSIXLookupRows(
    for executable: String,
    availableCommandNames: Set<String>,
    commandLookupPaths: [String: [String]] = [:],
    environmentPath: String? = nil,
    includeBuiltins: Bool,
    showAll: Bool,
    output: MSPPOSIXCommandLookupOutput
) -> [String] {
    let lookupName: String
    let slashOperandPath: String?
    if executable.contains("/") {
        guard let basename = executable.split(separator: "/").last.map(String.init),
              availableCommandNames.contains(basename) else {
            return []
        }
        lookupName = basename
        slashOperandPath = executable
    } else {
        guard availableCommandNames.contains(executable) else {
            return []
        }
        lookupName = executable
        slashOperandPath = nil
    }

    let entries = mspPOSIXLookupEntries(
        for: lookupName,
        commandLookupPaths: commandLookupPaths,
        includeBuiltins: includeBuiltins
    )
    let filteredEntries = mspPOSIXPathFilteredLookupEntries(
        entries,
        executable: lookupName,
        slashOperandPath: slashOperandPath,
        environmentPath: environmentPath
    )
    guard !filteredEntries.isEmpty else {
        return []
    }

    let rows = filteredEntries.compactMap { entry -> String? in
        switch output {
        case .commandLookup:
            switch entry.kind {
            case .keyword, .builtin:
                return executable
            case .file:
                return entry.path
            }
        case .path:
            return entry.kind == .file ? entry.path : nil
        case .kind:
            switch entry.kind {
            case .keyword:
                return "keyword"
            case .builtin:
                return "builtin"
            case .file:
                return "file"
            }
        case .description:
            switch entry.kind {
            case .keyword:
                return "\(executable) is a shell keyword"
            case .builtin:
                return "\(executable) is a shell builtin"
            case .file:
                guard let path = entry.path else {
                    return nil
                }
                return "\(executable) is \(path)"
            }
        }
    }
    return showAll ? rows : Array(rows.prefix(1))
}

private func mspPOSIXPathFilteredLookupEntries(
    _ entries: [MSPPOSIXCommandLookupEntry],
    executable: String,
    slashOperandPath: String?,
    environmentPath: String?
) -> [MSPPOSIXCommandLookupEntry] {
    if let slashOperandPath {
        return entries.filter { entry in
            entry.kind == .file && entry.path == slashOperandPath
        }
    }
    guard let environmentPath else {
        return entries
    }

    let nonFileEntries = entries.filter { entry in
        entry.kind != .file
    }
    let fileEntriesByPath = Dictionary(grouping: entries.filter { entry in
        entry.kind == .file
    }) { entry in
        entry.path ?? ""
    }
    let orderedFileEntries = mspPOSIXWhichPathEntries(environmentPath).flatMap { entry -> [MSPPOSIXCommandLookupEntry] in
        let directory = entry.isEmpty ? "." : entry
        let candidate = directory == "/" ? "/\(executable)" : "\(directory)/\(executable)"
        return fileEntriesByPath[candidate] ?? []
    }
    return nonFileEntries + orderedFileEntries
}

private func mspPOSIXLookupEntries(
    for executable: String,
    commandLookupPaths: [String: [String]],
    includeBuiltins: Bool
) -> [MSPPOSIXCommandLookupEntry] {
    var entries: [MSPPOSIXCommandLookupEntry] = []
    let isKeyword = mspPOSIXShellKeywordNames.contains(executable)
    let isBuiltin = mspPOSIXShellBuiltinNames.contains(executable)
    if includeBuiltins, isKeyword {
        entries.append(MSPPOSIXCommandLookupEntry(kind: .keyword, path: nil))
    }
    if includeBuiltins, isBuiltin {
        entries.append(MSPPOSIXCommandLookupEntry(kind: .builtin, path: nil))
    }

    let externalPaths = commandLookupPaths[executable]
        ?? mspPOSIXKnownExternalCommandPaths[executable]
        ?? (isKeyword || isBuiltin ? [] : ["/usr/bin/\(executable)", "/bin/\(executable)"])
    for path in externalPaths {
        entries.append(MSPPOSIXCommandLookupEntry(kind: .file, path: path))
    }
    return entries
}

let mspPOSIXShellKeywordNames: Set<String> = [
    "[["
]

let mspPOSIXShellBuiltinNames: Set<String> = [
    ".",
    ":",
    "[",
    "alias",
    "builtin",
    "cd",
    "command",
    "break",
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
    "trap",
    "test",
    "true",
    "type",
    "typeset",
    "umask",
    "unalias",
    "unset"
]

private let mspPOSIXKnownExternalCommandPaths: [String: [String]] = [
    "[": ["/usr/bin/[", "/bin/["],
    "basename": ["/usr/bin/basename", "/bin/basename"],
    "dirname": ["/usr/bin/dirname", "/bin/dirname"],
    "echo": ["/usr/bin/echo", "/bin/echo"],
    "env": ["/usr/bin/env", "/bin/env"],
    "false": ["/usr/bin/false", "/bin/false"],
    "printf": ["/usr/bin/printf", "/bin/printf"],
    "pwd": ["/usr/bin/pwd", "/bin/pwd"],
    "readlink": ["/usr/bin/readlink", "/bin/readlink"],
    "realpath": ["/usr/bin/realpath", "/bin/realpath"],
    "sh": ["/usr/bin/sh", "/bin/sh"],
    "test": ["/usr/bin/test", "/bin/test"],
    "true": ["/usr/bin/true", "/bin/true"],
    "which": ["/usr/bin/which", "/bin/which"]
]

func mspPOSIXBashShellDiagnosticStderr(
    _ stderr: String,
    invocation: MSPCommandInvocation
) -> String {
    guard !invocation.rawInput.isEmpty,
          !stderr.hasPrefix("/bin/bash: line "),
          let newline = stderr.firstIndex(of: "\n") else {
        return stderr
    }
    let firstLine = String(stderr[..<newline])
    let remainder = String(stderr[stderr.index(after: newline)...])
    return "/bin/bash: line 1: " + firstLine + "\n" + remainder
}

private func mspPOSIXTypeOptionFailure(_ failure: MSPCommandFailure) -> MSPCommandFailure {
    guard let option = mspPOSIXUnsupportedOption(from: failure.result.stderr, command: "type") else {
        return failure
    }
    return MSPCommandFailure(
        result: .failure(
            exitCode: 2,
            stderr: "type: \(option.count == 1 ? "-\(option)" : "--"): invalid option\ntype: usage: type [-afptP] name [name ...]\n"
        )
    )
}

private func mspPOSIXWhichOptionFailure(_ failure: MSPCommandFailure) -> MSPCommandFailure {
    guard let option = mspPOSIXUnsupportedOption(from: failure.result.stderr, command: "which") else {
        return failure
    }
    return MSPCommandFailure(
        result: .failure(
            exitCode: 2,
            stdout: "Usage: /usr/bin/which [-a] args\n",
            stderr: "Illegal option \(option.count == 1 ? "-\(option)" : "--")\n"
        )
    )
}

private func mspPOSIXUnsupportedOption(from stderr: String, command: String) -> String? {
    let prefix = "\(command): unsupported option -- "
    guard stderr.hasPrefix(prefix) else {
        return nil
    }
    return String(stderr.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
}
