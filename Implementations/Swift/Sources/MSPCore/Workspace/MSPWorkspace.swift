import Foundation

public protocol MSPWorkspace: Sendable {
    var rootPath: String { get }
    var fileSystem: any MSPWorkspaceFileSystem { get }
}

public protocol MSPWorkspaceFileSystem: Sendable {
    var policy: MSPWorkspaceFileSystemPolicy { get }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath
    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo
    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry]
    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws
    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String
    func readFile(_ path: String, from currentDirectory: String) throws -> Data
    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data
    func writeFile(_ path: String, data: Data, from currentDirectory: String, options: MSPFileWriteOptions) throws
    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws
    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws
    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws
    func createDirectory(
        _ path: String,
        from currentDirectory: String,
        intermediates: Bool,
        creationMode: UInt16?
    ) throws
    func touch(_ path: String, from currentDirectory: String) throws
    func touch(_ path: String, from currentDirectory: String, creationMode: UInt16?) throws
    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws
    func copy(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileCopyOptions) throws
    func move(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileMoveOptions) throws
    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws
    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws
    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws
}

public protocol MSPWorkspaceSequentialFileReader: Sendable {
    func read(upToCount count: Int) throws -> Data?
    func close() throws
}

public protocol MSPWorkspaceSequentialFileReading: MSPWorkspaceFileSystem {
    func openSequentialFileReader(
        _ path: String,
        from currentDirectory: String
    ) throws -> (any MSPWorkspaceSequentialFileReader)?
}

public protocol MSPWorkspaceTypedDirectoryEnumerating: MSPWorkspaceFileSystem {
    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws
}

public protocol MSPWorkspaceBatchDirectoryEnumerating: MSPWorkspaceTypedDirectoryEnumerating {
    func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws
}

