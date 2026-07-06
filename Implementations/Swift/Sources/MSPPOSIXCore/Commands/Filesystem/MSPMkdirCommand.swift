import MSPCore

public struct MSPMkdirCommand: MSPCommand {
    public let name = "mkdir"
    public let summary: String? = "Create directories inside the workspace."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["p", "v"],
            allowedLongOptions: ["parents", "verbose"],
            shortOptionsRequiringValue: ["m"],
            longOptionsRequiringValue: ["mode"]
        )
        let parsed = try spec.parse(invocation.arguments)
        guard !parsed.operands.isEmpty else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "mkdir: missing operand\nTry 'mkdir --help' for more information.\n"
                )
            )
        }
        let createParents = parsed.options.contains { option in
            option.matches(short: "p") || option.matches(long: "parents")
        }
        let verbose = parsed.options.contains { option in
            option.matches(short: "v") || option.matches(long: "verbose")
        }
        let specifiedMode = try parsed.options.reversed().first { option in
            option.matches(short: "m") || option.matches(long: "mode")
        }.map { option in
            try mspPOSIXMkdirMode(option.value ?? "")
        }
        let creationMode = specifiedMode ?? context.directoryCreationMode
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)

        var diagnostics: [String] = []
        var stdout = ""
        for path in parsed.operands {
            do {
                if let existing = try? fileSystem.stat(path, from: context.currentDirectory) {
                    if createParents, existing.isDirectory {
                        continue
                    }
                    throw MSPWorkspaceFileSystemError.alreadyExists(existing.virtualPath)
                }
                try fileSystem.createDirectory(
                    path,
                    from: context.currentDirectory,
                    intermediates: createParents,
                    creationMode: creationMode
                )
                if verbose {
                    stdout += "mkdir: created directory \(mspPOSIXMkdirQuote(MSPPOSIXCommandSupport.displayPath(path)))\n"
                }
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(path)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("mkdir: cannot create directory \(mspPOSIXMkdirQuote(displayPath)): \(reason)")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }
}

private func mspPOSIXMkdirQuote(_ value: String) -> String {
    MSPPOSIXCommandSupport.gnuQuote(value)
}

private func mspPOSIXMkdirMode(_ rawMode: String) throws -> UInt16 {
    do {
        return try mspPOSIXChmodPermissions(rawMode, currentMode: 0o777, isDirectory: true)
    } catch {
        throw MSPCommandFailure(
            result: .failure(
                exitCode: 1,
                stderr: "mkdir: invalid mode \(MSPPOSIXCommandSupport.gnuQuote(rawMode))\n"
            )
        )
    }
}
