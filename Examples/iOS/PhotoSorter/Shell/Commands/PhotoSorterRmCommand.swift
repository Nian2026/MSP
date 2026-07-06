import Foundation
import ModelShellProxy
import MSPCore

struct PhotoSorterRmCommand: MSPCommand {
    let name = "rm"
    let summary: String? = "Remove workspace files or directories."

    private let assetTrashBatcher: (any PhotoSorterAssetTrashBatching)?

    init(assetTrashBatcher: (any PhotoSorterAssetTrashBatching)?) {
        self.assetTrashBatcher = assetTrashBatcher
    }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try Self.parse(arguments: invocation.arguments)
        if parsed.operands.isEmpty {
            return parsed.force
                ? .success()
                : .failure(
                    exitCode: 1,
                    stderr: "rm: missing operand\nTry 'rm --help' for more information.\n"
                )
        }

        guard let fileSystem = context.workspace?.fileSystem else {
            return .failure(exitCode: 125, stderr: "rm: workspace is required\n")
        }

        var diagnostics: [String] = []
        var stdout = ""
        var batch: [PhotoSorterRmBatchItem] = []
        var batchedVirtualPaths = Set<String>()

        func flushBatch() {
            guard !batch.isEmpty else {
                return
            }
            let pending = batch
            batch.removeAll(keepingCapacity: true)
            batchedVirtualPaths.removeAll(keepingCapacity: true)

            do {
                if let assetTrashBatcher, pending.count > 1 {
                    try assetTrashBatcher.trashPhotoSorterAssets(at: pending.map(\.virtualPath))
                } else {
                    for item in pending {
                        try fileSystem.remove(item.rawPath, from: context.currentDirectory, recursive: false)
                    }
                }
                if parsed.verbose {
                    stdout += pending.map {
                        "removed '\(Self.displayPath($0.rawPath))'\n"
                    }.joined()
                }
            } catch {
                for item in pending {
                    do {
                        try fileSystem.remove(item.rawPath, from: context.currentDirectory, recursive: false)
                        if parsed.verbose {
                            stdout += "removed '\(Self.displayPath(item.rawPath))'\n"
                        }
                    } catch {
                        diagnostics.append(Self.cannotRemoveDiagnostic(path: item.rawPath, error: error))
                    }
                }
            }
        }

        for path in parsed.operands {
            do {
                let info = try fileSystem.stat(path, from: context.currentDirectory)
                let shouldRemoveDirectory = info.type == .directory && (parsed.recursive || parsed.removeEmptyDirectories)
                if info.type == .directory, parsed.removeEmptyDirectories, !parsed.recursive {
                    let entries = try fileSystem.listDirectory(info.virtualPath, from: "/")
                    guard entries.isEmpty else {
                        flushBatch()
                        diagnostics.append("rm: cannot remove '\(Self.displayPath(path))': Directory not empty")
                        continue
                    }
                }

                if !shouldRemoveDirectory,
                   info.type == .regularFile,
                   Self.isBatchablePhotoAssetPath(info.virtualPath) {
                    if batchedVirtualPaths.contains(info.virtualPath) {
                        flushBatch()
                    }
                    batch.append(PhotoSorterRmBatchItem(rawPath: path, virtualPath: info.virtualPath))
                    batchedVirtualPaths.insert(info.virtualPath)
                    continue
                }

                flushBatch()
                try fileSystem.remove(path, from: context.currentDirectory, recursive: shouldRemoveDirectory)
                if parsed.verbose {
                    stdout += "removed '\(Self.displayPath(path))'\n"
                }
            } catch MSPWorkspaceFileSystemError.notFound where parsed.force {
                flushBatch()
                continue
            } catch {
                flushBatch()
                diagnostics.append(Self.cannotRemoveDiagnostic(path: path, error: error))
            }
        }

        flushBatch()
        guard diagnostics.isEmpty else {
            return .failure(stdout: stdout, stderr: diagnostics.joined(separator: "\n") + "\n")
        }
        return .success(stdout: stdout)
    }

    private static func parse(arguments: [String]) throws -> PhotoSorterRmParsedArguments {
        var parsed = PhotoSorterRmParsedArguments()
        var parsingOptions = true

        for argument in arguments {
            guard parsingOptions else {
                parsed.operands.append(argument)
                continue
            }
            if argument == "--" {
                parsingOptions = false
                continue
            }
            if argument.hasPrefix("--"), argument.count > 2 {
                let optionName = String(argument.dropFirst(2))
                    .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init) ?? ""
                switch optionName {
                case "recursive":
                    parsed.recursive = true
                case "force":
                    parsed.force = true
                case "dir":
                    parsed.removeEmptyDirectories = true
                case "verbose":
                    parsed.verbose = true
                default:
                    throw MSPCommandFailure.usage("rm: unsupported option -- \(optionName)\n")
                }
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                for option in argument.dropFirst() {
                    switch option {
                    case "r", "R":
                        parsed.recursive = true
                    case "f":
                        parsed.force = true
                    case "d":
                        parsed.removeEmptyDirectories = true
                    case "v":
                        parsed.verbose = true
                    default:
                        throw MSPCommandFailure.usage("rm: unsupported option -- \(option)\n")
                    }
                }
                continue
            }
            parsed.operands.append(argument)
        }

        return parsed
    }

    private static func isBatchablePhotoAssetPath(_ virtualPath: String) -> Bool {
        guard let parentPath = PhotoLibraryMount.parentPath(of: virtualPath) else {
            return false
        }
        if parentPath == "/图库" {
            return true
        }
        if PhotoLibraryMount.isSystemAlbumMediaDirectory(parentPath) {
            return true
        }
        return parentPath.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/")
    }

    private static func cannotRemoveDiagnostic(path: String, error: Error) -> String {
        "rm: cannot remove '\(displayPath(path))': \(diagnosticReason(from: error))"
    }

    private static func displayPath(_ path: String) -> String {
        path.isEmpty ? "." : path
    }

    private static func diagnosticReason(from error: Error) -> String {
        guard let fileSystemError = error as? MSPWorkspaceFileSystemError else {
            return "\(error)"
        }
        switch fileSystemError {
        case .accessDenied, .hiddenPath:
            return "Permission denied"
        case .invalidPath:
            return "Invalid argument"
        case .notFound:
            return "No such file or directory"
        case .notDirectory:
            return "Not a directory"
        case .isDirectory:
            return "Is a directory"
        case .directoryNotEmpty:
            return "Directory not empty"
        case .notSymbolicLink:
            return "Invalid argument"
        case .alreadyExists:
            return "File exists"
        case .encodingFailed:
            return "Invalid or incomplete multibyte or wide character"
        case .io:
            return "Input/output error"
        }
    }
}

private struct PhotoSorterRmParsedArguments {
    var recursive = false
    var force = false
    var removeEmptyDirectories = false
    var verbose = false
    var operands: [String] = []
}

private struct PhotoSorterRmBatchItem {
    var rawPath: String
    var virtualPath: String
}
