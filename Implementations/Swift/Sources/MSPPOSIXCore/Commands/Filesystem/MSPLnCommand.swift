import Foundation
import MSPCore

public struct MSPLnCommand: MSPCommand {
    public let name = "ln"
    public let summary: String? = "Create links between files."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        var symbolic = false
        var force = false
        var noDereferenceDestination = false
        var noTargetDirectory = false
        var verbose = false
        var targetDirectory: String?
        var operands: [String] = []
        var parsingOptions = true
        var index = 0

        while index < invocation.arguments.count {
            let argument = invocation.arguments[index]
            if parsingOptions, argument == "--" {
                parsingOptions = false
                index += 1
                continue
            }
            if parsingOptions, argument.hasPrefix("-"), argument != "-" {
                if argument == "--symbolic" {
                    symbolic = true
                    index += 1
                    continue
                }
                if argument == "--force" {
                    force = true
                    index += 1
                    continue
                }
                if argument == "--no-dereference" {
                    noDereferenceDestination = true
                    index += 1
                    continue
                }
                if argument == "--no-target-directory" {
                    noTargetDirectory = true
                    index += 1
                    continue
                }
                if argument == "--verbose" {
                    verbose = true
                    index += 1
                    continue
                }
                if argument == "--target-directory" {
                    index += 1
                    guard index < invocation.arguments.count else {
                        throw MSPCommandFailure.usage("ln: option '--target-directory' requires an argument\n")
                    }
                    targetDirectory = invocation.arguments[index]
                    index += 1
                    continue
                }
                if argument.hasPrefix("--target-directory=") {
                    targetDirectory = String(argument.dropFirst("--target-directory=".count))
                    index += 1
                    continue
                }
                switch argument {
                default:
                    let characters = Array(argument.dropFirst())
                    var characterIndex = 0
                    while characterIndex < characters.count {
                        let option = characters[characterIndex]
                        switch option {
                        case "s":
                            symbolic = true
                        case "f":
                            force = true
                        case "n":
                            noDereferenceDestination = true
                        case "T":
                            noTargetDirectory = true
                        case "v":
                            verbose = true
                        case "t":
                            let tail = String(characters.dropFirst(characterIndex + 1))
                            if tail.isEmpty {
                                index += 1
                                guard index < invocation.arguments.count else {
                                    throw MSPCommandFailure.usage("ln: option requires an argument -- 't'\n")
                                }
                                targetDirectory = invocation.arguments[index]
                            } else {
                                targetDirectory = tail
                            }
                            characterIndex = characters.count
                            continue
                        default:
                            throw MSPCommandFailure.usage("ln: invalid option -- '\(option)'\n")
                        }
                        characterIndex += 1
                    }
                }
                index += 1
                continue
            }
            operands.append(argument)
            index += 1
        }

