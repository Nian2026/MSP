import Foundation
import MSPCore

final class RgRunState {
    var hadDiagnostics = false
    var anyMatched = false
    var currentFileMatchCount = 0
}

struct RgRootItem {
    var info: MSPFileInfo
    var displayPath: String
}

struct RgFileCandidate {
    var info: MSPFileInfo
    var displayPath: String
}

struct RgRootResolution {
    var items: [RgRootItem]
    var containsDirectory: Bool
    var regularFileCount: Int
}

func resolveRgRoots(
    query: RgQuery,
    fileSystem: any MSPWorkspaceFileSystem,
    context: MSPCommandContext,
    output: any RgOutputWriter,
    state: RgRunState
) async throws -> RgRootResolution {
    let roots = query.paths.isEmpty ? ["."] : query.paths
    var items: [RgRootItem] = []
    var containsDirectory = false
    var regularFileCount = 0

    for root in roots {
        do {
            let resolved = try fileSystem.resolve(root, from: context.currentDirectory)
            let info = try fileSystem.stat(resolved.virtualPath, from: "/")
            if info.isDirectory {
                containsDirectory = true
            } else if info.type == .regularFile {
                regularFileCount += 1
            }
            items.append(RgRootItem(
                info: info,
                displayPath: rgDisplayPath(
                    for: root,
                    resolvedPath: resolved.virtualPath,
                    isImplicitRoot: query.paths.isEmpty
                )
            ))
        } catch {
            state.hadDiagnostics = true
            if !query.noMessages {
                try await output.appendDiagnostic(rgFileSystemDiagnostic(
                    path: MSPPOSIXCommandSupport.displayPath(root),
                    error: error
                ))
            }
        }
    }

    return RgRootResolution(
        items: items,
        containsDirectory: containsDirectory,
        regularFileCount: regularFileCount
    )
}

func visitRgFiles(
    _ info: MSPFileInfo,
    displayPath: String,
    fileSystem: any MSPWorkspaceFileSystem,
    query: RgQuery,
    output: any RgOutputWriter,
    state: RgRunState,
    onFile: (RgFileCandidate) async throws -> Bool
) async throws -> Bool {
    if !query.includeHidden, MSPPOSIXCommandSupport.basename(info.virtualPath).hasPrefix(".") {
        return true
    }
    switch info.type {
    case .regularFile:
        guard query.globRules.isEmpty || query.includes(displayPath) else {
            return true
        }
        return try await onFile(RgFileCandidate(info: info, displayPath: displayPath))
    case .directory:
        do {
            var shouldContinue = true
            try await fileSystem.enumerateDirectory(info.virtualPath, from: "/") { entry in
                shouldContinue = try await visitRgFiles(
                    entry.info,
                    displayPath: rgJoinDisplayPath(displayPath, MSPPOSIXCommandSupport.basename(entry.info.virtualPath)),
                    fileSystem: fileSystem,
                    query: query,
                    output: output,
                    state: state,
                    onFile: onFile
                )
                return shouldContinue
                }
                return shouldContinue
            } catch MSPCommandStreamError.brokenPipe {
                throw MSPCommandStreamError.brokenPipe
            } catch {
                state.hadDiagnostics = true
                try await output.appendDiagnostic(rgFileSystemDiagnostic(
                path: displayPath.isEmpty ? "." : displayPath,
                error: error
            ))
            return true
        }
    case .symbolicLink, .other:
        return true
    }
}
