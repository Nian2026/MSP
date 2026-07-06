import Foundation
import MSPCore

extension MSPCore100FilesystemCommandTests {
    func context(_ workspace: Core100FilesystemTestWorkspace) -> MSPCommandContext {
        MSPCommandContext(workspace: workspace, currentDirectory: "/")
    }
}

struct Core100FilesystemTestWorkspace: MSPWorkspace {
    var rootPath: String { "/" }
    let fileSystem: any MSPWorkspaceFileSystem
    let fileSystemBox: Core100FilesystemTestFileSystem

    init(entries: [String: Core100FilesystemTestEntry]) {
        let fileSystem = Core100FilesystemTestFileSystem(entries: entries)
        self.fileSystem = fileSystem
        self.fileSystemBox = fileSystem
    }
}

enum Core100FilesystemTestEntry {
    case file(Data, mode: UInt16)
    case directory(mode: UInt16)
    case symlink(target: String)
}

final class Core100FilesystemTestFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var entries: [String: Core100FilesystemTestEntry]
    private(set) var listDirectoryCallCount = 0
    private(set) var enumeratedDirectories: [String] = []

    init(entries: [String: Core100FilesystemTestEntry]) {
        self.entries = entries
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = normalize(path, from: currentDirectory)
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        switch entry {
        case .file(let data, let mode):
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .regularFile,
                size: Int64(data.count),
                permissions: mode
            )
        case .directory(let mode):
            return MSPFileInfo(virtualPath: virtualPath, type: .directory, permissions: mode)
        case .symlink(let target):
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .symbolicLink,
                permissions: 0o777,
                symbolicLinkTarget: target
            )
        }
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        listDirectoryCallCount += 1
        return try directoryEntries(path, from: currentDirectory)
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let virtualPath = normalize(path, from: currentDirectory)
        enumeratedDirectories.append(virtualPath)
        for entry in try directoryEntries(virtualPath, from: "/") {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = normalize(path, from: currentDirectory)
        guard case .symlink(let target) = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
        }
        return target
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = normalize(path, from: currentDirectory)
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        switch entry {
        case .file(let data, _):
            return data
        case .directory:
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        case .symlink(let target):
            let parent = parentPath(of: virtualPath)
            return try readFile(join(parent: parent, child: target), from: "/")
        }
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let virtualPath = normalize(path, from: currentDirectory)
        let parent = parentPath(of: virtualPath)
        guard case .directory = entries[parent] else {
            throw MSPWorkspaceFileSystemError.notDirectory(parent)
        }
        if case .directory = entries[virtualPath] {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        if entries[virtualPath] != nil, !options.contains(.overwriteExisting) {
            throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
        }
        let existingMode = mode(virtualPath)
        entries[virtualPath] = .file(data, mode: existingMode ?? 0o644)
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = normalize(path, from: currentDirectory)
        if entries[virtualPath] != nil {
            guard case .directory = entries[virtualPath] else {
                throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
            }
            return
        }
        let parent = parentPath(of: virtualPath)
        if intermediates, entries[parent] == nil {
            try createDirectory(parent, from: "/", intermediates: true)
        }
        guard case .directory = entries[parent] else {
            throw MSPWorkspaceFileSystemError.notDirectory(parent)
        }
        entries[virtualPath] = .directory(mode: 0o755)
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = normalize(path, from: currentDirectory)
        if entries[virtualPath] == nil {
            entries[virtualPath] = .file(Data(), mode: 0o644)
        }
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = normalize(path, from: currentDirectory)
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        if case .directory = entry, !recursive {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        entries = entries.filter { key, _ in
            key != virtualPath && !key.hasPrefix(virtualPath + "/")
        }
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: destinationPath, operation: "copy")
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: destinationPath, operation: "move")
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: linkPath, operation: "link")
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        let virtualPath = normalize(linkPath, from: currentDirectory)
        entries[virtualPath] = .symlink(target: target)
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        let virtualPath = normalize(path, from: currentDirectory)
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        switch entry {
        case .file(let data, _):
            entries[virtualPath] = .file(data, mode: mode & 0o777)
        case .directory:
            entries[virtualPath] = .directory(mode: mode & 0o777)
        case .symlink:
            break
        }
    }

    func fileData(_ path: String) -> Data? {
        guard case .file(let data, _) = entries[path] else {
            return nil
        }
        return data
    }

    func mode(_ path: String) -> UInt16? {
        guard let entry = entries[path] else {
            return nil
        }
        switch entry {
        case .file(_, let mode), .directory(let mode):
            return mode
        case .symlink:
            return 0o777
        }
    }

    private func directoryEntries(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = normalize(path, from: currentDirectory)
        guard case .directory = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        return try entries.keys
            .filter { parentPath(of: $0) == virtualPath && $0 != virtualPath }
            .sorted()
            .map { childPath in
                MSPDirectoryEntry(
                    name: basename(childPath),
                    info: try stat(childPath, from: "/")
                )
            }
    }

    private func normalize(_ path: String, from currentDirectory: String) -> String {
        MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
    }

    private func parentPath(of path: String) -> String {
        let components = MSPWorkspacePathResolver.components(in: path)
        guard components.count > 1 else {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private func basename(_ path: String) -> String {
        MSPWorkspacePathResolver.components(in: path).last ?? path
    }

    private func join(parent: String, child: String) -> String {
        child.hasPrefix("/") ? child : (parent == "/" ? "/" + child : parent + "/" + child)
    }
}
