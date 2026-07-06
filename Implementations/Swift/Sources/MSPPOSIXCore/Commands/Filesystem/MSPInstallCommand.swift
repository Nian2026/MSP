import Foundation
import MSPCore

public struct MSPInstallCommand: MSPCommand {
    public let name = "install"
    public let summary: String? = "Copy files or create directories with install-style modes."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = parse(invocation.arguments)
        if let result = parsed.result {
            return result
        }
        let mode: UInt16
        do {
            mode = try parsed.modeString.map { try mspCore100ParseOctalMode($0, command: name) }
                ?? mspCore100DefaultInstallMode
        } catch let failure as MSPCommandFailure {
            return failure.result
        }

        guard !parsed.operands.isEmpty else {
            return .failure(
                exitCode: 1,
                stderr: "install: missing file operand\n\(mspCore100GNUHelpHint(name))"
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        if parsed.createDirectories {
            return createDirectories(
                parsed.operands,
                mode: mode,
                verbose: parsed.verbose,
                context: context,
                fileSystem: fileSystem
            )
        }

        let plan = destinationPlan(parsed: parsed, context: context, fileSystem: fileSystem)
        if let result = plan.result {
            return result
        }

        var stdout = ""
        var diagnostics: [String] = []
        for source in plan.sources {
            do {
                try installFile(
                    source: source,
                    destination: plan.destination(for: source),
                    parsed: parsed,
                    mode: mode,
                    context: context,
                    fileSystem: fileSystem,
                    stdout: &stdout
                )
            } catch let error as InstallDiagnostic {
                diagnostics.append(error.message)
            } catch {
                diagnostics.append("install: cannot stat '\(mspCore100DisplayPath(source))': \(mspCore100Reason(error))")
            }
        }

        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }

    private func createDirectories(
        _ operands: [String],
        mode: UInt16,
        verbose: Bool,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem
    ) -> MSPCommandResult {
        var diagnostics: [String] = []
        var stdout = ""
        for operand in operands {
            do {
                try createDirectoryPath(
                    operand,
                    finalMode: mode,
                    context: context,
                    fileSystem: fileSystem
                )
                if verbose {
                    stdout += "install: creating directory '\(mspCore100DisplayPath(operand))'\n"
                }
            } catch {
                diagnostics.append("install: cannot create directory '\(mspCore100DisplayPath(operand))': \(mspCore100Reason(error))")
            }
        }
        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }

    private func installFile(
        source: String,
        destination: String,
        parsed: InstallParseResult,
        mode: UInt16,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem,
        stdout: inout String
    ) throws {
        let sourceResolved = try fileSystem.resolve(source, from: context.currentDirectory)
        do {
            _ = try fileSystem.stat(sourceResolved.virtualPath, from: "/")
        } catch {
            throw InstallDiagnostic("install: cannot stat '\(mspCore100DisplayPath(source))': \(mspCore100Reason(error))")
        }

        let destinationResolved = try fileSystem.resolve(destination, from: context.currentDirectory)
        let destinationInfo = try? fileSystem.stat(destinationResolved.virtualPath, from: "/")
        if parsed.noTargetDirectory, destinationInfo?.type == .directory {
            throw InstallDiagnostic(
                "install: cannot overwrite directory '\(mspCore100DisplayPath(destination))' with non-directory"
            )
        }
        if destinationInfo?.type == .directory {
            throw InstallDiagnostic(
                "install: cannot overwrite directory '\(mspCore100DisplayPath(destination))' with non-directory"
            )
        }

        let sourceData: Data
        do {
            sourceData = try fileSystem.readFile(sourceResolved.virtualPath, from: "/")
        } catch {
            throw InstallDiagnostic("install: cannot open '\(mspCore100DisplayPath(source))' for reading: \(mspCore100Reason(error))")
        }
        guard sourceData.count <= mspCore100MaximumMaterializedFileSize else {
            throw InstallDiagnostic("install: cannot stat '\(mspCore100DisplayPath(source))': File too large")
        }

        if parsed.stripFiles {
            throw InstallDiagnostic(
                "strip: \(mspCore100DisplayPath(destination)): file format not recognized\ninstall: strip process terminated abnormally"
            )
        }

        if parsed.createParentDirectories {
            try createParentDirectories(
                forFile: destinationResolved.virtualPath,
                context: context,
                fileSystem: fileSystem
            )
        }

        if parsed.makeBackup, let existing = destinationInfo {
            try writeBackup(
                for: destinationResolved.virtualPath,
                existingInfo: existing,
                fileSystem: fileSystem
            )
        }

        if parsed.compareOnly,
           let existing = destinationInfo,
           existing.type == .regularFile,
           (try? fileSystem.readFile(destinationResolved.virtualPath, from: "/")) == sourceData,
           (existing.permissions ?? mspCore100DefaultFileMode) & 0o777 == mode {
            return
        }

        do {
            try fileSystem.writeFile(
                destinationResolved.virtualPath,
                data: sourceData,
                from: "/",
                options: [.overwriteExisting],
                creationMode: destinationInfo == nil ? mode : nil
            )
            try fileSystem.chmod(destinationResolved.virtualPath, mode: mode, from: "/")
        } catch {
            throw InstallDiagnostic(
                "install: cannot create regular file '\(mspCore100DisplayPath(destination))': \(mspCore100Reason(error))"
            )
        }

        if parsed.verbose {
            stdout += "'\(mspCore100DisplayPath(source))' -> '\(mspCore100DisplayPath(destination))'\n"
        }
    }

    private func writeBackup(
        for destinationVirtualPath: String,
        existingInfo: MSPFileInfo,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        guard existingInfo.type != .directory else {
            return
        }
        let data = try fileSystem.readFile(destinationVirtualPath, from: "/")
        let backupPath = destinationVirtualPath + "~"
        try fileSystem.writeFile(
            backupPath,
            data: data,
            from: "/",
            options: [.overwriteExisting],
            creationMode: existingInfo.permissions ?? mspCore100DefaultFileMode
        )
        try? fileSystem.chmod(backupPath, mode: existingInfo.permissions ?? mspCore100DefaultFileMode, from: "/")
    }

    private func createParentDirectories(
        forFile virtualPath: String,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        let parent = mspCore100ParentPath(of: virtualPath)
        guard parent != "/" else {
            return
        }
        try createDirectoryPath(
            parent,
            finalMode: mspCore100DefaultInstallMode,
            context: MSPCommandContext(
                workspace: context.workspace,
                currentDirectory: "/",
                environment: context.environment,
                standardInput: context.standardInput,
                standardInputClosed: context.standardInputClosed,
                standardInputStream: context.standardInputStream,
                standardOutputStream: context.standardOutputStream,
                standardErrorStream: context.standardErrorStream,
                fileCreationMask: context.fileCreationMask,
                availableCommandNames: context.availableCommandNames,
                subcommandRunner: context.subcommandRunner,
                commandLineRunner: context.commandLineRunner,
                policyEngine: context.policyEngine,
                auditSink: context.auditSink
            ),
            fileSystem: fileSystem
        )
    }

    private func createDirectoryPath(
        _ path: String,
        finalMode: UInt16,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        let resolved = try fileSystem.resolve(path, from: context.currentDirectory)
        var built = ""
        let components = MSPWorkspacePathResolver.components(in: resolved.virtualPath)
        for (index, component) in components.enumerated() {
            built = built.isEmpty ? "/" + component : built + "/" + component
            if let existing = try? fileSystem.stat(built, from: "/") {
                guard existing.type == .directory else {
                    throw MSPWorkspaceFileSystemError.notDirectory(built)
                }
                if index == components.count - 1 {
                    try? fileSystem.chmod(built, mode: finalMode, from: "/")
                }
                continue
            }
            let mode = index == components.count - 1 ? finalMode : mspCore100DefaultInstallMode
            try fileSystem.createDirectory(
                built,
                from: "/",
                intermediates: false,
                creationMode: mode
            )
            try? fileSystem.chmod(built, mode: mode, from: "/")
        }
    }

    private func destinationPlan(
        parsed: InstallParseResult,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem
    ) -> InstallDestinationPlan {
        if let targetDirectory = parsed.targetDirectory {
            guard let info = try? fileSystem.stat(targetDirectory, from: context.currentDirectory),
                  info.type == .directory
            else {
                return InstallDestinationPlan(
                    sources: [],
                    explicitDestination: nil,
                    destinationDirectory: nil,
                    context: context,
                    fileSystem: fileSystem,
                    result: .failure(stderr: "install: target directory '\(mspCore100DisplayPath(targetDirectory))': No such file or directory\n")
                )
            }
            return InstallDestinationPlan(
                sources: parsed.operands,
                explicitDestination: nil,
                destinationDirectory: info.virtualPath,
                context: context,
                fileSystem: fileSystem,
                result: nil
            )
        }

        guard parsed.operands.count >= 2 else {
            return InstallDestinationPlan(
                sources: [],
                explicitDestination: nil,
                destinationDirectory: nil,
                context: context,
                fileSystem: fileSystem,
                result: .failure(
                    exitCode: 1,
                    stderr: "install: missing destination file operand after '\(parsed.operands[0])'\n\(mspCore100GNUHelpHint(name))"
                )
            )
        }

        let sources = Array(parsed.operands.dropLast())
        let destination = parsed.operands[parsed.operands.count - 1]
        if sources.count > 1 {
            guard let info = try? fileSystem.stat(destination, from: context.currentDirectory),
                  info.type == .directory
            else {
                return InstallDestinationPlan(
                    sources: [],
                    explicitDestination: nil,
                    destinationDirectory: nil,
                    context: context,
                    fileSystem: fileSystem,
                    result: .failure(stderr: "install: target '\(mspCore100DisplayPath(destination))': Not a directory\n")
                )
            }
            return InstallDestinationPlan(
                sources: sources,
                explicitDestination: nil,
                destinationDirectory: info.virtualPath,
                context: context,
                fileSystem: fileSystem,
                result: nil
            )
        }

        if !parsed.noTargetDirectory,
           let info = try? fileSystem.stat(destination, from: context.currentDirectory),
           info.type == .directory {
            return InstallDestinationPlan(
                sources: sources,
                explicitDestination: nil,
                destinationDirectory: info.virtualPath,
                context: context,
                fileSystem: fileSystem,
                result: nil
            )
        }

        return InstallDestinationPlan(
            sources: sources,
            explicitDestination: destination,
            destinationDirectory: nil,
            context: context,
            fileSystem: fileSystem,
            result: nil
        )
    }

    private func parse(_ arguments: [String]) -> InstallParseResult {
        var result = InstallParseResult()
        var parsingOptions = true
        var index = 0

        func requireValue(option: String) -> String? {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                result.result = .failure(
                    exitCode: 1,
                    stderr: "install: option requires an argument -- '\(option)'\n\(mspCore100GNUHelpHint(name))"
                )
                return nil
            }
            index = nextIndex
            return arguments[nextIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if !parsingOptions {
                result.operands.append(argument)
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
                case "strip-program":
                    guard (inlineValue ?? requireValue(option: "strip-program")) != nil else {
                        return result
                    }
                case "directory":
                    result.createDirectories = true
                case "backup":
                    result.makeBackup = true
                case "compare":
                    result.compareOnly = true
                case "strip":
                    result.stripFiles = true
                case "preserve-timestamps":
                    result.preserveTimestamps = true
                case "mode":
                    guard let value = inlineValue ?? requireValue(option: "mode") else {
                        return result
                    }
                    result.modeString = value
                case "target-directory":
                    guard let value = inlineValue ?? requireValue(option: "target-directory") else {
                        return result
                    }
                    result.targetDirectory = value
                case "owner":
                    guard (inlineValue ?? requireValue(option: "owner")) != nil else {
                        return result
                    }
                case "group":
                    guard (inlineValue ?? requireValue(option: "group")) != nil else {
                        return result
                    }
                default:
                    result.result = mspCore100InvalidOption(name, option: option.first ?? "?")
                    return result
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
                    case "c":
                        break
                    case "b":
                        result.makeBackup = true
                    case "C":
                        result.compareOnly = true
                    case "D":
                        result.createParentDirectories = true
                    case "d":
                        result.createDirectories = true
                    case "p":
                        result.preserveTimestamps = true
                    case "s":
                        result.stripFiles = true
                    case "T":
                        result.noTargetDirectory = true
                    case "v":
                        result.verbose = true
                    case "g", "m", "o", "t":
                        let tail = String(characters.dropFirst(characterIndex + 1))
                        let value: String
                        if tail.isEmpty {
                            guard let required = requireValue(option: String(option)) else {
                                return result
                            }
                            value = required
                        } else {
                            value = tail
                        }
                        switch option {
                        case "m":
                            result.modeString = value
                        case "t":
                            result.targetDirectory = value
                        default:
                            break
                        }
                        characterIndex = characters.count
                        continue
                    default:
                        result.result = mspCore100InvalidOption(name, option: option)
                        return result
                    }
                    characterIndex += 1
                }
                index += 1
                continue
            }
            result.operands.append(argument)
            index += 1
        }
        return result
    }
}

private struct InstallParseResult {
    var createDirectories = false
    var createParentDirectories = false
    var noTargetDirectory = false
    var targetDirectory: String?
    var modeString: String?
    var makeBackup = false
    var compareOnly = false
    var stripFiles = false
    var preserveTimestamps = false
    var verbose = false
    var operands: [String] = []
    var result: MSPCommandResult?
}

private struct InstallDestinationPlan {
    var sources: [String]
    var explicitDestination: String?
    var destinationDirectory: String?
    var context: MSPCommandContext
    var fileSystem: any MSPWorkspaceFileSystem
    var result: MSPCommandResult?

    func destination(for source: String) throws -> String {
        if let explicitDestination {
            return explicitDestination
        }
        guard let destinationDirectory else {
            return source
        }
        let resolvedSource = try fileSystem.resolve(source, from: context.currentDirectory)
        return mspCore100JoinPath(
            parent: destinationDirectory,
            child: mspCore100Basename(resolvedSource.virtualPath)
        )
    }
}

private struct InstallDiagnostic: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
