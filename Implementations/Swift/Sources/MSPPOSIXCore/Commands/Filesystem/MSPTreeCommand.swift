import Foundation
import MSPCore

public struct MSPTreeCommand: MSPStreamingCommand {
    public let name = "tree"
    public let summary: String? = "Print a workspace directory tree."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let output = MSPCommandOutputBuffer()
        var streamingContext = context
        streamingContext.standardOutputStream = output
        let result = try await runStreaming(invocation: invocation, context: streamingContext)
        guard result.stdoutData.isEmpty else {
            return result
        }
        return MSPCommandResult(
            stdoutData: await output.data(),
            stderrData: result.stderrData,
            exitCode: result.exitCode,
            stateChange: result.stateChange
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = parse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let stream = parsed.options.outputPath == nil ? context.standardOutputStream : nil
        var fallbackOutput = Data()

        func emit(_ text: String) async throws {
            let data = Data(text.utf8)
            if let stream {
                try await stream.write(data)
            } else {
                fallbackOutput.append(data)
            }
        }

        var totals = TreeTotals()
        do {
            let rootOperands = parsed.operands.isEmpty ? ["."] : parsed.operands
            for rootOperand in rootOperands {
                let rootInfo = try fileSystem.stat(rootOperand, from: context.currentDirectory)
                try await emit(rootDisplayName(rootOperand))
                try await emit("\n")
                if rootInfo.type == .directory {
                    totals.rootDirectories += 1
                    try await renderDirectory(
                        rootInfo,
                        rootDisplayPrefix: rootDisplayName(rootOperand),
                        depth: 0,
                        prefix: "",
                        options: parsed.options,
                        fileSystem: fileSystem,
                        emit: emit,
                        totals: &totals
                    )
                } else {
                    totals.files += 1
                }
            }
            if !parsed.options.noReport {
                let directoryCount = totals.hasVisibleEntries ? totals.directories + totals.rootDirectories : 0
                try await emit("\n")
                if parsed.options.directoriesOnly {
                    try await emit("\(directoryCount) \(directoryCount == 1 ? "directory" : "directories")\n")
                } else {
                    try await emit(
                        "\(directoryCount) \(directoryCount == 1 ? "directory" : "directories"), \(totals.files) \(totals.files == 1 ? "file" : "files")\n"
                    )
                }
            }
            if let outputPath = parsed.options.outputPath {
                try fileSystem.writeFile(
                    outputPath,
                    data: fallbackOutput,
                    from: context.currentDirectory,
                    options: [.overwriteExisting]
                )
                fallbackOutput.removeAll(keepingCapacity: true)
            }
        } catch {
            return .failure(
                stdoutData: fallbackOutput,
                stderr: "tree: \(mspCore100Reason(error))\n"
            )
        }

        if stream == nil {
            return .success(stdoutData: fallbackOutput)
        }
        return .success()
    }

    private func renderDirectory(
        _ directory: MSPFileInfo,
        rootDisplayPrefix: String,
        depth: Int,
        prefix: String,
        options: TreeOptions,
        fileSystem: any MSPWorkspaceFileSystem,
        emit: (String) async throws -> Void,
        totals: inout TreeTotals
    ) async throws {
        if let maxDepth = options.maxDepth, depth >= maxDepth {
            return
        }

        var entries: [MSPDirectoryEntry] = []
        try await fileSystem.enumerateDirectory(directory.virtualPath, from: "/") { entry in
            entries.append(entry)
            return true
        }
        let parentPath = directory.virtualPath
        let visibleEntries = entries
            .filter { include($0, parentPath: parentPath, options: options, fileSystem: fileSystem) }
            .sorted { $0.name < $1.name }

        for (index, entry) in visibleEntries.enumerated() {
            totals.hasVisibleEntries = true
            let isLast = index == visibleEntries.count - 1
            let symlinkTarget = entry.info.type == .symbolicLink ? entry.info.symbolicLinkTarget : nil
            let directoryLike = entry.info.type == .directory
                || mspCore100IsSymlinkToDirectory(entry.info, parentVirtualPath: parentPath, fileSystem: fileSystem)
            if directoryLike {
                totals.directories += 1
            } else {
                totals.files += 1
            }

            let displayName = displayName(
                for: entry,
                rootDisplayPrefix: rootDisplayPrefix,
                fullPath: options.fullPath
            )
            if options.noIndent {
                try await emit(displayName)
            } else {
                try await emit(prefix)
                try await emit(options.charset.branch(isLast: isLast))
                try await emit(displayName)
            }
            if let symlinkTarget {
                try await emit(" -> \(symlinkTarget)")
            }
            try await emit("\n")

            if entry.info.type == .directory {
                let childPrefix = options.noIndent
                    ? ""
                    : prefix + options.charset.childPrefix(parentIsLast: isLast)
                try await renderDirectory(
                    entry.info,
                    rootDisplayPrefix: rootDisplayPrefix,
                    depth: depth + 1,
                    prefix: childPrefix,
                    options: options,
                    fileSystem: fileSystem,
                    emit: emit,
                    totals: &totals
                )
            }
        }
    }

