import MSPCore

public struct MSPRmCommand: MSPCommand {
    public let name = "rm"
    public let summary: String? = "Remove workspace files or directories."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["r", "R", "f", "d", "v"],
            allowedLongOptions: ["recursive", "force", "dir", "verbose"]
        )
        let parsed = try spec.parse(invocation.arguments)
        let recursive = parsed.options.contains { option in
            option.matches(short: "r") || option.matches(short: "R") || option.matches(long: "recursive")
        }
        let force = parsed.options.contains { option in
            option.matches(short: "f") || option.matches(long: "force")
        }
        let removeEmptyDirectories = parsed.options.contains { option in
            option.matches(short: "d") || option.matches(long: "dir")
        }
        let verbose = parsed.options.contains { option in
            option.matches(short: "v") || option.matches(long: "verbose")
        }
        if parsed.operands.isEmpty {
            return force
                ? .success()
                : .failure(
                    exitCode: 1,
                    stderr: "rm: missing operand\nTry 'rm --help' for more information.\n"
                )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var diagnostics: [String] = []
        var stdout = ""
        for path in parsed.operands {
            do {
                let info = try fileSystem.stat(path, from: context.currentDirectory)
                let shouldRemoveDirectory = info.type == .directory && (recursive || removeEmptyDirectories)
                if info.type == .directory, removeEmptyDirectories, !recursive {
                    let entries = try fileSystem.listDirectory(info.virtualPath, from: "/")
                    guard entries.isEmpty else {
                        diagnostics.append("rm: cannot remove '\(MSPPOSIXCommandSupport.displayPath(path))': Directory not empty")
                        continue
                    }
                }
                try fileSystem.remove(path, from: context.currentDirectory, recursive: shouldRemoveDirectory)
                if verbose {
                    stdout += "removed '\(MSPPOSIXCommandSupport.displayPath(path))'\n"
                }
            } catch MSPWorkspaceFileSystemError.notFound where force {
                continue
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(path)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("rm: cannot remove '\(displayPath)': \(reason)")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }
}
