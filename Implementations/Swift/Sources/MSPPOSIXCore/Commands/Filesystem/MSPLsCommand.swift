import Foundation
import MSPCore

public struct MSPLsCommand: MSPStreamingCommand {
    public let name = "ls"
    public let summary: String? = "List workspace directory contents."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try mspLsCommandSpec.parse(invocation.arguments)
        let options = try mspLsListingOptions(from: parsed.options)
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let paths = parsed.operands.isEmpty ? ["."] : parsed.operands

        var groups: [MSPLsListingGroup] = []
        var diagnostics: [String] = []
        for path in paths {
            do {
                let resolved = try fileSystem.resolve(path, from: context.currentDirectory)
                let info = try fileSystem.stat(resolved.virtualPath, from: "/")
                groups.append(MSPLsListingGroup(rawPath: path, info: info))
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(path)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("ls: cannot access '\(displayPath)': \(reason)")
            }
        }

        let sections = try mspLsSections(
            groups: groups,
            fileSystem: fileSystem,
            options: options
        )
        let stdout = sections
        guard diagnostics.isEmpty else {
            return .failure(
                exitCode: 2,
                stdout: stdout.isEmpty ? "" : stdout + options.lineTerminator,
                stderr: diagnostics.joined(separator: "\n") + "\n"
            )
        }
        return MSPCommandResult(stdout: stdout.isEmpty ? "" : stdout + options.lineTerminator)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try mspLsCommandSpec.parse(invocation.arguments)
        let options = try mspLsListingOptions(from: parsed.options)
        guard let standardOutput = context.standardOutputStream,
              mspLsStreamingDirectoryListingIsSafe(options: options, operands: parsed.operands)
        else {
            return try await run(invocation: invocation, context: context)
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let path = parsed.operands.first ?? "."
        do {
            let resolved = try fileSystem.resolve(path, from: context.currentDirectory)
            let info = try fileSystem.stat(resolved.virtualPath, from: "/")
            guard info.type == .directory else {
                return try await run(invocation: invocation, context: context)
            }
            if options.recursive {
                var isFirstSection = true
                try await mspLsStreamRecursiveListedEntries(
                    for: info,
                    displayPath: path.isEmpty ? "." : path,
                    fileSystem: fileSystem,
                    options: options,
                    standardOutput: standardOutput,
                    isFirstSection: &isFirstSection
                )
            } else {
                try await mspLsStreamListedEntries(
                    for: info,
                    fileSystem: fileSystem,
                    options: options,
                    standardOutput: standardOutput
                )
            }
            return .success()
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        } catch {
            let displayPath = MSPPOSIXCommandSupport.displayPath(path)
            let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
            return .failure(exitCode: 2, stderr: "ls: cannot access '\(displayPath)': \(reason)\n")
        }
    }
}
