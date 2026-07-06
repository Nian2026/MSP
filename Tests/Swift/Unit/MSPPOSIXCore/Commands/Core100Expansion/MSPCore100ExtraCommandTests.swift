import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

final class MSPCore100ExtraCommandTests: XCTestCase {
    func testEnvironmentIdentityProcessAndPathUtilitiesMatchStableOracleCases() async throws {
        let printenv = await runCommand(
            "printenv",
            ["FOO", "EMPTY", "MISSING"],
            environment: ["FOO": "bar", "EMPTY": ""]
        )
        let groups = await runCommand("groups", ["root", "nobody", "missing-user"])
        let nproc = await runCommand("nproc", ["--ignore=9999"])
        let tty = await runCommand("tty", [])
        let ttySilent = await runCommand("tty", ["-s"])
        let ttyHelp = await runCommand("tty", ["--help"])
        let ttyVersion = await runCommand("tty", ["--version"])
        let pathchkOK = await runCommand("pathchk", ["ok", "dir/file"])
        let pathchkEmpty = await runCommand("pathchk", [""])
        let pathchkWorkspace = Core100ExtraWorkspace(files: [
            "/plain": Data("x".utf8),
            "/dir/file": Data("x".utf8)
        ])
        let pathchkNonDirectoryParent = await runCommand("pathchk", ["plain/child"], workspace: pathchkWorkspace)
        let pathchkHelp = await runCommand("pathchk", ["--help"])
        let pathchkVersion = await runCommand("pathchk", ["--version"])
        let nprocHelp = await runCommand("nproc", ["--help"])
        let nprocVersion = await runCommand("nproc", ["--version"])

        XCTAssertEqual(printenv.stdout, "bar\n\n")
        XCTAssertEqual(printenv.stderr, "")
        XCTAssertEqual(printenv.exitCode, 1)
        XCTAssertEqual(groups.stdout, "root : root\nnobody : nogroup\n")
        XCTAssertEqual(groups.stderr, "groups: \u{2018}missing-user\u{2019}: no such user\n")
        XCTAssertEqual(groups.exitCode, 1)
        XCTAssertEqual(nproc.stdout, "1\n")
        XCTAssertEqual(nproc.stderr, "")
        XCTAssertEqual(nproc.exitCode, 0)
        XCTAssertEqual(tty.stdout, "not a tty\n")
        XCTAssertEqual(tty.exitCode, 1)
        XCTAssertEqual(ttySilent.stdout, "")
        XCTAssertEqual(ttySilent.exitCode, 1)
        XCTAssertTrue(ttyHelp.stdout.hasPrefix("Usage: tty [OPTION]...\n"))
        XCTAssertEqual(ttyVersion.stdout, "tty (GNU coreutils) 9.1\n")
        XCTAssertEqual(pathchkOK.exitCode, 0)
        XCTAssertEqual(pathchkOK.stderr, "")
        XCTAssertEqual(pathchkEmpty.stderr, "pathchk: '': No such file or directory\n")
        XCTAssertEqual(pathchkEmpty.exitCode, 1)
        XCTAssertEqual(pathchkNonDirectoryParent.stderr, "pathchk: \u{2018}plain\u{2019}: Not a directory\n")
        XCTAssertEqual(pathchkNonDirectoryParent.exitCode, 1)
        XCTAssertTrue(pathchkHelp.stdout.hasPrefix("Usage: pathchk [OPTION]... NAME...\n"))
        XCTAssertEqual(pathchkVersion.stdout, "pathchk (GNU coreutils) 9.1\n")
        XCTAssertTrue(nprocHelp.stdout.hasPrefix("Usage: nproc [OPTION]...\n"))
        XCTAssertEqual(nprocVersion.stdout, "nproc (GNU coreutils) 9.1\n")
    }

