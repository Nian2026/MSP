import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPGrepCommandTests: XCTestCase {
    func testPatternFileCanBeReadFromStandardInput() async throws {
        let workspace = GrepTestWorkspace(files: [
            "/haystack.txt": Data("alpha\nbeta\n".utf8)
        ])

        let result = try await runGrep(
            ["-f", "-", "/haystack.txt"],
            workspace: workspace,
            standardInput: Data("alpha\n".utf8)
        )

        XCTAssertEqual(result.stdout, "alpha\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPatternFileStandardInputIsNotReusedAsImplicitSearchInput() async throws {
        let result = try await runGrep(["-f", "-"], standardInput: Data("alpha\n".utf8))

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 1)
    }

    func testExcludeFromCanBeReadFromStandardInput() async throws {
        let workspace = GrepTestWorkspace(files: [
            "/tree/a.txt": Data("hit\n".utf8),
            "/tree/b.log": Data("hit\n".utf8)
        ])

        let result = try await runGrep(
            ["-r", "--exclude-from=-", "hit", "/tree"],
            workspace: workspace,
            standardInput: Data("*.log\n".utf8)
        )

        XCTAssertEqual(result.stdout, "/tree/a.txt:hit\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    private func runGrep(
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        standardInput: Data = Data()
    ) async throws -> MSPCommandResult {
        try await MSPGrepCommand().run(
            invocation: MSPCommandInvocation(name: "grep", arguments: arguments),
            context: MSPCommandContext(workspace: workspace, standardInput: standardInput)
        )
    }
}

private struct GrepTestWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = GrepTestFileSystem(files: files)
    }
}

private struct GrepTestFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    let files: [String: Data]

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
        if files[virtualPath] != nil {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile)
        }
        if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        let prefix = virtualPath == "/" ? "/" : virtualPath + "/"
        var entriesByName: [String: MSPDirectoryEntry] = [:]
        for filePath in files.keys where filePath.hasPrefix(prefix) {
            let remainder = String(filePath.dropFirst(prefix.count))
            guard let component = remainder.split(separator: "/", maxSplits: 1).first else {
                continue
            }
            let name = String(component)
            let childPath = virtualPath == "/" ? "/" + name : virtualPath + "/" + name
            let isDirectory = files[childPath] == nil && files.keys.contains { $0.hasPrefix(childPath + "/") }
            entriesByName[name] = MSPDirectoryEntry(
                name: name,
                info: MSPFileInfo(virtualPath: childPath, type: isDirectory ? .directory : .regularFile)
            )
        }
        return entriesByName.keys.sorted().compactMap { entriesByName[$0] }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
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
}
