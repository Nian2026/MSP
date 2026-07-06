import Foundation

extension MSPCompositeWorkspaceFileSystem {
    public func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            try baseFileSystem.writeFile(route.virtualPath, data: data, from: "/", options: options)
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            try withRebasedMountErrors(mount) {
                try mount.fileSystem.writeFile(route.backendPath, data: data, from: "/", options: options)
            }
        }
    }

    public func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                return
            }
            try baseFileSystem.createDirectory(route.virtualPath, from: "/", intermediates: intermediates)
        case .mount(let mount):
            if route.isMountRoot {
                return
            }
            try withRebasedMountErrors(mount) {
                try mount.fileSystem.createDirectory(route.backendPath, from: "/", intermediates: intermediates)
            }
        }
    }

    public func touch(_ path: String, from currentDirectory: String) throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            try baseFileSystem.touch(route.virtualPath, from: "/")
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            try withRebasedMountErrors(mount) {
                try mount.fileSystem.touch(route.backendPath, from: "/")
            }
        }
    }

    public func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.accessDenied(route.virtualPath)
            }
            try baseFileSystem.remove(route.virtualPath, from: "/", recursive: recursive)
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.accessDenied(route.virtualPath)
            }
            try withRebasedMountErrors(mount) {
                try mount.fileSystem.remove(route.backendPath, from: "/", recursive: recursive)
            }
        }
    }
}

extension MSPCompositeWorkspaceFileSystem: MSPWorkspaceFileTimestamping {
    public func setModificationDate(
        _ path: String,
        modificationDate: Date,
        from currentDirectory: String
    ) throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            if isSyntheticMountDirectory(route.virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            guard let timestampingFileSystem = baseFileSystem as? MSPWorkspaceFileTimestamping else {
                try baseFileSystem.touch(route.virtualPath, from: "/")
                return
            }
            try timestampingFileSystem.setModificationDate(
                route.virtualPath,
                modificationDate: modificationDate,
                from: "/"
            )
        case .mount(let mount):
            guard !route.isMountRoot else {
                throw MSPWorkspaceFileSystemError.isDirectory(route.virtualPath)
            }
            try withRebasedMountErrors(mount) {
                guard let timestampingFileSystem = mount.fileSystem as? MSPWorkspaceFileTimestamping else {
                    try mount.fileSystem.touch(route.backendPath, from: "/")
                    return
                }
                try timestampingFileSystem.setModificationDate(
                    route.backendPath,
                    modificationDate: modificationDate,
                    from: "/"
                )
            }
        }
    }
}
