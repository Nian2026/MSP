import Foundation

extension MSPCompositeWorkspaceFileSystem {
    public func openSequentialFileReader(
        _ path: String,
        from currentDirectory: String
    ) throws -> (any MSPWorkspaceSequentialFileReader)? {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            guard let fileSystem = baseFileSystem as? any MSPWorkspaceSequentialFileReading else {
                return nil
            }
            return try fileSystem.openSequentialFileReader(route.virtualPath, from: "/")
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            guard let fileSystem = mount.fileSystem as? any MSPWorkspaceSequentialFileReading else {
                return nil
            }
            return try withRebasedMountErrors(mount) {
                try fileSystem.openSequentialFileReader(route.backendPath, from: "/")
            }
        }
    }

    public func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                return MSPResolvedPath(virtualPath: route.virtualPath)
            }
            return try baseFileSystem.resolve(route.virtualPath, from: "/")
        case .mount(let mount):
            if route.isMountRoot {
                return MSPResolvedPath(virtualPath: mount.path)
            }
            let resolved = try withRebasedMountErrors(mount) {
                try mount.fileSystem.resolve(route.backendPath, from: "/")
            }
            return MSPResolvedPath(
                virtualPath: rebasePath(resolved.virtualPath, mountPath: mount.path),
                physicalPath: resolved.physicalPath
            )
        }
    }

    public func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            do {
                return try baseFileSystem.stat(route.virtualPath, from: "/")
            } catch MSPWorkspaceFileSystemError.notFound where isSyntheticMountDirectory(route.virtualPath) {
                return syntheticMountDirectoryInfo(route.virtualPath)
            }
        case .mount(let mount):
            if route.isMountRoot {
                return mountedRootInfo(for: mount)
            }
            return try withRebasedMountErrors(mount) {
                try rebaseInfo(
                    mount.fileSystem.stat(route.backendPath, from: "/"),
                    mountPath: mount.path
                )
            }
        }
    }

    public func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.notSymbolicLink(route.virtualPath)
            }
            return try baseFileSystem.readSymbolicLink(route.virtualPath, from: "/")
        case .mount(let mount):
            let target = try withRebasedMountErrors(mount) {
                try mount.fileSystem.readSymbolicLink(route.backendPath, from: "/")
            }
            guard target.hasPrefix("/") else {
                return target
            }
            return rebasePath(target, mountPath: mount.path)
        }
    }

    public func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            return try baseFileSystem.readFile(route.virtualPath, from: "/")
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            return try withRebasedMountErrors(mount) {
                try mount.fileSystem.readFile(route.backendPath, from: "/")
            }
        }
    }

    public func readFileRange(
        _ path: String,
        from currentDirectory: String,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            return try baseFileSystem.readFileRange(route.virtualPath, from: "/", offset: offset, length: length)
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            return try withRebasedMountErrors(mount) {
                try mount.fileSystem.readFileRange(route.backendPath, from: "/", offset: offset, length: length)
            }
        }
    }
}
