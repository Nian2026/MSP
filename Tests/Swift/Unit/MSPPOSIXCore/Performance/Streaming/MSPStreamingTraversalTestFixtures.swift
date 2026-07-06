import Foundation
import MSPCore

struct StreamingTraversalWorkspace: MSPWorkspace {
    var rootPath: String { "/" }
    let fileSystem: any MSPWorkspaceFileSystem
}

final class StreamingTraversalFileSystem: MSPWorkspaceBatchDirectoryEnumerating, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private(set) var listDirectoryCallCount = 0
    private(set) var enumeratedDirectories: [String] = []
    private(set) var typedEnumerationOptions: [MSPDirectoryEnumerationOptions] = []
    private(set) var batchEnumeratedDirectories: [String] = []
    private(set) var batchEnumerationOptions: [MSPDirectoryEnumerationOptions] = []
    private(set) var batchSizes: [Int] = []
    private(set) var readFiles: [String] = []

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = normalize(path, from: currentDirectory)
        switch virtualPath {
        case "/":
            return directoryInfo("/")
        case "/album":
            return directoryInfo("/album")
        case "/empty":
            return directoryInfo("/empty")
        case "/album/a.jpg", "/album/b.jpg":
            return fileInfo(virtualPath)
        default:
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        listDirectoryCallCount += 1
        throw MSPWorkspaceFileSystemError.io(
            path: normalize(path, from: currentDirectory),
            operation: "eager-list-forbidden"
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        try await enumerateDirectory(
            path,
            from: currentDirectory,
            options: .all,
            visitor: visitor
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let virtualPath = normalize(path, from: currentDirectory)
        typedEnumerationOptions.append(options)
        enumeratedDirectories.append(virtualPath)
        for entry in try directoryEntries(in: virtualPath) where options.includes(entry.type) {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let virtualPath = normalize(path, from: currentDirectory)
        batchEnumeratedDirectories.append(virtualPath)
        batchEnumerationOptions.append(options)

        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        batch.reserveCapacity(resolvedBatchSize)
        for entry in try directoryEntries(in: virtualPath) where options.includes(entry.type) {
            batch.append(entry)
            if batch.count >= resolvedBatchSize {
                batchSizes.append(batch.count)
                guard try await visitor(batch) else {
                    return
                }
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            batchSizes.append(batch.count)
            _ = try await visitor(batch)
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(normalize(path, from: currentDirectory))
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = normalize(path, from: currentDirectory)
        readFiles.append(virtualPath)
        switch virtualPath {
        case "/album/a.jpg":
            return Data("alpha\nz\n".utf8)
        case "/album/b.jpg":
            return Data("beta\n".utf8)
        default:
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(destinationPath, from: currentDirectory))
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(destinationPath, from: currentDirectory))
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(linkPath, from: currentDirectory))
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(linkPath, from: currentDirectory))
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    private func directoryInfo(_ virtualPath: String) -> MSPFileInfo {
        MSPFileInfo(virtualPath: virtualPath, type: .directory, permissions: 0o755)
    }

    private func fileInfo(_ virtualPath: String) -> MSPFileInfo {
        MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: 1, permissions: 0o644)
    }

    private func directoryEntries(in virtualPath: String) throws -> [MSPDirectoryEntry] {
        switch virtualPath {
        case "/":
            return [
                MSPDirectoryEntry(name: "album", info: directoryInfo("/album")),
                MSPDirectoryEntry(name: "empty", info: directoryInfo("/empty"))
            ]
        case "/album":
            return [
                MSPDirectoryEntry(name: "a.jpg", info: fileInfo("/album/a.jpg")),
                MSPDirectoryEntry(name: "b.jpg", info: fileInfo("/album/b.jpg"))
            ]
        case "/empty":
            return []
        default:
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
    }

    private func normalize(_ path: String, from currentDirectory: String) -> String {
        MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
    }
}

final class ChunkedTestInputStream: MSPCommandInputStream {
    private let storage: ChunkedTestInputStorage

    init(chunks: [Data]) {
        self.storage = ChunkedTestInputStorage(chunks: chunks)
    }

    var readCount: Int {
        get async { await storage.readCount }
    }

    var didCloseRead: Bool {
        get async { await storage.didCloseRead }
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read()
    }

    func closeRead() async {
        await storage.closeRead()
    }
}

private actor ChunkedTestInputStorage {
    private var chunks: [Data]
    private(set) var readCount = 0
    private(set) var didCloseRead = false

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func read() -> Data? {
        guard !didCloseRead, !chunks.isEmpty else {
            return nil
        }
        readCount += 1
        return chunks.removeFirst()
    }

    func closeRead() {
        didCloseRead = true
    }
}
