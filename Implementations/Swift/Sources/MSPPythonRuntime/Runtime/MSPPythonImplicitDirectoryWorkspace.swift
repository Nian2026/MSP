import Foundation
import MSPCore

final class MSPPythonImplicitDirectoryWorkspace: MSPWorkspace, @unchecked Sendable {
    private let base: any MSPWorkspace

    init(base: any MSPWorkspace) {
        self.base = base
    }

    var rootPath: String {
        base.rootPath
    }

    var fileSystem: any MSPWorkspaceFileSystem {
        MSPPythonImplicitDirectoryFileSystem(base: base.fileSystem)
    }
}

final class MSPPythonImplicitDirectoryFileSystem: MSPWorkspaceTypedDirectoryEnumerating, MSPWorkspaceFileTimestamping, @unchecked Sendable {
    private static let implicitDirectoryPaths: Set<String> = ["/tmp"]

    private let base: any MSPWorkspaceFileSystem

    init(base: any MSPWorkspaceFileSystem) {
        self.base = base
    }

    var policy: MSPWorkspaceFileSystemPolicy {
        base.policy
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        try base.resolve(path, from: currentDirectory)
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        do {
            return try base.stat(path, from: currentDirectory)
        } catch MSPWorkspaceFileSystemError.notFound {
            let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
            if let info = Self.implicitDirectoryInfo(virtualPath) {
                return info
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        do {
            return addingImplicitRootEntries(
                try base.listDirectory(path, from: currentDirectory),
                for: virtualPath
            )
        } catch MSPWorkspaceFileSystemError.notFound where Self.isImplicitDirectoryPath(virtualPath) {
            return []
        }
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        if let typedBase = base as? any MSPWorkspaceTypedDirectoryEnumerating {
            let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
            var emitted = Set<String>()
            var shouldContinue = true
            do {
                try await typedBase.enumerateDirectory(path, from: currentDirectory, options: options) { entry in
                    emitted.insert(entry.name)
                    shouldContinue = try await visitor(entry)
                    return shouldContinue
                }
            } catch MSPWorkspaceFileSystemError.notFound where Self.isImplicitDirectoryPath(virtualPath) {
                return
            }
            if virtualPath == "/",
               shouldContinue,
               !emitted.contains("tmp"),
               options.includes(.directory),
               let info = Self.implicitDirectoryInfo("/tmp") {
                _ = try await visitor(MSPDirectoryEntry(name: "tmp", info: info))
            }
            return
        }
        for entry in try listDirectory(path, from: currentDirectory) where options.includes(entry.type) {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        try base.readSymbolicLink(path, from: currentDirectory)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        try base.readFile(path, from: currentDirectory)
    }

    func readFileRange(
        _ path: String,
        from currentDirectory: String,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        try base.readFileRange(path, from: currentDirectory, offset: offset, length: length)
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: path, from: currentDirectory)
        try base.writeFile(path, data: data, from: currentDirectory, options: options)
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: path, from: currentDirectory)
        try base.appendFile(
            path,
            data: data,
            from: currentDirectory,
            options: options,
            creationMode: creationMode
        )
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: path, from: currentDirectory)
        try base.writeFile(
            path,
            data: data,
            from: currentDirectory,
            options: options,
            creationMode: creationMode
        )
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        try createDirectory(path, from: currentDirectory, intermediates: intermediates, creationMode: nil)
    }

    func createDirectory(
        _ path: String,
        from currentDirectory: String,
        intermediates: Bool,
        creationMode: UInt16?
    ) throws {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if Self.isImplicitDirectoryPath(virtualPath) {
            if let info = try? base.stat(virtualPath, from: "/"),
               info.type != .directory {
                throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
            }
            if (try? base.stat(virtualPath, from: "/")) == nil {
                try? base.createDirectory(
                    virtualPath,
                    from: "/",
                    intermediates: true,
                    creationMode: creationMode ?? 0o777
                )
            }
            throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
        }
        try ensureImplicitParentDirectoryIfNeeded(for: path, from: currentDirectory)
        try base.createDirectory(
            path,
            from: currentDirectory,
            intermediates: intermediates,
            creationMode: creationMode
        )
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: path, from: currentDirectory)
        try base.touch(path, from: currentDirectory)
    }

    func touch(_ path: String, from currentDirectory: String, creationMode: UInt16?) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: path, from: currentDirectory)
        try base.touch(path, from: currentDirectory, creationMode: creationMode)
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        try base.remove(path, from: currentDirectory, recursive: recursive)
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: destinationPath, from: currentDirectory)
        try base.copy(sourcePath, to: destinationPath, from: currentDirectory, options: options)
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: destinationPath, from: currentDirectory)
        try base.move(sourcePath, to: destinationPath, from: currentDirectory, options: options)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: linkPath, from: currentDirectory)
        try base.createHardLink(source: sourcePath, at: linkPath, from: currentDirectory)
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        try ensureImplicitParentDirectoryIfNeeded(for: linkPath, from: currentDirectory)
        try base.createSymbolicLink(target: target, at: linkPath, from: currentDirectory)
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        try base.chmod(path, mode: mode, from: currentDirectory)
    }

    func setModificationDate(
        _ path: String,
        modificationDate: Date,
        from currentDirectory: String
    ) throws {
        guard let timestampingFileSystem = base as? MSPWorkspaceFileTimestamping else {
            try touch(path, from: currentDirectory)
            return
        }
        try timestampingFileSystem.setModificationDate(
            path,
            modificationDate: modificationDate,
            from: currentDirectory
        )
    }

    private static func isImplicitDirectoryPath(_ path: String) -> Bool {
        implicitDirectoryPaths.contains(MSPWorkspacePathResolver.normalize(path))
    }

    private static func implicitDirectoryInfo(_ path: String) -> MSPFileInfo? {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard isImplicitDirectoryPath(normalized) else {
            return nil
        }
        return MSPFileInfo(
            virtualPath: normalized,
            type: .directory,
            size: 0,
            permissions: 0o777,
            fileIdentity: "msp-python-implicit-directory:\(normalized)"
        )
    }

    private func addingImplicitRootEntries(
        _ entries: [MSPDirectoryEntry],
        for virtualPath: String
    ) -> [MSPDirectoryEntry] {
        guard virtualPath == "/",
              !entries.contains(where: { $0.name == "tmp" }),
              let info = Self.implicitDirectoryInfo("/tmp") else {
            return entries
        }
        return entries + [MSPDirectoryEntry(name: "tmp", info: info)]
    }

    private func ensureImplicitParentDirectoryIfNeeded(
        for path: String,
        from currentDirectory: String
    ) throws {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        let parentVirtualPath = parentPath(of: virtualPath)
        guard Self.isImplicitDirectoryPath(parentVirtualPath) else {
            return
        }
        do {
            let info = try base.stat(parentVirtualPath, from: "/")
            guard info.type == .directory else {
                throw MSPWorkspaceFileSystemError.notDirectory(parentVirtualPath)
            }
        } catch MSPWorkspaceFileSystemError.notFound {
            try base.createDirectory(
                parentVirtualPath,
                from: "/",
                intermediates: true,
                creationMode: 0o777
            )
        }
    }

    private func parentPath(of path: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard normalized != "/" else {
            return "/"
        }
        let components = MSPWorkspacePathResolver.components(in: normalized)
        guard components.count > 1 else {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }
}
