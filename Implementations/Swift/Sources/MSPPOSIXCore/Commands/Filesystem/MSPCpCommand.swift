import MSPCore

public struct MSPCpCommand: MSPCommand {
    public let name = "cp"
    public let summary: String? = "Copy workspace files or directories."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["r", "R", "f", "n", "T", "v"],
            allowedLongOptions: [
                "recursive",
                "force",
                "no-clobber",
                "no-target-directory",
                "parents",
                "strip-trailing-slashes",
                "verbose"
            ],
            shortOptionsRequiringValue: ["t"],
            longOptionsRequiringValue: ["target-directory"]
        )
        let parsed = try spec.parse(invocation.arguments)
        let preserveParents = parsed.options.contains { option in
            option.matches(long: "parents")
        }
        let stripTrailingSlashes = parsed.options.contains { option in
            option.matches(long: "strip-trailing-slashes")
        }
        let targetDirectories = parsed.options.compactMap { option -> String? in
            option.matches(short: "t") || option.matches(long: "target-directory") ? option.value : nil
        }
        guard targetDirectories.count <= 1 else {
            return .failure(stderr: "cp: multiple target directories specified\n")
        }
        let targetDirectoryOperand = targetDirectories.first
        let noTargetDirectory = parsed.options.contains { option in
            option.matches(short: "T") || option.matches(long: "no-target-directory")
        }
        guard !(targetDirectoryOperand != nil && noTargetDirectory) else {
            return .failure(stderr: "cp: cannot combine --target-directory (-t) and --no-target-directory (-T)\n")
        }
        let verbose = parsed.options.contains { option in
            option.matches(short: "v") || option.matches(long: "verbose")
        }

        guard !parsed.operands.isEmpty else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "cp: missing file operand\nTry 'cp --help' for more information.\n"
                )
            )
        }
        guard targetDirectoryOperand != nil || parsed.operands.count >= 2 else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "cp: missing destination file operand after '\(parsed.operands[0])'\nTry 'cp --help' for more information.\n"
                )
            )
        }

        let recursive = parsed.options.contains { option in
            option.matches(short: "r") || option.matches(short: "R") || option.matches(long: "recursive")
        }
        var overwriteExisting = true
        for option in parsed.options {
            if option.matches(short: "n") || option.matches(long: "no-clobber") {
                overwriteExisting = false
            } else if option.matches(short: "f") || option.matches(long: "force") {
                overwriteExisting = true
            }
        }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
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
            return .failure(stderr: "cp: target directory '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))': \(reason)\n")
        }

        if requiresDirectoryDestination(destinationOperand), destinationDirectory == nil {
            let reason = missingOrNotDirectoryReason(
                destinationOperand,
                fileSystem: fileSystem,
                context: context
            )
            return .failure(stderr: "cp: cannot stat '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))': \(reason)\n")
        }

        if sources.count > 1, destinationDirectory == nil {
            let reason = missingOrNotDirectoryReason(
                destinationOperand,
                fileSystem: fileSystem,
                context: context
            )
            return .failure(stderr: "cp: target '\(destinationOperand)': \(reason)\n")
        }

        var diagnostics: [String] = []
        var stdout = ""
        var preparedCopies: [PreparedCopy] = []
        var copyOptions: MSPFileCopyOptions = []
        if overwriteExisting {
            copyOptions.insert(.overwriteExisting)
        }
        if recursive {
            copyOptions.insert(.recursive)
        }
        let batchFileSystem = fileSystem as? any MSPWorkspaceBatchCopying
        let shouldPrepareBatch = overwriteExisting && sources.count > 1 && batchFileSystem != nil
        for source in sources {
            do {
                let sourceResolved = try fileSystem.resolve(source, from: context.currentDirectory)
                let sourceInfo: MSPFileInfo
                do {
                    sourceInfo = try fileSystem.stat(sourceResolved.virtualPath, from: "/")
                } catch {
                    let displayPath = MSPPOSIXCommandSupport.displayPath(source)
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    diagnostics.append("cp: cannot stat '\(displayPath)': \(reason)")
                    continue
                }
                if sourceInfo.isDirectory, !recursive {
                    diagnostics.append("cp: -r not specified; omitting directory '\(MSPPOSIXCommandSupport.displayPath(source))'")
                    continue
                }
                if sourceInfo.isDirectory, destinationDirectory == nil,
                   let destinationInfo = try? fileSystem.stat(destinationOperand, from: context.currentDirectory),
                   !destinationInfo.isDirectory {
                    diagnostics.append(
                        "cp: cannot overwrite non-directory '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))' with directory '\(MSPPOSIXCommandSupport.displayPath(source))'"
                    )
                    continue
                }
                if noTargetDirectory,
                   !sourceInfo.isDirectory,
                   let destinationInfo = try? fileSystem.stat(destinationOperand, from: context.currentDirectory),
                   destinationInfo.isDirectory {
                    diagnostics.append(
                        "cp: cannot overwrite directory '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))' with non-directory"
                    )
                    continue
                }
                let finalDestination: String
                if let destinationDirectory {
                    let relativeName = preserveParents
                        ? parentPreservingName(for: sourceResolved.virtualPath)
                        : MSPPOSIXCommandSupport.basename(sourceResolved.virtualPath)
                    finalDestination = MSPPOSIXCommandSupport.joinPath(destinationDirectory.virtualPath, child: relativeName)
                } else {
                    finalDestination = destinationOperand
                }
                let destinationResolved = try fileSystem.resolve(finalDestination, from: context.currentDirectory)
                if !overwriteExisting, (try? fileSystem.stat(destinationResolved.virtualPath, from: "/")) != nil {
                    continue
                }
                if sourceResolved.virtualPath == destinationResolved.virtualPath {
                    diagnostics.append(
                        "cp: '\(MSPPOSIXCommandSupport.displayPath(source))' and '\(MSPPOSIXCommandSupport.displayPath(destinationOperand))' are the same file"
                    )
                    continue
                }
                if preserveParents, let parentPath = parentDirectoryPath(of: destinationResolved.virtualPath) {
                    try fileSystem.createDirectory(
                        parentPath,
                        from: "/",
                        intermediates: true,
                        creationMode: context.directoryCreationMode
                    )
                }
                if shouldPrepareBatch {
                    preparedCopies.append(PreparedCopy(source: source, destination: finalDestination))
                } else {
                    try fileSystem.copy(
                        source,
                        to: finalDestination,
                        from: context.currentDirectory,
                        options: copyOptions
                    )
                    if verbose {
                        stdout += "'\(MSPPOSIXCommandSupport.displayPath(source))' -> '\(MSPPOSIXCommandSupport.displayPath(finalDestination))'\n"
                    }
                }
            } catch {
                let displayPath = MSPPOSIXCommandSupport.displayPath(source)
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("cp: cannot copy '\(displayPath)': \(reason)")
            }
        }

        if shouldPrepareBatch,
           diagnostics.isEmpty,
           preparedCopies.count > 1,
           let batchFileSystem {
            do {
                try batchFileSystem.copy(
                    preparedCopies.map {
                        MSPFileCopyRequest(sourcePath: $0.source, destinationPath: $0.destination)
                    },
                    from: context.currentDirectory,
                    options: copyOptions
                )
                if verbose {
                    stdout += preparedCopies.map {
                        "'\(MSPPOSIXCommandSupport.displayPath($0.source))' -> '\(MSPPOSIXCommandSupport.displayPath($0.destination))'"
                    }.joined(separator: "\n")
                    stdout += "\n"
                }
            } catch {
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                diagnostics.append("cp: cannot copy batch: \(reason)")
            }
        } else {
            for copy in preparedCopies {
                do {
                    try fileSystem.copy(
                        copy.source,
                        to: copy.destination,
                        from: context.currentDirectory,
                        options: copyOptions
                    )
                    if verbose {
                        stdout += "'\(MSPPOSIXCommandSupport.displayPath(copy.source))' -> '\(MSPPOSIXCommandSupport.displayPath(copy.destination))'\n"
                    }
                } catch {
                    let displayPath = MSPPOSIXCommandSupport.displayPath(copy.source)
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    diagnostics.append("cp: cannot copy '\(displayPath)': \(reason)")
                }
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

    private func requiresDirectoryDestination(_ path: String) -> Bool {
        path.count > 1 && path.hasSuffix("/")
    }

    private func strippedTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func parentPreservingName(for virtualPath: String) -> String {
        let components = MSPWorkspacePathResolver.components(in: virtualPath)
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private func parentDirectoryPath(of virtualPath: String) -> String? {
        var components = MSPWorkspacePathResolver.components(in: virtualPath)
        guard components.count > 1 else {
            return nil
        }
        components.removeLast()
        return "/" + components.joined(separator: "/")
    }

    private struct PreparedCopy {
        var source: String
        var destination: String
    }
}