    private func include(
        _ entry: MSPDirectoryEntry,
        parentPath: String,
        options: TreeOptions,
        fileSystem: any MSPWorkspaceFileSystem
    ) -> Bool {
        if !options.includeAll, entry.name.hasPrefix(".") {
            return false
        }
        if options.ignorePatterns.contains(where: { mspCore100GlobMatch(entry.name, pattern: $0) }) {
            return false
        }
        let directoryLike = entry.info.type == .directory
            || mspCore100IsSymlinkToDirectory(entry.info, parentVirtualPath: parentPath, fileSystem: fileSystem)
        if options.directoriesOnly, !directoryLike {
            return false
        }
        if !directoryLike,
           !options.includePatterns.isEmpty,
           !options.includePatterns.contains(where: { mspCore100GlobMatch(entry.name, pattern: $0) }) {
            return false
        }
        return true
    }

    private func displayName(
        for entry: MSPDirectoryEntry,
        rootDisplayPrefix: String,
        fullPath: Bool
    ) -> String {
        guard fullPath else {
            return entry.name
        }
        if entry.info.virtualPath == "/" {
            return rootDisplayPrefix
        }
        return "." + entry.info.virtualPath
    }

    private func rootDisplayName(_ operand: String) -> String {
        operand.isEmpty ? "." : operand
    }

    private func parse(_ arguments: [String]) -> TreeParseResult {
        var options = TreeOptions()
        var operands: [String] = []
        var parsingOptions = true
        var index = 0

        func requireValue(option: String) -> String? {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                return nil
            }
            index = nextIndex
            return arguments[nextIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if !parsingOptions {
                operands.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                parsingOptions = false
                index += 1
                continue
            }
            if argument.hasPrefix("--"), argument.count > 2 {
                let body = String(argument.dropFirst(2))
                let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let option = String(parts[0])
                let inlineValue = parts.count == 2 ? String(parts[1]) : nil
                switch option {
                case "charset":
                    guard let value = inlineValue ?? requireValue(option: "charset") else {
                        return TreeParseResult(options: options, operands: operands, result: invalidOption("?"))
                    }
                    options.charset = value.lowercased() == "ascii" ? .ascii : .unicode
                case "noreport":
                    options.noReport = true
                default:
                    return TreeParseResult(options: options, operands: operands, result: invalidOption(option.first ?? "?"))
                }
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                let characters = Array(argument.dropFirst())
                var characterIndex = 0
                while characterIndex < characters.count {
                    let option = characters[characterIndex]
                    switch option {
                    case "a":
                        options.includeAll = true
                    case "d":
                        options.directoriesOnly = true
                    case "f":
                        options.fullPath = true
                    case "i":
                        options.noIndent = true
                    case "L", "P", "I", "o":
                        let tail = String(characters.dropFirst(characterIndex + 1))
                        guard let value = tail.isEmpty ? requireValue(option: String(option)) : tail else {
                            return TreeParseResult(options: options, operands: operands, result: invalidOption(option))
                        }
                        switch option {
                        case "L":
                            options.maxDepth = max(0, Int(value) ?? 0)
                        case "P":
                            options.includePatterns.append(value)
                        case "I":
                            options.ignorePatterns.append(value)
                        case "o":
                            options.outputPath = value
                        default:
                            break
                        }
                        characterIndex = characters.count
                        continue
                    default:
                        return TreeParseResult(options: options, operands: operands, result: invalidOption(option))
                    }
                    characterIndex += 1
                }
                index += 1
                continue
            }
            operands.append(argument)
            index += 1
        }

        return TreeParseResult(options: options, operands: operands, result: nil)
    }

    private func invalidOption(_ option: Character) -> MSPCommandResult {
        .failure(exitCode: 1, stderr: """
        tree: Invalid argument -`\(option)'.
        usage: tree [-acdfghilnpqrstuvxACDFJQNSUX] [-L level [-R]] [-H  baseHREF]
        \t[-T title] [-o filename] [-P pattern] [-I pattern] [--gitignore]
        \t[--gitfile[=]file] [--matchdirs] [--metafirst] [--ignore-case]
        \t[--nolinks] [--hintro[=]file] [--houtro[=]file] [--inodes] [--device]
        \t[--sort[=]<name>] [--dirsfirst] [--filesfirst] [--filelimit #] [--si]
        \t[--du] [--prune] [--charset[=]X] [--timefmt[=]format] [--fromfile]
        \t[--fflinks] [--info] [--infofile[=]file] [--noreport] [--version]
        \t[--help] [--] [directory ...]
        """ + "\n")
    }
}

private struct TreeParseResult {
    var options: TreeOptions
    var operands: [String]
    var result: MSPCommandResult?
}

private struct TreeOptions {
    var includeAll = false
    var directoriesOnly = false
    var fullPath = false
    var noIndent = false
    var maxDepth: Int?
    var includePatterns: [String] = []
    var ignorePatterns: [String] = []
    var charset = TreeCharset.unicode
    var noReport = false
    var outputPath: String?
}

private enum TreeCharset {
    case unicode
    case ascii

    func branch(isLast: Bool) -> String {
        switch self {
        case .unicode:
            return isLast ? "└── " : "├── "
        case .ascii:
            return isLast ? "`-- " : "|-- "
        }
    }

    func childPrefix(parentIsLast: Bool) -> String {
        switch self {
        case .unicode:
            return parentIsLast ? "    " : "│\u{00a0}\u{00a0} "
        case .ascii:
            return parentIsLast ? "    " : "|   "
        }
    }
}

private struct TreeTotals {
    var rootDirectories = 0
    var directories = 0
    var files = 0
    var hasVisibleEntries = false
}