    func testFactorAndSumUseGNUCoreutilsAlgorithms() async throws {
        let workspace = Core100ExtraWorkspace(files: [
            "/sum.txt": Data("alpha\nbeta\n".utf8)
        ])

        let factor = await runCommand("factor", ["0", "1", "2", "12", "97", "1001"])
        let sumBSD = await runCommand("sum", ["sum.txt"], workspace: workspace)
        let sumBSDExplicit = await runCommand("sum", ["-r", "sum.txt"], workspace: workspace)
        let sumSysV = await runCommand("sum", ["-s", "sum.txt"], workspace: workspace)
        let factorHelp = await runCommand("factor", ["--help"])
        let factorVersion = await runCommand("factor", ["--version"])
        let sumHelp = await runCommand("sum", ["--help"])
        let sumVersion = await runCommand("sum", ["--version"])

        XCTAssertEqual(factor.stdout, "0:\n1:\n2: 2\n12: 2 2 3\n97: 97\n1001: 7 11 13\n")
        XCTAssertEqual(factor.stderr, "")
        XCTAssertEqual(factor.exitCode, 0)
        XCTAssertEqual(sumBSD.stdout, "41645     1 sum.txt\n")
        XCTAssertEqual(sumBSDExplicit.stdout, "41645     1 sum.txt\n")
        XCTAssertEqual(sumSysV.stdout, "950 1 sum.txt\n")
        XCTAssertTrue(factorHelp.stdout.hasPrefix("Usage: factor [NUMBER]...\n"))
        XCTAssertEqual(factorVersion.stdout, "factor (GNU coreutils) 9.1\n")
        XCTAssertTrue(sumHelp.stdout.hasPrefix("Usage: sum [OPTION]... [FILE]...\n"))
        XCTAssertEqual(sumVersion.stdout, "sum (GNU coreutils) 9.1\n")
    }

    func testLinkDelegatesHardLinkCreationToWorkspaceFS() async throws {
        let workspace = Core100ExtraWorkspace(files: [
            "/src.txt": Data("data\n".utf8)
        ])

        let result = await runCommand("link", ["src.txt", "hard.txt"], workspace: workspace)

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(workspace.fileData("/hard.txt"), Data("data\n".utf8))
        XCTAssertEqual(workspace.linkCalls, [
            Core100ExtraLinkCall(source: "src.txt", link: "hard.txt", currentDirectory: "/")
        ])
    }

    func testLinkFailureDiagnosticsUseCoreutilsQuoting() async throws {
        let existingWorkspace = Core100ExtraWorkspace(files: [
            "/src": Data("one".utf8),
            "/hard": Data("two".utf8)
        ])

        let existing = await runCommand("link", ["src", "hard"], workspace: existingWorkspace)

        XCTAssertEqual(existing.exitCode, 1)
        XCTAssertEqual(existing.stdout, "")
        XCTAssertEqual(existing.stderr, "link: cannot create link 'hard' to 'src': File exists\n")

        let missingWorkspace = Core100ExtraWorkspace(files: [:])
        let missing = await runCommand("link", ["missing", "hard"], workspace: missingWorkspace)

        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertEqual(missing.stderr, "link: cannot create link 'hard' to 'missing': No such file or directory\n")
    }

    private func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        standardInput: Data = Data(),
        environment: [String: String] = [:]
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(
                workspace: workspace,
                currentDirectory: "/",
                environment: environment,
                standardInput: standardInput,
                availableCommandNames: registry.commandNames
            )
        )
    }
}

private struct Core100ExtraLinkCall: Equatable {
    var source: String
    var link: String
    var currentDirectory: String
}

private final class Core100ExtraWorkspace: MSPWorkspace, @unchecked Sendable {
    let rootPath = "/"
    var fileSystem: any MSPWorkspaceFileSystem { fileSystemBox }
    let fileSystemBox: Core100ExtraFileSystem

    var linkCalls: [Core100ExtraLinkCall] {
        fileSystemBox.linkCalls
    }

    init(files: [String: Data]) {
        self.fileSystemBox = Core100ExtraFileSystem(files: files)
    }

    func fileData(_ path: String) -> Data? {
        fileSystemBox.files[path]
    }
}

private final class Core100ExtraFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]
    var linkCalls: [Core100ExtraLinkCall] = []

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory) else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if let data = files[virtualPath] {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count))
        }
        if isDirectory(virtualPath) {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            if isDirectory(virtualPath) {
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

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        let source = try resolve(sourcePath, from: currentDirectory).virtualPath
        let link = try resolve(linkPath, from: currentDirectory).virtualPath
        guard let data = files[source] else {
            throw MSPWorkspaceFileSystemError.notFound(source)
        }
        guard files[link] == nil else {
            throw MSPWorkspaceFileSystemError.alreadyExists(link)
        }
        linkCalls.append(Core100ExtraLinkCall(
            source: sourcePath,
            link: linkPath,
            currentDirectory: currentDirectory
        ))
        files[link] = data
    }

    private func isDirectory(_ virtualPath: String) -> Bool {
        virtualPath == "/" || files.keys.contains { $0.hasPrefix(virtualPath + "/") }
    }
}
