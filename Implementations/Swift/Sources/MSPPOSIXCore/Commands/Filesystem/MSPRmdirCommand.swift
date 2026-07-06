import MSPCore

public struct MSPRmdirCommand: MSPCommand {
    public let name = "rmdir"
    public let summary: String? = "Remove empty workspace directories."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = parse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard !parsed.operands.isEmpty else {
            return mspCore100MissingOperand(name)
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var diagnostics: [String] = []
        var stdout = ""

        for operand in parsed.operands {
            let ok = removeDirectory(
                operand,
                context: context,
                fileSystem: fileSystem,
                options: parsed.options,
                diagnostics: &diagnostics,
                stdout: &stdout
            )
            if ok, parsed.options.parents {
                removeParents(
                    of: operand,
                    context: context,
                    fileSystem: fileSystem,
                    options: parsed.options,
                    diagnostics: &diagnostics,
                    stdout: &stdout
                )
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }

    private func removeDirectory(
        _ operand: String,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem,
        options: RmdirOptions,
        diagnostics: inout [String],
        stdout: inout String
    ) -> Bool {
        if options.verbose {
            stdout += "rmdir: removing directory, '\(mspCore100DisplayPath(operand))'\n"
        }
        do {
            let info = try fileSystem.stat(operand, from: context.currentDirectory)
            guard info.type == .directory else {
                mspCore100AppendDiagnostic(
                    &diagnostics,
                    "rmdir: failed to remove '\(mspCore100DisplayPath(operand))': Not a directory"
                )
                return false
            }
            let entries = try fileSystem.listDirectory(info.virtualPath, from: "/")
            guard entries.isEmpty else {
                if options.ignoreFailOnNonEmpty {
                    return true
                }
                mspCore100AppendDiagnostic(
                    &diagnostics,
                    "rmdir: failed to remove '\(mspCore100DisplayPath(operand))': Directory not empty"
                )
                return false
            }
            try fileSystem.remove(info.virtualPath, from: "/", recursive: true)
            return true
        } catch {
            let reason = mspCore100Reason(error)
            mspCore100AppendDiagnostic(
                &diagnostics,
                "rmdir: failed to remove '\(mspCore100DisplayPath(operand))': \(reason)"
            )
            return false
        }
    }

    private func removeParents(
        of operand: String,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem,
        options: RmdirOptions,
        diagnostics: inout [String],
        stdout: inout String
    ) {
        var currentDisplay = mspCore100ParentDisplayPath(of: operand)
        while let display = currentDisplay {
            if options.verbose {
                stdout += "rmdir: removing directory, '\(mspCore100DisplayPath(display))'\n"
            }
            do {
                let info = try fileSystem.stat(display, from: context.currentDirectory)
                guard info.type == .directory else {
                    mspCore100AppendDiagnostic(
                        &diagnostics,
                        "rmdir: failed to remove directory '\(mspCore100DisplayPath(display))': Not a directory"
                    )
                    return
                }
                let entries = try fileSystem.listDirectory(info.virtualPath, from: "/")
                guard entries.isEmpty else {
                    if options.ignoreFailOnNonEmpty {
                        return
                    }
                    mspCore100AppendDiagnostic(
                        &diagnostics,
                        "rmdir: failed to remove directory '\(mspCore100DisplayPath(display))': Directory not empty"
                    )
                    return
                }
                try fileSystem.remove(info.virtualPath, from: "/", recursive: true)
            } catch {
                let reason = mspCore100Reason(error)
                mspCore100AppendDiagnostic(
                    &diagnostics,
                    "rmdir: failed to remove directory '\(mspCore100DisplayPath(display))': \(reason)"
                )
                return
            }
            currentDisplay = mspCore100ParentDisplayPath(of: display)
        }
    }

    private func parse(_ arguments: [String]) -> RmdirParseResult {
        var options = RmdirOptions()
        var operands: [String] = []
        var parsingOptions = true

        for argument in arguments {
            if !parsingOptions {
                operands.append(argument)
                continue
            }
            if argument == "--" {
                parsingOptions = false
                continue
            }
            if argument == "--parents" || argument == "--path" {
                options.parents = true
                continue
            }
            if argument == "--verbose" {
                options.verbose = true
                continue
            }
            if argument == "--ignore-fail-on-non-empty" {
                options.ignoreFailOnNonEmpty = true
                continue
            }
            if argument.hasPrefix("--"), argument.count > 2 {
                let option = argument.dropFirst(2).first ?? "?"
                return RmdirParseResult(options: options, operands: operands, result: mspCore100InvalidOption(name, option: option))
            }
            if argument.hasPrefix("-"), argument != "-" {
                for option in argument.dropFirst() {
                    switch option {
                    case "p":
                        options.parents = true
                    case "v":
                        options.verbose = true
                    default:
                        return RmdirParseResult(options: options, operands: operands, result: mspCore100InvalidOption(name, option: option))
                    }
                }
                continue
            }
            operands.append(argument)
        }

        return RmdirParseResult(options: options, operands: operands, result: nil)
    }
}

private struct RmdirOptions {
    var parents = false
    var verbose = false
    var ignoreFailOnNonEmpty = false
}

private struct RmdirParseResult {
    var options: RmdirOptions
    var operands: [String]
    var result: MSPCommandResult?
}
