import Foundation
import ModelShellProxy

final class MSPPlaygroundMemoryFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy: MSPWorkspaceFileSystemPolicy

    private let lock = NSRecursiveLock()
    private var directories: Set<String>
    private var files: [String: Data]
    private var permissions: [String: UInt16]
    private var modificationDates: [String: Date]
    private let currentDate: @Sendable () -> Date

    init(
        files: [String: Data] = [:],
        policy: MSPWorkspaceFileSystemPolicy = MSPWorkspaceFileSystemPolicy(directoryOrdering: .name),
        modificationDate: Date = Date(),
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.currentDate = currentDate
        self.files = Dictionary(uniqueKeysWithValues: files.map { path, data in
            (MSPWorkspacePathResolver.normalize(path), data)
        })
        self.directories = ["/"]
        self.permissions = ["/": 0o755]
        self.modificationDates = ["/": modificationDate]
        for path in self.files.keys {
            permissions[path] = 0o644
            modificationDates[path] = modificationDate
            var parent = Self.parentPath(of: path)
            while parent != "/" {
                directories.insert(parent)
                permissions[parent] = 0o755
                modificationDates[parent] = modificationDate
                parent = Self.parentPath(of: parent)
            }
        }
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(
            virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        )
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        return try withLock {
            if directories.contains(virtualPath) {
                return MSPFileInfo(
                    virtualPath: virtualPath,
                    type: .directory,
                    modificationDate: modificationDates[virtualPath],
                    permissions: permissions[virtualPath] ?? 0o755
                )
            }
            if let data = files[virtualPath] {
                return MSPFileInfo(
                    virtualPath: virtualPath,
                    type: .regularFile,
                    size: Int64(data.count),
                    modificationDate: modificationDates[virtualPath],
                    permissions: permissions[virtualPath] ?? 0o644
                )
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        return try withLock {
            guard directories.contains(virtualPath) else {
                throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
            }
            let childPaths = Set(
                files.keys.filter { Self.parentPath(of: $0) == virtualPath }
                    + directories.filter { $0 != "/" && Self.parentPath(of: $0) == virtualPath }
            )
            return policy.directoryOrdering.ordered(try childPaths.map { childPath in
                MSPDirectoryEntry(name: Self.name(of: childPath), info: try stat(childPath, from: "/"))
            })
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(
            try resolve(path, from: currentDirectory).virtualPath
        )
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        return try withLock {
            if directories.contains(virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            guard let data = files[virtualPath] else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            return data
        }
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        try withLock {
            let parent = Self.parentPath(of: virtualPath)
            if options.contains(.createParentDirectories) {
                try createDirectory(parent, from: "/", intermediates: true)
            }
            guard directories.contains(parent) else {
                throw MSPWorkspaceFileSystemError.notDirectory(parent)
            }
            if directories.contains(virtualPath) {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            if files[virtualPath] != nil, !options.contains(.overwriteExisting) {
                throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
            }
            let existed = files[virtualPath] != nil
            let now = currentDate()
            files[virtualPath] = data
            permissions[virtualPath, default: 0o644] = permissions[virtualPath] ?? 0o644
            modificationDates[virtualPath] = now
            if !existed {
                modificationDates[parent] = now
            }
        }
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        try withLock {
            guard virtualPath != "/" else {
                return
            }
            let parent = Self.parentPath(of: virtualPath)
            if !directories.contains(parent) {
                guard intermediates else {
                    throw MSPWorkspaceFileSystemError.notDirectory(parent)
                }
                try createDirectory(parent, from: "/", intermediates: true)
            }
            if files[virtualPath] != nil {
                throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
            }
            let now = currentDate()
            directories.insert(virtualPath)
            permissions[virtualPath, default: 0o755] = permissions[virtualPath] ?? 0o755
            modificationDates[virtualPath] = now
            modificationDates[parent] = now
        }
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        try withLock {
            if files[virtualPath] != nil || directories.contains(virtualPath) {
                modificationDates[virtualPath] = currentDate()
            } else {
                try writeFile(
                    virtualPath,
                    data: Data(),
                    from: "/",
                    options: [.createParentDirectories]
                )
            }
        }
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        try withLock {
            if files.removeValue(forKey: virtualPath) != nil {
                permissions.removeValue(forKey: virtualPath)
                modificationDates.removeValue(forKey: virtualPath)
                modificationDates[Self.parentPath(of: virtualPath)] = currentDate()
                return
            }
            guard directories.contains(virtualPath), virtualPath != "/" else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            let childPrefix = virtualPath + "/"
            let hasChildren = files.keys.contains { $0.hasPrefix(childPrefix) }
                || directories.contains { $0 != virtualPath && $0.hasPrefix(childPrefix) }
            if hasChildren, !recursive {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            files = files.filter { !$0.key.hasPrefix(childPrefix) }
            directories = directories.filter { $0 == "/" || ($0 != virtualPath && !$0.hasPrefix(childPrefix)) }
            permissions = permissions.filter { key, _ in key == "/" || (key != virtualPath && !key.hasPrefix(childPrefix)) }
            modificationDates = modificationDates.filter { key, _ in key == "/" || (key != virtualPath && !key.hasPrefix(childPrefix)) }
            modificationDates[Self.parentPath(of: virtualPath)] = currentDate()
        }
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        let data = try readFile(sourcePath, from: currentDirectory)
        try writeFile(
            destinationPath,
            data: data,
            from: currentDirectory,
            options: options.contains(.overwriteExisting)
                ? [.overwriteExisting, .createParentDirectories]
                : [.createParentDirectories]
        )
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        try copy(
            sourcePath,
            to: destinationPath,
            from: currentDirectory,
            options: options.contains(.overwriteExisting) ? [.overwriteExisting] : []
        )
        try remove(sourcePath, from: currentDirectory, recursive: false)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try copy(sourcePath, to: linkPath, from: currentDirectory, options: [])
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(
            path: try resolve(linkPath, from: currentDirectory).virtualPath,
            operation: "symlink"
        )
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        try withLock {
            _ = try stat(virtualPath, from: "/")
            permissions[virtualPath] = mode & 0o777
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func parentPath(of path: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard normalized != "/" else {
            return "/"
        }
        let components = MSPWorkspacePathResolver.components(in: normalized).dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func name(of path: String) -> String {
        MSPWorkspacePathResolver.components(in: path).last ?? ""
    }
}