        guard !(targetDirectory != nil && noTargetDirectory) else {
            return .failure(stderr: "ln: cannot combine --target-directory and --no-target-directory\n")
        }
        guard !operands.isEmpty else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "ln: missing file operand\nTry 'ln --help' for more information.\n"
                )
            )
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        if targetDirectory != nil || (!noTargetDirectory && operands.count > 2) {
            let destination = targetDirectory ?? operands[operands.count - 1]
            let targets = targetDirectory == nil ? Array(operands.dropLast()) : operands
            guard let destinationDirectory = try existingDirectoryInfo(
                destination,
                fileSystem: fileSystem,
                currentDirectory: context.currentDirectory
            ) else {
                let reason = missingOrNotDirectoryReason(
                    destination,
                    fileSystem: fileSystem,
                    context: context
                )
                return .failure(stderr: "ln: target '\(destination)': \(reason)\n")
            }

            var diagnostics: [String] = []
            var stdout = ""
            for target in targets {
                let rawLinkName = mspPOSIXJoinVirtualPath(
                    parent: destinationDirectory.virtualPath,
                    child: targetName(for: target)
                )
                let displayLinkName = mspPOSIXJoinDisplayPath(
                    parent: MSPPOSIXCommandSupport.displayPath(destination),
                    child: targetName(for: target)
                )
                if let diagnostic = createLinkDiagnostic(
                    target: target,
                    rawLinkName: rawLinkName,
                    displayLinkName: displayLinkName,
                    symbolic: symbolic,
                    force: force,
                    noDereferenceDestination: true,
                    fileSystem: fileSystem,
                    context: context
                ) {
                    diagnostics.append(diagnostic)
                } else if verbose {
                    stdout += verboseLine(
                        linkName: displayLinkName,
                        target: MSPPOSIXCommandSupport.displayPath(target),
                        symbolic: symbolic
                    )
                }
            }
            guard diagnostics.isEmpty else {
                return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
            }
            return .success(stdout: stdout)
        }
        guard operands.count <= 2 else {
            return .failure(
                stderr: "ln: extra operand '\(MSPPOSIXCommandSupport.displayPath(operands[2]))'\nTry 'ln --help' for more information.\n"
            )
        }

        let target = operands[0]
        let rawLinkName = operands.count == 1 ? "./\(targetName(for: target))" : operands[1]
        let displayLinkName = operands.count == 1
            ? rawLinkName
            : MSPPOSIXCommandSupport.displayPath(operands[1])
        if let diagnostic = createLinkDiagnostic(
            target: target,
            rawLinkName: rawLinkName,
            displayLinkName: displayLinkName,
            symbolic: symbolic,
            force: force,
            noDereferenceDestination: noDereferenceDestination || noTargetDirectory,
            fileSystem: fileSystem,
            context: context
        ) {
            return .failure(stderr: diagnostic + "\n")
        }
        let stdout = verbose
            ? verboseLine(
                linkName: displayLinkName,
                target: MSPPOSIXCommandSupport.displayPath(target),
                symbolic: symbolic
            )
            : ""
        return .success(stdout: stdout)
    }

    private func verboseLine(linkName: String, target: String, symbolic: Bool) -> String {
        "'\(linkName)' \(symbolic ? "->" : "=>") '\(target)'\n"
    }

    private func createLinkDiagnostic(
        target: String,
        rawLinkName: String,
        displayLinkName: String,
        symbolic: Bool,
        force: Bool,
        noDereferenceDestination: Bool,
        fileSystem: any MSPWorkspaceFileSystem,
        context: MSPCommandContext
    ) -> String? {
        if !symbolic {
            do {
                let targetInfo = try fileSystem.stat(target, from: context.currentDirectory)
                if targetInfo.isDirectory {
                    return "ln: \(MSPPOSIXCommandSupport.displayPath(target)): hard link not allowed for directory"
                }
            } catch {
                let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                return "ln: failed to access '\(MSPPOSIXCommandSupport.displayPath(target))': \(reason)"
            }
        }
        do {
            let linkName = try resolvedLinkName(
                rawLinkName: rawLinkName,
                target: target,
                noDereferenceDestination: noDereferenceDestination,
                fileSystem: fileSystem,
                context: context
            )
            if symbolic, !force, (try? fileSystem.readSymbolicLink(linkName, from: "/")) != nil {
                return "ln: failed to create symbolic link '\(displayLinkName)': File exists"
            }
            if force {
                try? fileSystem.remove(linkName, from: "/", recursive: false)
            }
            if symbolic {
                try fileSystem.createSymbolicLink(target: target, at: linkName, from: "/")
            } else {
                try fileSystem.createHardLink(source: target, at: linkName, from: context.currentDirectory)
            }
            return nil
        } catch {
            let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
            let linkDescription = symbolic ? "symbolic link" : "hard link"
            return "ln: failed to create \(linkDescription) '\(displayLinkName)': \(reason)"
        }
    }

    private func resolvedLinkName(
        rawLinkName: String,
        target: String,
        noDereferenceDestination: Bool,
        fileSystem: any MSPWorkspaceFileSystem,
        context: MSPCommandContext
    ) throws -> String {
        let linkPath = try fileSystem.resolve(rawLinkName, from: context.currentDirectory).virtualPath
        guard !noDereferenceDestination,
              let directoryInfo = try existingDirectoryInfo(
                linkPath,
                fileSystem: fileSystem,
                currentDirectory: "/"
              ) else {
            return linkPath
        }
        return mspPOSIXJoinVirtualPath(parent: directoryInfo.virtualPath, child: targetName(for: target))
    }

    private func targetName(for target: String) -> String {
        let trimmed = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmed.split(separator: "/").last else {
            return target
        }
        return String(last)
    }

    private func existingDirectoryInfo(
        _ path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> MSPFileInfo? {
        do {
            let info = try fileSystem.stat(path, from: currentDirectory)
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
                currentDirectory: currentDirectory
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
}

private func mspPOSIXJoinVirtualPath(parent: String, child: String) -> String {
    parent == "/" ? "/" + child : parent + "/" + child
}

private func mspPOSIXJoinDisplayPath(parent: String, child: String) -> String {
    if parent == "/" {
        return "/" + child
    }
    let trimmed = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty {
        return child
    }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}
