import Foundation
import MSPCore

func grepVisitSources(
    paths: [String],
    options: GrepOptions,
    context: MSPCommandContext,
    state: GrepRunState,
    visitor: (GrepSource) async throws -> Bool
) async throws {
    guard !paths.isEmpty else {
        let data = options.standardInputConsumedByOptionFile ? Data() : context.standardInput
        _ = try await visitor(GrepSource(path: nil, data: data))
        return
    }
    let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: "grep")
    var standardInputConsumed = options.standardInputConsumedByOptionFile
    for path in paths {
        if path == "-" {
            defer { standardInputConsumed = true }
            let shouldContinue = try await visitor(GrepSource(
                path: "standard input",
                data: standardInputConsumed ? Data() : context.standardInput
            ))
            if !shouldContinue {
                return
            }
            continue
        }
        do {
            let info = try fileSystem.stat(path, from: context.currentDirectory)
            if info.isDirectory {
                switch options.directoryMode {
                case .skip:
                    continue
                case .read:
                    if !state.suppressMessages {
                        state.diagnostics.append("grep: \(path): Is a directory")
                    }
                    state.errorSeen = true
                    continue
                case .recurse:
                    break
                }
                let shouldContinue = try await grepVisitFiles(
                    info,
                    options: options,
                    fileSystem: fileSystem,
                    isCommandLineRoot: true,
                    displayPath: path,
                    visitor: visitor
                )
                if !shouldContinue {
                    return
                }
            } else {
                guard options.shouldSearchFile(info.virtualPath) else {
                    continue
                }
                let data = try fileSystem.readFile(path, from: context.currentDirectory)
                let shouldContinue = try await visitor(GrepSource(path: path, data: data))
                if !shouldContinue {
                    return
                }
            }
        } catch let failure as MSPCommandFailure {
            throw failure
        } catch {
            if !state.suppressMessages {
                state.diagnostics.append(
                    "grep: \(MSPPOSIXCommandSupport.displayPath(path)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                )
            }
            state.errorSeen = true
        }
    }
}

func grepVisitFiles(
    _ info: MSPFileInfo,
    options: GrepOptions,
    fileSystem: any MSPWorkspaceFileSystem,
    isCommandLineRoot: Bool = false,
    displayPath: String? = nil,
    visitor: (GrepSource) async throws -> Bool
) async throws -> Bool {
    if !info.isDirectory {
        guard options.shouldSearchFile(info.virtualPath) else {
            return true
        }
        return try await visitor(GrepSource(
            path: displayPath ?? info.virtualPath,
            data: try fileSystem.readFile(info.virtualPath, from: "/")
        ))
    }
    guard options.shouldDescendIntoDirectory(info.virtualPath, isCommandLineRoot: isCommandLineRoot) else {
        return true
    }
    var shouldContinue = true
    try await fileSystem.enumerateDirectory(info.virtualPath, from: "/") { entry in
        let childDisplayPath = grepChildDisplayPath(
            parent: displayPath ?? grepDisplayPath(for: info.virtualPath),
            childVirtualPath: entry.info.virtualPath
        )
        shouldContinue = try await grepVisitFiles(
            entry.info,
            options: options,
            fileSystem: fileSystem,
            isCommandLineRoot: false,
            displayPath: childDisplayPath,
            visitor: visitor
        )
        return shouldContinue
    }
    return shouldContinue
}

func grepDisplayPath(for virtualPath: String) -> String {
    virtualPath.hasPrefix("/") ? String(virtualPath.dropFirst()) : virtualPath
}

func grepChildDisplayPath(parent: String, childVirtualPath: String) -> String {
    let childName = childVirtualPath.split(separator: "/").last.map(String.init) ?? childVirtualPath
    guard !parent.isEmpty else {
        return childName
    }
    return parent.hasSuffix("/") ? parent + childName : parent + "/" + childName
}
