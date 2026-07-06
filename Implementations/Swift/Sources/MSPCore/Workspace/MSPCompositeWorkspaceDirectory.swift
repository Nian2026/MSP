import Foundation

extension MSPCompositeWorkspaceFileSystem {
    public func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            return try baseDirectoryEntries(at: route.virtualPath)
        case .mount(let mount):
            let entries = try withRebasedMountErrors(mount) {
                try mount.fileSystem.listDirectory(route.backendPath, from: "/")
            }
            return policy.directoryOrdering.ordered(entries.map { rebaseEntry($0, mountPath: mount.path) })
        }
    }

    public func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        for entry in try listDirectory(path, from: currentDirectory) {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    public func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            for entry in try baseDirectoryEntries(at: route.virtualPath) where options.includes(entry.type) {
                guard try await visitor(entry) else {
                    return
                }
            }
        case .mount(let mount):
            if let typedFileSystem = mount.fileSystem as? any MSPWorkspaceTypedDirectoryEnumerating {
                do {
                    try await typedFileSystem.enumerateDirectory(
                        route.backendPath,
                        from: "/",
                        options: options
                    ) { entry in
                        try await visitor(rebaseEntry(entry, mountPath: mount.path))
                    }
                } catch {
                    throw rebaseMountedError(error, mountPath: mount.path)
                }
                return
            }
            let entries = try withRebasedMountErrors(mount) {
                try mount.fileSystem.listDirectory(route.backendPath, from: "/")
            }
            for entry in entries.map({ rebaseEntry($0, mountPath: mount.path) }) where options.includes(entry.type) {
                guard try await visitor(entry) else {
                    return
                }
            }
        }
    }

    public func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let route = try route(path, from: currentDirectory)
        switch route.backend {
        case .base:
            let resolvedBatchSize = max(1, batchSize)
            var batch: [MSPDirectoryEntry] = []
            batch.reserveCapacity(resolvedBatchSize)
            var shouldContinue = true
            for entry in try baseDirectoryEntries(at: route.virtualPath) where options.includes(entry.type) {
                batch.append(entry)
                if batch.count >= resolvedBatchSize {
                    shouldContinue = try await visitor(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                if !shouldContinue {
                    return
                }
            }
            if shouldContinue, !batch.isEmpty {
                _ = try await visitor(batch)
            }
        case .mount(let mount):
            if let batchFileSystem = mount.fileSystem as? any MSPWorkspaceBatchDirectoryEnumerating {
                do {
                    try await batchFileSystem.enumerateDirectoryBatches(
                        route.backendPath,
                        from: "/",
                        options: options,
                        batchSize: batchSize
                    ) { entries in
                        try await visitor(entries.map { rebaseEntry($0, mountPath: mount.path) })
                    }
                } catch {
                    throw rebaseMountedError(error, mountPath: mount.path)
                }
                return
            }
            let resolvedBatchSize = max(1, batchSize)
            var batch: [MSPDirectoryEntry] = []
            batch.reserveCapacity(resolvedBatchSize)
            var shouldContinue = true
            try await enumerateDirectory(
                route.virtualPath,
                from: "/",
                options: options
            ) { entry in
                batch.append(entry)
                if batch.count >= resolvedBatchSize {
                    shouldContinue = try await visitor(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                return shouldContinue
            }
            if shouldContinue, !batch.isEmpty {
                _ = try await visitor(batch)
            }
        }
    }

    var mountPaths: Set<String> {
        Set(mounts.map(\.path))
    }

    func baseDirectoryEntries(at virtualPath: String) throws -> [MSPDirectoryEntry] {
        let baseEntries: [MSPDirectoryEntry]
        do {
            baseEntries = try baseFileSystem.listDirectory(virtualPath, from: "/")
                .filter { !mountPaths.contains($0.info.virtualPath) }
        } catch MSPWorkspaceFileSystemError.notFound where isSyntheticMountDirectory(virtualPath) {
            baseEntries = []
        }

        let basePaths = Set(baseEntries.map(\.info.virtualPath))
        let visibleMountEntries = mountEntries(in: virtualPath)
            .filter { !basePaths.contains($0.info.virtualPath) }
        return policy.directoryOrdering.ordered(baseEntries + visibleMountEntries)
    }

    func mountEntries(in directoryPath: String) -> [MSPDirectoryEntry] {
        var entriesByPath: [String: MSPDirectoryEntry] = [:]
        for mount in mounts {
            guard let childPath = mountChildPath(for: mount.path, in: directoryPath),
                  !policy.isHidden(childPath)
            else {
                continue
            }
            entriesByPath[childPath] = MSPDirectoryEntry(
                name: name(of: childPath),
                info: childPath == mount.path
                    ? mountedRootInfo(for: mount)
                    : syntheticMountDirectoryInfo(childPath)
            )
        }
        return Array(entriesByPath.values)
    }

    func mountedRootInfo(for mount: MSPWorkspaceMount) -> MSPFileInfo {
        do {
            return try rebaseInfo(mount.fileSystem.stat("/", from: "/"), mountPath: mount.path)
        } catch {
            return MSPFileInfo(virtualPath: mount.path, type: .directory, permissions: 0o755)
        }
    }

    func syntheticMountDirectoryInfo(_ virtualPath: String) -> MSPFileInfo {
        let normalized = MSPWorkspacePathResolver.normalize(virtualPath)
        let modificationDate = mounts
            .filter { mount in
                mount.path == normalized || mount.path.hasPrefix(normalized + "/")
            }
            .compactMap { mount in
                try? mount.fileSystem.stat("/", from: "/").modificationDate
            }
            .max()
        return MSPFileInfo(
            virtualPath: normalized,
            type: .directory,
            modificationDate: modificationDate,
            permissions: 0o755
        )
    }

    func mountChildPath(for mountPath: String, in directoryPath: String) -> String? {
        let directoryPath = MSPWorkspacePathResolver.normalize(directoryPath)
        let mountPath = MSPWorkspacePathResolver.normalize(mountPath)
        if directoryPath == "/" {
            guard let first = MSPWorkspacePathResolver.components(in: mountPath).first else {
                return nil
            }
            return "/" + first
        }
        guard mountPath.hasPrefix(directoryPath + "/") else {
            return nil
        }
        let remainderStart = mountPath.index(mountPath.startIndex, offsetBy: directoryPath.count + 1)
        let remainder = mountPath[remainderStart...]
        guard let first = remainder.split(separator: "/").first else {
            return nil
        }
        return directoryPath + "/" + first
    }

    func isSyntheticMountDirectory(_ virtualPath: String) -> Bool {
        !mountEntries(in: virtualPath).isEmpty
    }

    func name(of path: String) -> String {
        MSPWorkspacePathResolver.components(in: path).last ?? ""
    }
}