public extension MSPWorkspaceBatchDirectoryEnumerating {
    func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        batch.reserveCapacity(resolvedBatchSize)
        var shouldContinue = true
        try await enumerateDirectory(
            path,
            from: currentDirectory,
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

public protocol MSPWorkspaceBatchCopying: MSPWorkspaceFileSystem {
    func copy(
        _ requests: [MSPFileCopyRequest],
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws
}

public extension MSPWorkspaceBatchCopying {
    func copy(
        _ requests: [MSPFileCopyRequest],
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        for request in requests {
            try copy(
                request.sourcePath,
                to: request.destinationPath,
                from: currentDirectory,
                options: options
            )
        }
    }
}

public protocol MSPWorkspaceFileTimestamping: MSPWorkspaceFileSystem {
    func setModificationDate(
        _ path: String,
        modificationDate: Date,
        from currentDirectory: String
    ) throws
}

public extension MSPWorkspaceFileSystem {
    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        let resolved = try resolve(path, from: currentDirectory)
        let existed = (try? stat(resolved.virtualPath, from: "/")) != nil
        try writeFile(path, data: data, from: currentDirectory, options: options)
        if !existed, let creationMode {
            try? chmod(resolved.virtualPath, mode: creationMode & 0o777, from: "/")
        }
    }

    func createDirectory(
        _ path: String,
        from currentDirectory: String,
        intermediates: Bool,
        creationMode: UInt16?
    ) throws {
        let resolved = try resolve(path, from: currentDirectory)
        let existed = (try? stat(resolved.virtualPath, from: "/")) != nil
        try createDirectory(path, from: currentDirectory, intermediates: intermediates)
        if !existed, let creationMode {
            try? chmod(resolved.virtualPath, mode: creationMode & 0o777, from: "/")
        }
    }

    func touch(_ path: String, from currentDirectory: String, creationMode: UInt16?) throws {
        do {
            _ = try stat(path, from: currentDirectory)
            try touch(path, from: currentDirectory)
        } catch MSPWorkspaceFileSystemError.notFound {
            try writeFile(
                path,
                data: Data(),
                from: currentDirectory,
                options: [.overwriteExisting],
                creationMode: creationMode
            )
        }
    }

    func enumerateDirectory(
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

    func resolve(_ path: String) throws -> MSPResolvedPath {
        try resolve(path, from: "/")
    }

    func stat(_ path: String) throws -> MSPFileInfo {
        try stat(path, from: "/")
    }

    func listDirectory(_ path: String) throws -> [MSPDirectoryEntry] {
        try listDirectory(path, from: "/")
    }

    func readFile(_ path: String) throws -> Data {
        try readFile(path, from: "/")
    }

    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data {
        let resolved = try resolve(path, from: currentDirectory)
        let data = try readFile(resolved.virtualPath, from: "/")
        guard length > 0, offset < UInt64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func readFileRange(_ path: String, offset: UInt64, length: Int) throws -> Data {
        try readFileRange(path, from: "/", offset: offset, length: length)
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions = [.createParentDirectories],
        creationMode: UInt16? = nil
    ) throws {
        let resolved = try resolve(path, from: currentDirectory)
        let existed = (try? stat(resolved.virtualPath, from: "/")) != nil
        var combined = Data()
        if existed {
            combined = try readFile(resolved.virtualPath, from: "/")
        }
        combined.append(data)
        try writeFile(
            resolved.virtualPath,
            data: combined,
            from: "/",
            options: options.union(.overwriteExisting),
            creationMode: existed ? nil : creationMode
        )
    }

    func readSymbolicLink(_ path: String) throws -> String {
        try readSymbolicLink(path, from: "/")
    }

    func readTextFile(
        _ path: String,
        from currentDirectory: String = "/",
        encoding: String.Encoding = .utf8
    ) throws -> String {
        let resolved = try resolve(path, from: currentDirectory)
        let data = try readFile(resolved.virtualPath, from: "/")
        guard let text = String(data: data, encoding: encoding) else {
            throw MSPWorkspaceFileSystemError.encodingFailed(resolved.virtualPath)
        }
        return text
    }

    func writeFile(
        _ path: String,
        data: Data,
        options: MSPFileWriteOptions = [.overwriteExisting]
    ) throws {
        try writeFile(path, data: data, from: "/", options: options)
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String
    ) throws {
        try writeFile(path, data: data, from: currentDirectory, options: [.overwriteExisting])
    }

    func writeTextFile(
        _ path: String,
        contents: String,
        from currentDirectory: String = "/",
        encoding: String.Encoding = .utf8,
        options: MSPFileWriteOptions = [.overwriteExisting]
    ) throws {
        let resolved = try resolve(path, from: currentDirectory)
        guard let data = contents.data(using: encoding) else {
            throw MSPWorkspaceFileSystemError.encodingFailed(resolved.virtualPath)
        }
        try writeFile(resolved.virtualPath, data: data, from: "/", options: options)
    }

    func createDirectory(
        _ path: String,
        intermediates: Bool = false
    ) throws {
        try createDirectory(path, from: "/", intermediates: intermediates)
    }

    func createDirectory(_ path: String, from currentDirectory: String) throws {
        try createDirectory(path, from: currentDirectory, intermediates: false)
    }

    func touch(_ path: String) throws {
        try touch(path, from: "/")
    }

    func remove(_ path: String, recursive: Bool = false) throws {
        try remove(path, from: "/", recursive: recursive)
    }

    func remove(_ path: String, from currentDirectory: String) throws {
        try remove(path, from: currentDirectory, recursive: false)
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        options: MSPFileCopyOptions = []
    ) throws {
        try copy(sourcePath, to: destinationPath, from: "/", options: options)
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String
    ) throws {
        try copy(sourcePath, to: destinationPath, from: currentDirectory, options: [])
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        options: MSPFileMoveOptions = [.overwriteExisting]
    ) throws {
        try move(sourcePath, to: destinationPath, from: "/", options: options)
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String
    ) throws {
        try move(sourcePath, to: destinationPath, from: currentDirectory, options: [.overwriteExisting])
    }

    func createSymbolicLink(target: String, at linkPath: String) throws {
        try createSymbolicLink(target: target, at: linkPath, from: "/")
    }

    func createHardLink(source sourcePath: String, at linkPath: String) throws {
        try createHardLink(source: sourcePath, at: linkPath, from: "/")
    }

    func chmod(_ path: String, mode: UInt16) throws {
        try chmod(path, mode: mode, from: "/")
    }
}

public extension MSPWorkspaceFileSystem {
    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: linkPath, operation: "link")
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: linkPath, operation: "symlink")
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "chmod")
    }
}
