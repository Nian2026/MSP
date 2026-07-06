import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPFilesystemCommandTests: XCTestCase {
    func testMissingSourceDiagnosticsMatchGNUCoreutils() async throws {
        let workspace = MissingSourceWorkspace()

        let cp = await runCommand("cp", ["missing", "b"], workspace: workspace)
        let mv = await runCommand("mv", ["missing", "b"], workspace: workspace)

        XCTAssertEqual(cp.stdout, "")
        XCTAssertEqual(cp.stderr, "cp: cannot stat 'missing': No such file or directory\n")
        XCTAssertEqual(cp.exitCode, 1)

        XCTAssertEqual(mv.stdout, "")
        XCTAssertEqual(mv.stderr, "mv: cannot stat 'missing': No such file or directory\n")
        XCTAssertEqual(mv.exitCode, 1)
    }

    func testLsLongFormatUsesLinuxMetadataColumnsAndDirectoryTotal() async throws {
        let epoch = Date(timeIntervalSince1970: 0)
        let workspace = LongListingWorkspace(entries: [
            "/": .directory(permissions: 0o755, modificationDate: epoch),
            "/docs": .directory(permissions: 0o755, modificationDate: epoch),
            "/docs/a.txt": .file(size: 3, permissions: 0o640, modificationDate: epoch),
            "/docs/link.txt": .symlink(target: "a.txt", modificationDate: epoch)
        ])

        let result = await runCommand("ls", ["-la", "/docs"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            total 12
            drwxr-xr-x 2 nobody nogroup 4096 Jan  1  1970 .
            drwxr-xr-x 3 nobody nogroup 4096 Jan  1  1970 ..
            -rw-r----- 1 nobody nogroup    3 Jan  1  1970 a.txt
            lrwxrwxrwx 1 nobody nogroup    5 Jan  1  1970 link.txt -> a.txt

            """
        )
    }

    private func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: any MSPWorkspace
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(workspace: workspace)
        )
    }
}

private struct MissingSourceWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem = MissingSourceFileSystem()
}

private struct LongListingWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(entries: [String: LongListingEntry]) {
        fileSystem = LongListingFileSystem(entries: entries)
    }
}

private enum LongListingEntry {
    case file(size: Int64, permissions: UInt16, modificationDate: Date?)
    case directory(permissions: UInt16, modificationDate: Date?)
    case symlink(target: String, modificationDate: Date?)
}

private final class LongListingFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    let entries: [String: LongListingEntry]

    init(entries: [String: LongListingEntry]) {
        self.entries = entries
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        switch entry {
        case .file(let size, let permissions, let modificationDate):
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .regularFile,
                size: size,
                modificationDate: modificationDate,
                permissions: permissions
            )
        case .directory(let permissions, let modificationDate):
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .directory,
                modificationDate: modificationDate,
                permissions: permissions
            )
        case .symlink(let target, let modificationDate):
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .symbolicLink,
                modificationDate: modificationDate,
                permissions: 0o777,
                symbolicLinkTarget: target
            )
        }
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
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

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard case .symlink(let target, _) = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
        }
        return target
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard case .file(let size, _, _) = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        return Data(repeating: 0, count: Int(size))
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "write")
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "mkdir")
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "touch")
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "remove")
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "copy")
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "move")
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
}

private struct MissingSourceFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPFileInfo(virtualPath: "/", type: .directory)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "readlink")
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "read")
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "write")
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "mkdir")
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "touch")
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "remove")
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "copy")
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "move")
    }
}
