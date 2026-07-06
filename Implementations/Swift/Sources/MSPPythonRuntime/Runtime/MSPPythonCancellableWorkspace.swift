import Foundation
import MSPCore

final class MSPPythonSubprocessCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    func performMutation<T>(
        path: String,
        _ body: () throws -> T
    ) throws -> T {
        try lock.withLock {
            guard !cancelled else {
                throw MSPWorkspaceFileSystemError.accessDenied(path)
            }
            return try body()
        }
    }

    func throwIfCancelled(path: String) throws {
        if isCancelled {
            throw MSPWorkspaceFileSystemError.accessDenied(path)
        }
    }
}

final class MSPPythonCancellableWorkspace: MSPWorkspace, @unchecked Sendable {
    private let base: any MSPWorkspace
    private let cancellationToken: MSPPythonSubprocessCancellationToken

    init(
        base: any MSPWorkspace,
        cancellationToken: MSPPythonSubprocessCancellationToken
    ) {
        self.base = base
        self.cancellationToken = cancellationToken
    }

    var rootPath: String {
        base.rootPath
    }

    var fileSystem: any MSPWorkspaceFileSystem {
        MSPPythonCancellableWorkspaceFileSystem(
            base: base.fileSystem,
            cancellationToken: cancellationToken
        )
    }
}

private final class MSPPythonCancellableWorkspaceFileSystem: MSPWorkspaceTypedDirectoryEnumerating, MSPWorkspaceFileTimestamping, @unchecked Sendable {
    private let base: any MSPWorkspaceFileSystem
    private let cancellationToken: MSPPythonSubprocessCancellationToken

    init(
        base: any MSPWorkspaceFileSystem,
        cancellationToken: MSPPythonSubprocessCancellationToken
    ) {
        self.base = base
        self.cancellationToken = cancellationToken
    }

    var policy: MSPWorkspaceFileSystemPolicy {
        base.policy
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        try base.resolve(path, from: currentDirectory)
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        try base.stat(path, from: currentDirectory)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        try base.listDirectory(path, from: currentDirectory)
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        if let typedBase = base as? any MSPWorkspaceTypedDirectoryEnumerating {
            try await typedBase.enumerateDirectory(path, from: currentDirectory, options: options, visitor: visitor)
            return
        }
        for entry in try base.listDirectory(path, from: currentDirectory) where options.includes(entry.type) {
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
        try cancellationToken.performMutation(path: path) {
            try base.writeFile(path, data: data, from: currentDirectory, options: options)
        }
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        try cancellationToken.performMutation(path: path) {
            try base.appendFile(
                path,
                data: data,
                from: currentDirectory,
                options: options,
                creationMode: creationMode
            )
        }
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        try cancellationToken.performMutation(path: path) {
            try base.writeFile(
                path,
                data: data,
                from: currentDirectory,
                options: options,
                creationMode: creationMode
            )
        }
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        try cancellationToken.performMutation(path: path) {
            try base.createDirectory(path, from: currentDirectory, intermediates: intermediates)
        }
    }

    func createDirectory(
        _ path: String,
        from currentDirectory: String,
        intermediates: Bool,
        creationMode: UInt16?
    ) throws {
        try cancellationToken.performMutation(path: path) {
            try base.createDirectory(
                path,
                from: currentDirectory,
                intermediates: intermediates,
                creationMode: creationMode
            )
        }
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        try cancellationToken.performMutation(path: path) {
            try base.touch(path, from: currentDirectory)
        }
    }

    func touch(_ path: String, from currentDirectory: String, creationMode: UInt16?) throws {
        try cancellationToken.performMutation(path: path) {
            try base.touch(path, from: currentDirectory, creationMode: creationMode)
        }
    }

    func setModificationDate(
        _ path: String,
        modificationDate: Date,
        from currentDirectory: String
    ) throws {
        try cancellationToken.performMutation(path: path) {
            guard let timestampingFileSystem = base as? MSPWorkspaceFileTimestamping else {
                try base.touch(path, from: currentDirectory)
                return
            }
            try timestampingFileSystem.setModificationDate(
                path,
                modificationDate: modificationDate,
                from: currentDirectory
            )
        }
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        try cancellationToken.performMutation(path: path) {
            try base.remove(path, from: currentDirectory, recursive: recursive)
        }
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        try cancellationToken.performMutation(path: destinationPath) {
            try base.copy(sourcePath, to: destinationPath, from: currentDirectory, options: options)
        }
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        try cancellationToken.performMutation(path: destinationPath) {
            try base.move(sourcePath, to: destinationPath, from: currentDirectory, options: options)
        }
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try cancellationToken.performMutation(path: linkPath) {
            try base.createHardLink(source: sourcePath, at: linkPath, from: currentDirectory)
        }
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        try cancellationToken.performMutation(path: linkPath) {
            try base.createSymbolicLink(target: target, at: linkPath, from: currentDirectory)
        }
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        try cancellationToken.performMutation(path: path) {
            try base.chmod(path, mode: mode, from: currentDirectory)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
