import MSPCore

public struct MSPMvCommand: MSPCommand {
    public let name = "mv"
    public let summary: String? = "Move or rename workspace files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["f", "n", "T", "v"],
            allowedLongOptions: ["force", "no-clobber", "no-target-directory", "strip-trailing-slashes", "verbose"],
            shortOptionsRequiringValue: ["t"],
            longOptionsRequiringValue: ["target-directory"]
        )
        let parsed = try spec.parse(invocation.arguments)
        let stripTrailingSlashes = parsed.options.contains { option in
            option.matches(long: "strip-trailing-slashes")
        }
        let targetDirectories = parsed.options.compactMap { option -> String? in
            option.matches(short: "t") || option.matches(long: "target-directory") ? option.value : nil
        }
        guard targetDirectories.count <= 1 else {
            return .failure(stderr: "mv: multiple target directories specified\n")
        }
        let targetDirectoryOperand = targetDirectories.first
        let noTargetDirectory = parsed.options.contains { option in
            option.matches(short: "T") || option.matches(long: "no-target-directory")
        }
        guard !(targetDirectoryOperand != nil && noTargetDirectory) else {
            return .failure(stderr: "mv: cannot combine --target-directory (-t) and --no-target-directory (-T)\n")
        }
        let verbose = parsed.options.contains { option in
            option.matches(short: "v") || option.matches(long: "verbose")
        }
        guard !parsed.operands.isEmpty else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "mv: missing file operand\nTry 'mv --help' for more information.\n"
                )
            )
        }
        guard targetDirectoryOperand != nil || parsed.operands.count >= 2 else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "mv: missing destination file operand after '\(parsed.operands[0])'\nTry 'mv --help' for more information.\n"
                )
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var overwriteExisting = true
        for option in parsed.options {
            if option.matches(short: "n") || option.matches(long: "no-clobber") {
                overwriteExisting = false
            } else if option.matches(short: "f") || option.matches(long: "force") {
                overwriteExisting = true
            }
        }
        let sources: [String]
        let destinationOperand: String
        if let targetDirectoryOperand {
            sources = parsed.operands.map { stripTrailingSlashes ? strippedTrailingSlashes($0) : $0 }
            destinationOperand = targetDirectoryOperand
        } else {
            sources = Array(parsed.operands.dropLast()).map { stripTrailingSlashes ? strippedTrailingSlashes($0) : $0 }
            destinationOperand = parsed.operands[parsed.operands.count - 1]
        }
        let destinationDirectory = noTargetDirectory
            ? nil
            : try existingDirectoryInfo(
                destinationOperand,
                fileSystem: fileSystem,
                context: context
            )

        if targetDirectoryOperand != nil, destinationDirectory == nil {
            let reason = missingOrNotDirectoryReason(
                destinationOperand,
                fileSystem: fileSystem,
                context: context
            )
            return .failure(stderr: "mv: target directory '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))': \(reason)\n")
        }

        if sources.count > 1, destinationDirectory == nil {
            let reason = missingOrNotDirectoryReason(
                destinationOperand,
                fileSystem: fileSystem,
                context: context
            )
            return .failure(stderr: "mv: target '\(destinationOperand)': \(reason)\n")
        }

        var diagnostics: [String] = []
        var stdout = ""
        for source in sources {
            do {
                let sourceResolved = try fileSystem.resolve(source, from: context.currentDirectory)
                let sourceInfo: MSPFileInfo
                do {
                    sourceInfo = try fileSystem.stat(sourceResolved.virtualPath, from: "/")
                } catch {
                    let displayPath = MSPPOSIXCommandSupport.displayPath(source)
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    diagnostics.append("mv: cannot stat '\(displayPath)': \(reason)")
                    continue
                }
                let finalDestination: String
                if let destinationDirectory {
                    finalDestination = MSPPOSIXCommandSupport.joinPath(
                        destinationDirectory.virtualPath,
                        child: MSPPOSIXCommandSupport.basename(sourceResolved.virtualPath)
                    )
                } else {
                    finalDestination = destinationOperand
                }
                let destinationResolved = try fileSystem.resolve(finalDestination, from: context.currentDirectory)
                if !overwriteExisting, (try? fileSystem.stat(destinationResolved.virtualPath, from: "/")) != nil {
                    continue
                }
                if sourceInfo.isDirectory, destinationDirectory == nil,
                   let destinationInfo = try? fileSystem.stat(destinationOperand, from: context.currentDirectory),
                   !destinationInfo.isDirectory {
                    diagnostics.append(
                        "mv: cannot overwrite non-directory '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))' with directory '\(MSPPOSIXCommandSupport.displayPath(source))'"
                    )
                    continue
                }
                if noTargetDirectory,
                   !sourceInfo.isDirectory,
                   let destinationInfo = try? fileSystem.stat(destinationOperand, from: context.currentDirectory),
                   destinationInfo.isDirectory {
                    diagnostics.append(
                        "mv: cannot overwrite directory '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))' with non-directory"
                    )
                    continue
                }
                if sourceResolved.virtualPath == destinationResolved.virtualPath {
                    diagnostics.append(
                        "mv: '\(MSPPOSIXCommandSupport.displayPath(source))' and '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))' are the same file"
                    )
                    continue
                }
                var options: MSPFileMoveOptions = []
                if overwriteExisting {
                    options.insert(.overwriteExisting)
                }
                try fileSystem.move(
                    source,
                    to: finalDestination,
                    from: context.currentDirectory,
                    options: options
                )
                if verbose {
                    stdout += "renamed '\(MSPPOSIXCommandSupport.displayPath(source))' -> '\(MSPPOSIXCommandSupport.displayPath(finalDestination))'\n"
                }
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(source)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("mv: cannot move '\(displayPath)': \(reason)")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }

    private func existingDirectoryInfo(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        context: MSPCommandContext
    ) throws -> MSPFileInfo? {
        do {
            let info = try fileSystem.stat(path, from: context.currentDirectory)
            if info.type == .directory {
                return info
            }
            guard info.type == .symbolicLink else {
                return nil
            }
            let canonicalPath = try MSPPOSIXCommandSupport.canonicalVirtualPath(
                path,
                command: name,
                mode: .existingOnly,
                fileSystem: fileSystem,
                currentDirectory: context.currentDirectory
            )
            let canonicalInfo = try fileSystem.stat(canonicalPath, from: "/")
            return canonicalInfo.type == .directory ? canonicalInfo : nil
        } catch MSPWorkspaceFileSystemError.notFound {
            return nil
        }
    }

    private func missingOrNotDirectoryReason(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        context: MSPCommandContext
    ) -> String {
        do {
            _ = try fileSystem.stat(path, from: context.currentDirectory)
            return "Not a directory"
        } catch {
            return MSPPOSIXCommandSupport.diagnosticReason(from: error)
        }
    }

    private func strippedTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
