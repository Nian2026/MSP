import Foundation

extension MSPCompositeWorkspaceFileSystem {
    func rebaseEntry(_ entry: MSPDirectoryEntry, mountPath: String) -> MSPDirectoryEntry {
        MSPDirectoryEntry(
            name: entry.name,
            info: rebaseInfo(entry.info, mountPath: mountPath)
        )
    }

    func rebaseInfo(_ info: MSPFileInfo, mountPath: String) -> MSPFileInfo {
        var rebased = info
        rebased.virtualPath = rebasePath(info.virtualPath, mountPath: mountPath)
        if let target = info.symbolicLinkTarget, target.hasPrefix("/") {
            rebased.symbolicLinkTarget = rebasePath(target, mountPath: mountPath)
        }
        return rebased
    }

    func withRebasedRouteErrors<T>(
        _ route: MSPCompositeRoute,
        _ operation: () throws -> T
    ) throws -> T {
        switch route.backend {
        case .base:
            return try operation()
        case .mount(let mount):
            return try withRebasedMountErrors(mount, operation)
        }
    }

    func withRebasedMountErrors<T>(
        _ mount: MSPWorkspaceMount,
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch {
            throw rebaseMountedError(error, mountPath: mount.path)
        }
    }

    func rebaseMountedError(_ error: Error, mountPath: String) -> Error {
        guard let fileSystemError = error as? MSPWorkspaceFileSystemError else {
            return error
        }
        func path(_ backendPath: String) -> String {
            guard backendPath.hasPrefix("/") else {
                return backendPath
            }
            return rebasePath(backendPath, mountPath: mountPath)
        }
        switch fileSystemError {
        case .accessDenied(let backendPath):
            return MSPWorkspaceFileSystemError.accessDenied(path(backendPath))
        case .hiddenPath(let backendPath):
            return MSPWorkspaceFileSystemError.hiddenPath(path(backendPath))
        case .invalidPath(let backendPath):
            return MSPWorkspaceFileSystemError.invalidPath(path(backendPath))
        case .notFound(let backendPath):
            return MSPWorkspaceFileSystemError.notFound(path(backendPath))
        case .notDirectory(let backendPath):
            return MSPWorkspaceFileSystemError.notDirectory(path(backendPath))
        case .isDirectory(let backendPath):
            return MSPWorkspaceFileSystemError.isDirectory(path(backendPath))
        case .directoryNotEmpty(let backendPath):
            return MSPWorkspaceFileSystemError.directoryNotEmpty(path(backendPath))
        case .notSymbolicLink(let backendPath):
            return MSPWorkspaceFileSystemError.notSymbolicLink(path(backendPath))
        case .alreadyExists(let backendPath):
            return MSPWorkspaceFileSystemError.alreadyExists(path(backendPath))
        case .encodingFailed(let backendPath):
            return MSPWorkspaceFileSystemError.encodingFailed(path(backendPath))
        case .io(let backendPath, let operation):
            return MSPWorkspaceFileSystemError.io(path: path(backendPath), operation: operation)
        }
    }

    func rebasePath(_ backendPath: String, mountPath: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(backendPath)
        guard normalized != "/" else {
            return mountPath
        }
        return MSPWorkspacePathResolver.normalize(mountPath + "/" + normalized.dropFirst())
    }

    func backendPath(forMountedVirtualPath virtualPath: String, mountPath: String) -> String {
        guard virtualPath != mountPath else {
            return "/"
        }
        return "/" + virtualPath.dropFirst(mountPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func backendPath(forRebasedPath virtualPath: String, mountPath: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(virtualPath)
        guard normalized == mountPath || normalized.hasPrefix(mountPath + "/") else {
            return normalized
        }
        return backendPath(forMountedVirtualPath: normalized, mountPath: mountPath)
    }
}
