import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPPathCommandTests: XCTestCase {
    func testBasenameSupportsGNUCoreutilsPathOptions() async throws {
        let suffixOperand = await runCommand("basename", ["include/stdio.h", ".h"])
        let multiple = await runCommand("basename", ["-a", "/usr/bin/sort", "relative/name.txt"])
        let suffixOption = await runCommand("basename", ["--suffix=.txt", "relative/name.txt", "another.md"])
        let emptySuffixOption = await runCommand("basename", ["--suffix=", "aa", "ba"])
        let zeroTerminated = await runCommand("basename", ["-az", "/tmp/a.txt", "/tmp/b.md"])
        let missing = await runCommand("basename", [])
        let extra = await runCommand("basename", ["a", "b", "c"])
        let invalid = await runCommand("basename", ["-Q"])
        let missingSuffix = await runCommand("basename", ["-s"])
        let help = await runCommand("basename", ["--help"])
        let version = await runCommand("basename", ["--version"])

        XCTAssertEqual(suffixOperand.stdout, "stdio\n")
        XCTAssertEqual(multiple.stdout, "sort\nname.txt\n")
        XCTAssertEqual(suffixOption.stdout, "name\nanother.md\n")
        XCTAssertEqual(emptySuffixOption.stdout, "aa\nba\n")
        XCTAssertEqual(zeroTerminated.stdout, "a.txt\0b.md\0")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(missing.stderr, "basename: missing operand\nTry 'basename --help' for more information.\n")
        XCTAssertEqual(extra.exitCode, 1)
        XCTAssertEqual(extra.stderr, "basename: extra operand \u{2018}c\u{2019}\nTry 'basename --help' for more information.\n")
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertEqual(invalid.stderr, "basename: invalid option -- 'Q'\nTry 'basename --help' for more information.\n")
        XCTAssertEqual(missingSuffix.exitCode, 1)
        XCTAssertEqual(missingSuffix.stderr, "basename: option requires an argument -- 's'\nTry 'basename --help' for more information.\n")
        XCTAssertTrue(help.stdout.hasPrefix("Usage: basename NAME [SUFFIX]\n"))
        XCTAssertEqual(version.stdout, "basename (MSP coreutils-compatible) 9.1\n")
    }

    func testDirnameSupportsGNUCoreutilsPathOptions() async throws {
        let relative = await runCommand("dirname", ["foo/bar", "/usr/bin/"])
        let repeatedSlashes = await runCommand("dirname", ["///a///b", "///a//b/"])
        let zeroTerminated = await runCommand("dirname", ["-z", "foo/bar", "/usr/bin/"])
        let missing = await runCommand("dirname", [])
        let invalid = await runCommand("dirname", ["-Q"])
        let help = await runCommand("dirname", ["--help"])
        let version = await runCommand("dirname", ["--version"])

        XCTAssertEqual(relative.stdout, "foo\n/usr\n")
        XCTAssertEqual(repeatedSlashes.stdout, "///a\n///a\n")
        XCTAssertEqual(zeroTerminated.stdout, "foo\0/usr\0")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(missing.stderr, "dirname: missing operand\nTry 'dirname --help' for more information.\n")
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertEqual(invalid.stderr, "dirname: invalid option -- 'Q'\nTry 'dirname --help' for more information.\n")
        XCTAssertTrue(help.stdout.hasPrefix("Usage: dirname [OPTION] NAME...\n"))
        XCTAssertEqual(version.stdout, "dirname (MSP coreutils-compatible) 9.1\n")
    }

    func testReadlinkAndRealpathUseWorkspaceFileSystemBoundaries() async throws {
        let workspace = TestWorkspace(entries: [
            "/": .directory,
            "/docs": .directory,
            "/docs/a.txt": .file,
            "/links": .directory,
            "/links/docs": .symlink("/docs"),
            "/relative-link": .symlink("docs/a.txt")
        ])

        let readlink = await runCommand("readlink", ["/links/docs"], workspace: workspace)
        let readlinkCanonical = await runCommand("readlink", ["-f", "/links/docs/a.txt"], workspace: workspace)
        let readlinkMissingFinal = await runCommand("readlink", ["-f", "/docs/missing.txt"], workspace: workspace)
        let readlinkZero = await runCommand("readlink", ["--zero", "/links/docs", "/relative-link"], workspace: workspace)
        let readlinkNoNewline = await runCommand("readlink", ["--no-newline", "/links/docs"], workspace: workspace)
        let readlinkHelp = await runCommand("readlink", ["--help"], workspace: workspace)
        let readlinkVersion = await runCommand("readlink", ["--version"], workspace: workspace)
        let realpath = await runCommand("realpath", ["/links/docs/a.txt"], workspace: workspace)
        let realpathMissing = await runCommand("realpath", ["-m", "/missing/child"], workspace: workspace)
        let realpathDefaultMissingFinal = await runCommand("realpath", ["/docs/missing.txt"], workspace: workspace)
        let realpathHelp = await runCommand("realpath", ["--help"], workspace: workspace)
        let realpathVersion = await runCommand("realpath", ["--version"], workspace: workspace)
        let realpathRelativeTo = await runCommand(
            "realpath",
            ["--relative-to=/docs", "/docs/a.txt"],
            workspace: workspace
        )
        let realpathRelativeBase = await runCommand(
            "realpath",
            ["--relative-base=/docs", "/docs/a.txt"],
            workspace: workspace
        )

        XCTAssertEqual(readlink.stdout, "/docs\n")
        XCTAssertEqual(readlinkCanonical.stdout, "/docs/a.txt\n")
        XCTAssertEqual(readlinkMissingFinal.stdout, "/docs/missing.txt\n")
        XCTAssertEqual(readlinkZero.stdout, "/docs\0docs/a.txt\0")
        XCTAssertEqual(readlinkNoNewline.stdout, "/docs")
        XCTAssertTrue(readlinkHelp.stdout.hasPrefix("Usage: readlink [OPTION]... FILE...\n"))
        XCTAssertEqual(readlinkVersion.stdout, "readlink (GNU coreutils) 9.1\n")
        XCTAssertEqual(realpath.stdout, "/docs/a.txt\n")
        XCTAssertEqual(realpathMissing.stdout, "/missing/child\n")
        XCTAssertEqual(realpathDefaultMissingFinal.stdout, "/docs/missing.txt\n")
        XCTAssertTrue(realpathHelp.stdout.hasPrefix("Usage: realpath [OPTION]... FILE...\n"))
        XCTAssertEqual(realpathVersion.stdout, "realpath (GNU coreutils) 9.1\n")
        XCTAssertEqual(realpathRelativeTo.stdout, "a.txt\n")
        XCTAssertEqual(realpathRelativeBase.stdout, "a.txt\n")

        let nonLink = await runCommand("readlink", ["/docs"], workspace: workspace)
        XCTAssertEqual(nonLink.exitCode, 1)
        XCTAssertEqual(nonLink.stdout, "")
        XCTAssertEqual(nonLink.stderr, "")
    }

    func testReadlinkAndRealpathMatchGNUErrorContinuationModes() async throws {
        let workspace = TestWorkspace(entries: [
            "/": .directory,
            "/docs": .directory,
            "/docs/a.txt": .file,
            "/links": .directory,
            "/links/docs": .symlink("/docs"),
            "/relative-link": .symlink("docs/a.txt")
        ])

        let readlinkMixed = await runCommand(
            "readlink",
            ["/links/docs", "/docs", "/relative-link"],
            workspace: workspace
        )
        let readlinkVerbose = await runCommand("readlink", ["-v", "/docs"], workspace: workspace)
        let readlinkExistingMissing = await runCommand("readlink", ["-e", "/missing"], workspace: workspace)
        let realpathMixed = await runCommand(
            "realpath",
            ["/docs/a.txt", "/missing/child", "/links/docs/a.txt"],
            workspace: workspace
        )
        let realpathQuiet = await runCommand("realpath", ["-q", "-e", "/missing"], workspace: workspace)
        let realpathNoSymlinks = await runCommand("realpath", ["-s", "/links/docs/a.txt"], workspace: workspace)
        let readlinkMissingOperand = await runCommand("readlink", [], workspace: workspace)
        let readlinkInvalid = await runCommand("readlink", ["-Z"], workspace: workspace)
        let realpathMissingOperand = await runCommand("realpath", [], workspace: workspace)
        let realpathInvalid = await runCommand("realpath", ["--bad"], workspace: workspace)

        XCTAssertEqual(readlinkMixed.stdout, "/docs\ndocs/a.txt\n")
        XCTAssertEqual(readlinkMixed.stderr, "")
        XCTAssertEqual(readlinkMixed.exitCode, 1)
        XCTAssertEqual(readlinkVerbose.stderr, "readlink: /docs: Invalid argument\n")
        XCTAssertEqual(readlinkVerbose.exitCode, 1)
        XCTAssertEqual(readlinkExistingMissing.stderr, "")
        XCTAssertEqual(readlinkExistingMissing.exitCode, 1)

        XCTAssertEqual(realpathMixed.stdout, "/docs/a.txt\n/docs/a.txt\n")
        XCTAssertEqual(realpathMixed.stderr, "realpath: /missing/child: No such file or directory\n")
        XCTAssertEqual(realpathMixed.exitCode, 1)
        XCTAssertEqual(realpathQuiet.stdout, "")
        XCTAssertEqual(realpathQuiet.stderr, "")
        XCTAssertEqual(realpathQuiet.exitCode, 1)
        XCTAssertEqual(realpathNoSymlinks.stdout, "/links/docs/a.txt\n")
        XCTAssertEqual(readlinkMissingOperand.exitCode, 1)
        XCTAssertEqual(readlinkMissingOperand.stderr, "readlink: missing operand\nTry 'readlink --help' for more information.\n")
        XCTAssertEqual(readlinkInvalid.exitCode, 1)
        XCTAssertEqual(readlinkInvalid.stderr, "readlink: invalid option -- 'Z'\nTry 'readlink --help' for more information.\n")
        XCTAssertEqual(realpathMissingOperand.exitCode, 1)
        XCTAssertEqual(realpathMissingOperand.stderr, "realpath: missing operand\nTry 'realpath --help' for more information.\n")
        XCTAssertEqual(realpathInvalid.exitCode, 1)
        XCTAssertEqual(realpathInvalid.stderr, "realpath: unrecognized option '--bad'\nTry 'realpath --help' for more information.\n")
    }

    private func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        currentDirectory: String = "/"
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(workspace: workspace, currentDirectory: currentDirectory)
        )
    }
}

private struct TestWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(entries: [String: TestWorkspaceFileSystem.Entry]) {
        self.fileSystem = TestWorkspaceFileSystem(entries: entries)
    }
}

private struct TestWorkspaceFileSystem: MSPWorkspaceFileSystem {
    enum Entry {
        case file
        case directory
        case symlink(String)
    }

    let policy = MSPWorkspaceFileSystemPolicy.default
    var entries: [String: Entry]

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        guard !policy.isHidden(virtualPath) else {
            throw MSPWorkspaceFileSystemError.hiddenPath(virtualPath)
        }
        return MSPResolvedPath(virtualPath: virtualPath)
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        switch entry {
        case .file:
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile)
        case .directory:
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        case .symlink:
            return MSPFileInfo(virtualPath: virtualPath, type: .symbolicLink)
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        guard case .symlink(let target) = entry else {
            throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
        }
        return target
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
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
